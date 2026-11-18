#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
# shellcheck source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=lib/k8sgpt.sh
source "$ROOT/scripts/lib/k8sgpt.sh"
# shellcheck source=lib/monitoring.sh
source "$ROOT/scripts/lib/monitoring.sh"

usage() {
    cat <<'EOF'
Usage: bash scripts/deploy.sh [--model MODEL] [--nvidia-gpu] [--render]
Install the pinned platform charts using the current kubeconfig.
  --model MODEL  Use this model for both Ollama and K8sGPT.
  --nvidia-gpu   Request one NVIDIA GPU for Ollama.
  --render       Print manifests without connecting to a cluster; downloads charts.
  --help         Show this help without changing anything.
EOF
}

render=false
nvidia_gpu=false
while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --render) render=true; shift ;;
        --nvidia-gpu) nvidia_gpu=true; shift ;;
        --model)
            (($# >= 2)) || die '--model requires a value'
            OLLAMA_MODEL=$2; shift 2 ;;
        *) die "Unknown option: $1" ;;
    esac
done
[[ $OLLAMA_MODEL =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$ ]] || die 'Invalid model name'
[[ $K8SGPT_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid K8sGPT version'
require_command helm

ollama_args=(--set-string "extraEnv[0].value=$OLLAMA_MODEL")
if "$nvidia_gpu"; then
    ollama_args+=(--set ollama.gpu.enabled=true --set ollama.gpu.type=nvidia --set ollama.gpu.number=1)
fi

chart() {
    local release=$1 namespace=$2 name=$3 repository=$4 version=$5 values=$6
    shift 6
    log "$release: chart $name $version" >&2
    local args=("$release" "$name" --repo "$repository" --version "$version"
        --namespace "$namespace" --values "$ROOT/config/helm/$values.yaml")
    if "$render"; then
        helm template "${args[@]}" --include-crds --kube-version "$KUBERNETES_VERSION" "$@"
    else
        helm upgrade --install "${args[@]}" --create-namespace --wait \
            --wait-for-jobs --timeout "$HELM_TIMEOUT" "$@"
    fi
}

integration() {
    sed -e "s|@@OLLAMA_MODEL@@|$OLLAMA_MODEL|g" \
        -e "s|@@K8SGPT_VERSION@@|$K8SGPT_VERSION|g" \
        "$ROOT/manifests/integrations/k8sgpt.yaml.template"
}

wait_workload() {
    local namespace=$1 workload=$2
    kube wait --for=create "$workload" -n "$namespace" --timeout="$WAIT_TIMEOUT"
    kube rollout status "$workload" -n "$namespace" --timeout="$WAIT_TIMEOUT"
}

wait_k8sgpt() {
    local config
    kube wait --for=create deployment/k8sgpt -n k8sgpt --timeout="$WAIT_TIMEOUT"
    config=$(k8sgpt_config) || die 'Cannot read the K8sGPT integration configuration'
    k8sgpt_wait_config "$config"
    kube rollout status deployment/k8sgpt -n k8sgpt --timeout="$WAIT_TIMEOUT"
}

if ! "$render"; then
    require_command kubectl
    kube cluster-info >/dev/null
    if "$nvidia_gpu"; then
        gpu_capacity=$(kube get nodes -o 'jsonpath={range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}')
        [[ $gpu_capacity =~ (^|[[:space:]])[1-9][0-9]*($|[[:space:]]) ]] ||
            die 'No node advertises allocatable nvidia.com/gpu. Check the NVIDIA device plugin before deploying.'
    fi
    # The former loki-stack chart has a different storage schema and workload.
    existing=$(helm list --namespace logging --filter '^loki$' --all --output json)
    [[ $existing != *'loki-stack-'* ]] || die 'Migrate the existing loki-stack installation before deploying; see docs/operations.en.md'
    storage=$(kube get storageclass -o 'jsonpath={range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"|"}{.metadata.annotations.storageclass\.beta\.kubernetes\.io/is-default-class}{"\n"}{end}')
    defaults=0
    while IFS='|' read -r stable legacy; do
        if [[ $stable == true || $legacy == true ]]; then defaults=$((defaults + 1)); fi
    done <<< "$storage"
    ((defaults == 1)) || die 'Exactly one default StorageClass is required'
fi

chart victoria-metrics monitoring victoria-metrics-k8s-stack \
    https://victoriametrics.github.io/helm-charts "$VM_CHART_VERSION" monitoring
chart loki logging loki https://grafana.github.io/helm-charts "$LOKI_CHART_VERSION" loki
chart alloy logging alloy https://grafana.github.io/helm-charts "$ALLOY_CHART_VERSION" alloy
chart argocd argocd argo-cd https://argoproj.github.io/argo-helm "$ARGOCD_CHART_VERSION" argocd
chart ollama ai ollama https://otwld.github.io/ollama-helm "$OLLAMA_CHART_VERSION" ollama \
    "${ollama_args[@]}"
chart k8sgpt-operator k8sgpt k8sgpt-operator https://charts.k8sgpt.ai "$K8SGPT_CHART_VERSION" k8sgpt

if "$render"; then
    printf '\n---\n'
    cat "$ROOT/manifests/integrations/grafana-loki.yaml"
    printf '\n---\n'
    integration
else
    kube wait --for=condition=Established crd/k8sgpts.core.k8sgpt.ai --timeout="$WAIT_TIMEOUT"
    kube apply -f "$ROOT/manifests/integrations/grafana-loki.yaml"
    integration | kube apply -f -
    # Helm cannot wait for workloads created later by an operator.
    while read -r resource; do
        monitoring_wait_ready "$resource"
    done < <(monitoring_resources)
    for workload in deployment/vmsingle-vm deployment/vmagent-vm deployment/vmalert-vm statefulset/vmalertmanager-vm; do
        wait_workload monitoring "$workload"
    done
    wait_k8sgpt
    log 'Charts installed. Checking readiness and model availability.'
    bash "$ROOT/scripts/verify.sh"
fi
