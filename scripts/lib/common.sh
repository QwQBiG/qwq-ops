#!/usr/bin/env bash
# Shared command boundaries; callers enable strict mode and load versions.env.

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_command() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "Required command not found: $command_name"
    done
}

kube() {
    kubectl --request-timeout="${REQUEST_TIMEOUT:-30s}" "$@"
}

curl_fetch() {
    curl --fail --show-error --silent --location --connect-timeout 15 \
        --max-time 180 --retry 2 "$@"
}
