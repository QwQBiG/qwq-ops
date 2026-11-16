#!/usr/bin/env bash
# Shared configuration checks for the Operator-managed analyzer Deployment.

k8sgpt_config() {
    local state model backend base_url repository version
    state=$(kube get k8sgpt k8sgpt -n k8sgpt -o 'jsonpath={.spec.ai.model}{"|"}{.spec.ai.backend}{"|"}{.spec.ai.baseUrl}{"|"}{.spec.repository}{"|"}{.spec.version}') || return
    IFS='|' read -r model backend base_url repository version <<< "$state"
    [[ -n $model ]] || { warn 'K8sGPT has no configured model'; return 1; }
    [[ -n $backend && -n $repository ]] || { warn 'K8sGPT has incomplete backend or image configuration'; return 1; }
    # The Operator uses latest when spec.version is empty.
    printf '%s\n' "$model" "$backend" "$base_url" "$repository:${version:-latest}"
}

k8sgpt_template_path() {
    local container='.spec.template.spec.containers[?(@.name=="k8sgpt")]'
    case "$1" in
        model) printf '{%s.env[?(@.name=="K8SGPT_MODEL")].value}' "$container" ;;
        backend) printf '{%s.env[?(@.name=="K8SGPT_BACKEND")].value}' "$container" ;;
        baseUrl) printf '{%s.env[?(@.name=="K8SGPT_BASEURL")].value}' "$container" ;;
        image) printf '{%s.image}' "$container" ;;
    esac
}

k8sgpt_template_config() {
    local field query=''
    for field in model backend baseUrl image; do
        query+="$(k8sgpt_template_path "$field"){\"\n\"}"
    done
    kube get deployment/k8sgpt -n k8sgpt -o "jsonpath=$query"
}

k8sgpt_wait_config() {
    local field index=0
    local -a expected
    mapfile -t expected <<< "$1"
    # A previous Deployment can be Ready before the Operator applies the new CR.
    for field in model backend baseUrl image; do
        kube wait "--for=jsonpath=$(k8sgpt_template_path "$field")=${expected[index]}" \
            deployment/k8sgpt -n k8sgpt --timeout="$WAIT_TIMEOUT" || return
        index=$((index + 1))
    done
}
