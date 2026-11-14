#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=config/versions.env
source "$ROOT/config/versions.env"

usage() {
    cat <<'EOF'
Usage: bash scripts/storage.sh

Install Local Path Provisioner and make local-path the default StorageClass.
Uses the current kubectl context. No root permissions are needed.
Refuses to replace another default StorageClass or an unrelated local-path class.
Local volumes belong to this node; deleting a claim also deletes its data.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $arg (see --help)" ;;
    esac
done

main() (
    require_command kubectl curl
    kube get --raw=/readyz >/dev/null
    local classes name provisioner stable_default legacy_default
    # Include the old annotation as well: Kubernetes still recognizes it.
    classes=$(kube get storageclasses -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.provisioner}{"|"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"|"}{.metadata.annotations.storageclass\.beta\.kubernetes\.io/is-default-class}{"\n"}{end}')
    while IFS='|' read -r name provisioner stable_default legacy_default; do
        [[ -n $name ]] || continue
        if [[ $name == local-path ]]; then
            [[ $provisioner == rancher.io/local-path ]] ||
                die "StorageClass local-path belongs to a different provisioner."
        elif [[ $stable_default == true || $legacy_default == true ]]; then
            die "StorageClass $name is already default. Choose storage manually before continuing."
        fi
    done <<< "$classes"

    local deployment
    deployment=$(kube get deployment local-path-provisioner -n local-path-storage \
        --ignore-not-found -o name)
    if [[ -z $deployment ]]; then
        # Refuse to overwrite an existing class during a partial or custom installation.
        local existing_class
        existing_class=$(kube get storageclass local-path --ignore-not-found -o name)
        [[ -z $existing_class ]] || die "local-path exists without its deployment; inspect this installation manually."
        local manifest
        manifest=$(mktemp)
        trap 'rm -f -- "$manifest"' EXIT
        log "Installing Local Path Provisioner $LOCAL_PATH_PROVISIONER_VERSION."
        curl_fetch "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml" \
            --output "$manifest"
        kube apply -f "$manifest"
    else
        log "Existing Local Path Provisioner found; preserving its configuration."
    fi
    kube rollout status deployment/local-path-provisioner -n local-path-storage --timeout="$WAIT_TIMEOUT"
    kube annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite
    kube get storageclass local-path
    log "Storage ready. Run: bash scripts/deploy.sh"
)

main
