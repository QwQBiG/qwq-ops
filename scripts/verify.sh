#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
# shellcheck source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"

case "${1:-}" in
    --help|-h)
        printf 'Usage: bash scripts/verify.sh\nRead-only checks; any missing or unhealthy component returns a nonzero status.\n'
        exit 0 ;;
    '') ;;
    *) die "Unknown option: $1" ;;
esac
(($# == 0)) || die 'Unexpected arguments'
require_command kubectl helm
kube cluster-info >/dev/null
failures=0
fail() { warn "$*"; failures=$((failures + 1)); }

if nodes=$(kube get nodes -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'); then
    [[ -n $nodes ]] || fail 'The cluster has no nodes'
    while IFS='|' read -r name ready; do
        [[ -n $name ]] || continue
        [[ $ready == True ]] || fail "Node $name is not Ready"
    done <<< "$nodes"
else
    fail 'Cannot read nodes'
fi

if storage=$(kube get storageclass -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"|"}{.metadata.annotations.storageclass\.beta\.kubernetes\.io/is-default-class}{"\n"}{end}'); then
    defaults=0
    while IFS='|' read -r name stable legacy; do
        if [[ $stable == true || $legacy == true ]]; then defaults=$((defaults + 1)); fi
    done <<< "$storage"
    ((defaults == 1)) || fail "Expected one default StorageClass; found $defaults"
else
    fail 'Cannot read StorageClasses'
fi

check_pods() {
    local namespace=$1 pods name phase deleting ready active=0 unhealthy=0
    if ! pods=$(kube get pods -n "$namespace" -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.metadata.deletionTimestamp}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'); then
        fail "Cannot read Pods in $namespace"
        return
    fi
    while IFS='|' read -r name phase deleting ready; do
        [[ -n $name ]] || continue
        if [[ $phase == Succeeded && -z $deleting ]]; then continue; fi
        active=$((active + 1))
        if [[ $phase != Running || $ready != True || -n $deleting ]]; then
            fail "$namespace/$name: phase=$phase Ready=${ready:-missing} deleting=${deleting:-no}"
            unhealthy=$((unhealthy + 1))
        fi
    done <<< "$pods"
    if ((active == 0)); then
        fail "$namespace has no active Pods"
    elif ((unhealthy == 0)); then
        log "$namespace: $active Pods Ready"
    fi
}

for namespace in kube-system tigera-operator calico-system local-path-storage monitoring logging argocd ai k8sgpt; do
    check_pods "$namespace"
done

check_release() {
    local namespace=$1 release=$2 deployed
    if ! deployed=$(helm list --namespace "$namespace" --filter "^$release$" --deployed --short); then
        fail "Cannot read Helm release $namespace/$release"
    elif [[ $deployed != "$release" ]]; then
        fail "Helm release $namespace/$release is missing or is not deployed"
    else
        log "$namespace/$release: deployed"
    fi
}
check_release monitoring victoria-metrics
check_release logging loki
check_release logging alloy
check_release argocd argocd
check_release ai ollama
check_release k8sgpt k8sgpt-operator

check_workload() {
    local namespace=$1 workload=$2 field=availableReplicas state generation observed desired updated ready
    [[ $workload != statefulset/* ]] || field=readyReplicas
    if ! state=$(kube get "$workload" -n "$namespace" -o "jsonpath={.metadata.generation}{\"|\"}{.status.observedGeneration}{\"|\"}{.spec.replicas}{\"|\"}{.status.updatedReplicas}{\"|\"}{.status.$field}"); then
        fail "Cannot read $namespace/$workload"
    elif [[ ! $state =~ ^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+$ ]]; then
        fail "$namespace/$workload has incomplete replica status"
    else
        IFS='|' read -r generation observed desired updated ready <<< "$state"
        if ((desired > 0 && observed >= generation && updated == desired && ready == desired)); then
            log "$namespace/$workload: $ready updated replicas ready"
        else
            fail "$namespace/$workload is not fully rolled out (status $state)"
        fi
    fi
}
for workload in deployment/vmsingle-vm deployment/vmagent-vm deployment/vmalert-vm statefulset/vmalertmanager-vm; do
    check_workload monitoring "$workload"
done
check_workload k8sgpt deployment/k8sgpt

if model=$(kube get k8sgpt k8sgpt -n k8sgpt -o 'jsonpath={.spec.ai.model}'); then
    if [[ -z $model ]]; then
        fail 'K8sGPT has no configured model'
    elif ! kube exec -n ai deployment/ollama -- ollama show "$model" >/dev/null; then
        fail "Ollama cannot load the configured K8sGPT model: $model"
    fi
else
    fail 'Cannot read the K8sGPT integration'
fi

((failures == 0)) || die "$failures checks failed; inspect kubectl describe and workload logs before retrying"
log 'All requested checks passed. This checks resource readiness and model availability, not diagnosis quality.'
