#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=config/versions.env
source "$ROOT/config/versions.env"

usage() {
    cat <<'EOF'
Usage: sudo bash scripts/bootstrap.sh [--use-aliyun-mirror]

Prepare a fresh Ubuntu 22.04/24.04 host for a single-node lab cluster.
Changes swap, kernel networking, containerd and Kubernetes packages.
Existing clusters and incompatible runtime configurations are refused.
EOF
}

IMAGE_REPOSITORY=registry.k8s.io
for arg in "$@"; do
    case "$arg" in
        --help|-h) usage; exit 0 ;;
        --use-aliyun-mirror) IMAGE_REPOSITORY=registry.aliyuncs.com/google_containers ;;
        *) die "Unknown option: $arg (see --help)" ;;
    esac
done

preflight() {
    [[ $EUID -eq 0 ]] || die "Run bootstrap with sudo."
    [[ $(uname -s) == Linux ]] || die "Bootstrap requires Linux."
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ $ID == ubuntu && ( $VERSION_ID == 22.04 || $VERSION_ID == 24.04 ) ]] ||
        die "Supported hosts: Ubuntu 22.04 or 24.04."
    [[ ! -e /etc/kubernetes/admin.conf && ! -e /etc/kubernetes/kubelet.conf && ! -d /var/lib/etcd/member ]] ||
        die "An existing cluster was found. Bootstrap does not upgrade or reset clusters."
    [[ ! -e /root/.kube/config ]] ||
        die "Existing /root/.kube/config found; preserve it before preparing this host."
    for cmd in apt-get apt-mark systemctl modprobe install sed grep python3 ip; do
        require_command "$cmd"
    done
    validate_network
    local package installed
    for package in kubelet kubeadm kubectl; do
        if installed=$(dpkg-query -W -f='${Status} ${Version}' "$package" 2>/dev/null); then
            if [[ $installed == 'install ok installed '* ]]; then
                [[ $installed == "install ok installed ${KUBERNETES_VERSION}-1.1" ]] ||
                    die "Existing $package differs from the configured version; bootstrap does not upgrade packages."
            fi
        fi
    done
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
        TARGET_USER=$SUDO_USER
        TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
        [[ -n $TARGET_HOME ]] || die "Cannot locate the invoking user's home directory."
        [[ ! -e $TARGET_HOME/.kube/config ]] ||
            die "Existing $TARGET_HOME/.kube/config found; bootstrap will not overwrite it."
    fi
    if [[ -f /etc/containerd/config.toml ]]; then
        require_command containerd
        local runtime_config
        runtime_config=$(containerd config dump)
        grep -Eq 'SystemdCgroup[[:space:]]*=[[:space:]]*true' <<< "$runtime_config" ||
            die "Existing containerd config must enable SystemdCgroup; review it manually."
        if grep -Eq 'disabled_plugins[[:space:]]*=.*"(io.containerd.grpc.v1.)?cri"' <<< "$runtime_config"; then
            die "Existing containerd config disables CRI; review it manually."
        fi
    fi
}

validate_network() {
    ip -j -4 address show scope global | python3 -c '
import ipaddress, json, sys
try:
    pod = ipaddress.ip_network(sys.argv[1])
    if pod.version != 4 or pod.prefixlen > 26:
        raise ValueError("Pod CIDR must be IPv4 with a prefix no longer than /26")
    if pod.overlaps(ipaddress.ip_network("10.96.0.0/12")):
        raise ValueError("Pod CIDR overlaps the kubeadm default service CIDR")
    for interface in json.load(sys.stdin):
        for address in interface.get("addr_info", []):
            host = ipaddress.ip_interface(str(address["local"]) + "/" + str(address["prefixlen"])).network
            if pod.overlaps(host):
                raise ValueError("Pod CIDR overlaps host network " + str(host))
except (ValueError, KeyError) as error:
    sys.exit(str(error))
' "$POD_CIDR"
}

prepare_host() {
    log "Disabling swap and preparing kernel networking."
    if [[ ! -e /etc/fstab.qwq-ops.bak ]]; then
        cp /etc/fstab /etc/fstab.qwq-ops.bak
    fi
    swapoff -a
    sed -i '/^[[:space:]]*#/!{/[[:space:]]swap[[:space:]]/s/^/# qwq-ops: /;}' /etc/fstab
    modprobe overlay
    modprobe br_netfilter
    if [[ ! -e /etc/modules-load.d/qwq-ops.conf ]]; then
        printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/qwq-ops.conf
    fi
    if [[ ! -e /etc/sysctl.d/99-qwq-ops.conf ]]; then
        cat > /etc/sysctl.d/99-qwq-ops.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
    fi
    sysctl --system
    [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]] || die "IPv4 forwarding is disabled."
}

