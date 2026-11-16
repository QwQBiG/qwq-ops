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
    local namespace=$1 controller_checked=${2:-false}
    local pods name phase deleting ready active=0 unhealthy=0
    if ! pods=$(kube get pods -n "$namespace" -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.metadata.deletionTimestamp}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'); then
        fail "Cannot read Pods in $namespace"
        return
    fi
    while IFS='|' read -r name phase deleting ready; do
        [[ -n $name ]] || continue
        if [[ $controller_checked == true && ( $phase == Failed || -n $deleting ) ]]; then
            warn "$namespace/$name: retained Pod, phase=$phase deleting=${deleting:-no}; controller readiness is checked separately"
            continue
        fi
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

# Infrastructure does not have the complete controller inventory used below.
for namespace in kube-system tigera-operator calico-system local-path-storage; do
    check_pods "$namespace"
done
for namespace in monitoring logging argocd ai k8sgpt; do
    check_pods "$namespace" true
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
    local namespace=$1 workload=$2 desired_path=spec.replicas
    local updated_path=status.updatedReplicas ready_path=status.availableReplicas
    local state generation observed desired updated ready
    case "$workload" in
        statefulset/*) ready_path=status.readyReplicas ;;
        daemonset/*)
            desired_path=status.desiredNumberScheduled
            updated_path=status.updatedNumberScheduled
            ready_path=status.numberAvailable ;;
    esac
    if ! state=$(kube get "$workload" -n "$namespace" -o "jsonpath={.metadata.generation}{\"|\"}{.status.observedGeneration}{\"|\"}{.$desired_path}{\"|\"}{.$updated_path}{\"|\"}{.$ready_path}"); then
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

# Helm's release status does not change when a managed controller is deleted.
# The rendered-manifest check compares this inventory with chart controllers
# and the controllers generated from this platform's custom resources.
managed_workloads() {
    cat <<'WORKLOADS'
monitoring deployment/grafana
monitoring deployment/victoria-metrics-kube-state-metrics
monitoring deployment/victoria-metrics-victoria-metrics-operator
monitoring daemonset/victoria-metrics-prometheus-node-exporter
monitoring deployment/vmsingle-vm
monitoring deployment/vmagent-vm
monitoring deployment/vmalert-vm
monitoring statefulset/vmalertmanager-vm
logging statefulset/loki
logging deployment/loki-gateway
logging daemonset/alloy
argocd deployment/argocd-applicationset-controller
argocd deployment/argocd-notifications-controller
argocd deployment/argocd-repo-server
argocd deployment/argocd-server
argocd deployment/argocd-dex-server
argocd deployment/argocd-redis
argocd statefulset/argocd-application-controller
ai deployment/ollama
k8sgpt deployment/k8sgpt-operator-controller-manager
k8sgpt deployment/k8sgpt
WORKLOADS
}

if config=$(k8sgpt_config); then
    if ! actual=$(k8sgpt_template_config); then
        fail 'Cannot read the K8sGPT Deployment configuration'
    elif [[ $actual != "$config" ]]; then
        fail 'K8sGPT Deployment model/backend/baseUrl/image does not match its integration'
    fi
    model=${config%%$'\n'*}
    if ! kube exec -n ai deployment/ollama -- ollama show "$model" >/dev/null; then
        fail "Ollama cannot load the configured K8sGPT model: $model"
    fi
else
    fail 'Cannot read the K8sGPT integration'
fi

while read -r resource; do
    if ! state=$(monitoring_state "$resource"); then
        fail "Cannot read monitoring/$resource reconciliation status"
    elif [[ ! $state =~ ^[0-9]+\|[0-9]+\|[a-z]+$ ]]; then
        fail "monitoring/$resource has incomplete reconciliation status"
    else
        IFS='|' read -r generation observed update_status <<< "$state"
        if ((generation > 0 && observed == generation)) && [[ $update_status == operational ]]; then
            log "monitoring/$resource: generation $generation operational"
        else
            fail "monitoring/$resource is not fully reconciled (status $state)"
        fi
    fi
done < <(monitoring_resources)

# Check rollout state after confirming the Operator-managed configurations.
while read -r namespace workload; do
    check_workload "$namespace" "$workload"
done < <(managed_workloads)

((failures == 0)) || die "$failures checks failed; inspect kubectl describe and workload logs before retrying"
log 'All requested checks passed. This checks resource readiness and model availability, not diagnosis quality.'
