#!/usr/bin/env bash
# Reconciliation checks for the monitoring stack's Operator-managed resources.

monitoring_resources() {
    printf '%s\n' vmsingle/vm vmagent/vm vmalert/vm vmalertmanager/vm
}

monitoring_state() {
    kube get "$1" -n monitoring -o 'jsonpath={.metadata.generation}{"|"}{.status.observedGeneration}{"|"}{.status.updateStatus}'
}

monitoring_wait_ready() {
    local resource=$1 generation
    generation=$(kube get "$resource" -n monitoring -o 'jsonpath={.metadata.generation}') || return
    [[ $generation =~ ^[1-9][0-9]*$ ]] || {
        warn "$resource has no valid generation"
        return 1
    }
    # The Operator writes generation and updateStatus together; only operational
    # confirms that reconciliation of the observed generation succeeded.
    kube wait "--for=jsonpath={.status.observedGeneration}=$generation" \
        "$resource" -n monitoring --timeout="$WAIT_TIMEOUT" || return
    kube wait --for=jsonpath='{.status.updateStatus}'=operational \
        "$resource" -n monitoring --timeout="$WAIT_TIMEOUT" || return
}