install_runtime() {
    log "Installing Ubuntu's containerd package if needed."
    apt-get update
    apt-get install -y ca-certificates curl gnupg
    if ! command -v containerd >/dev/null 2>&1; then
        apt-get install -y containerd
    fi
    if [[ ! -e /etc/containerd/config.toml ]]; then
        install -d -m 0755 /etc/containerd
        containerd config default > /etc/containerd/config.toml
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    fi
    systemctl enable containerd
    systemctl restart containerd
    systemctl is-active --quiet containerd
}

install_kubernetes() {
    log "Installing Kubernetes $KUBERNETES_VERSION."
    local minor=${KUBERNETES_VERSION%.*}
    local keyring=/etc/apt/keyrings/qwq-ops-kubernetes.gpg
    local repository=/etc/apt/sources.list.d/qwq-ops-kubernetes.list
    install -d -m 0755 /etc/apt/keyrings
    if [[ ! -e $keyring ]]; then
        curl_fetch "https://pkgs.k8s.io/core:/stable:/v${minor}/deb/Release.key" |
            gpg --dearmor --output "$keyring"
        chmod 0644 "$keyring"
    fi
    local expected="deb [signed-by=$keyring] https://pkgs.k8s.io/core:/stable:/v${minor}/deb/ /"
    if [[ -e $repository ]]; then
        [[ $(cat "$repository") == "$expected" ]] ||
            die "Existing $repository differs; review it before retrying."
    else
        printf '%s\n' "$expected" > "$repository"
    fi
    apt-get update
    apt-get install -y "kubelet=${KUBERNETES_VERSION}-1.1" \
        "kubeadm=${KUBERNETES_VERSION}-1.1" "kubectl=${KUBERNETES_VERSION}-1.1"
    apt-mark hold kubelet kubeadm kubectl
    systemctl enable kubelet
}

configure_access() {
    install -d -m 0700 /root/.kube
    install -m 0600 /etc/kubernetes/admin.conf /root/.kube/config
    if [[ -n ${TARGET_USER:-} ]]; then
        local target_group
        target_group=$(id -gn "$TARGET_USER")
        install -d -m 0700 -o "$TARGET_USER" -g "$target_group" "$TARGET_HOME/.kube"
        install -m 0600 -o "$TARGET_USER" -g "$target_group" \
            /etc/kubernetes/admin.conf "$TARGET_HOME/.kube/config"
    fi
    export KUBECONFIG=/etc/kubernetes/admin.conf
}

install_network() (
    log "Installing Calico $CALICO_VERSION."
    local operator_manifest
    operator_manifest=$(mktemp)
    trap 'rm -f -- "$operator_manifest"' EXIT
    curl_fetch "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/operator-crds.yaml" \
        --output "$operator_manifest"
    kube apply --server-side -f "$operator_manifest"
    kube wait --for=condition=Established crd/installations.operator.tigera.io --timeout="$WAIT_TIMEOUT"
    curl_fetch "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" \
        --output "$operator_manifest"
    kube apply --server-side -f "$operator_manifest"
    kube rollout status deployment/tigera-operator -n tigera-operator --timeout="$WAIT_TIMEOUT"
    # Use a minimal Installation instead of enabling optional Calico dashboards.
    kube apply -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: $POD_CIDR
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
EOF
    kube wait --for=condition=Ready nodes --all --timeout="$WAIT_TIMEOUT"
)

main() {
    preflight
    prepare_host
    install_runtime
    install_kubernetes
    log "Initializing the single-node cluster."
    kubeadm init --kubernetes-version="v$KUBERNETES_VERSION" \
        --pod-network-cidr="$POD_CIDR" --image-repository="$IMAGE_REPOSITORY" \
        --cri-socket=unix:///run/containerd/containerd.sock
    configure_access
    # This host is dedicated to the lab, so workloads may run on its control plane.
    kube taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-
    install_network
    kube get nodes -o wide
    log "Cluster ready. Run: bash scripts/storage.sh"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main
fi
