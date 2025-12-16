#!/bin/bash
#
# 01_init_k8s.sh - 系统准备和 Kubernetes 集群初始化脚本
# 
# 用途: 在 Ubuntu 22.04 LTS 上从零搭建单节点 Kubernetes 集群
# 目标环境: 4-8 vCPU, 16GB RAM
#
# 使用方法:
#   sudo ./01_init_k8s.sh [--use-aliyun-mirror]
#
# 选项:
#   --use-aliyun-mirror  使用阿里云镜像源（适用于国内网络）
#

set -euo pipefail

# ============================================================================
# 全局变量
# ============================================================================
K8S_VERSION="1.28"
POD_CIDR="192.168.0.0/16"
USE_ALIYUN_MIRROR=false
CALICO_VERSION="v3.26.4"

# 解析命令行参数
for arg in "$@"; do
    case $arg in
        --use-aliyun-mirror)
            USE_ALIYUN_MIRROR=true
            shift
            ;;
    esac
done

# ============================================================================
# 通用函数
# ============================================================================

# 日志输出函数
info() {
    echo -e "\033[32m[INFO]\033[0m $(date '+%Y-%m-%d %H:%M:%S') $*"
}

warn() {
    echo -e "\033[33m[WARN]\033[0m $(date '+%Y-%m-%d %H:%M:%S') $*"
}

error() {
    echo -e "\033[31m[ERROR]\033[0m $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

error_exit() {
    error "$1"
    exit 1
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "此脚本需要 root 权限运行，请使用 sudo 执行"
    fi
    info "Root 权限检查通过"
}

# 检查命令是否存在
check_command() {
    local cmd=$1
    if ! command -v "$cmd" &>/dev/null; then
        return 1
    fi
    return 0
}

# 等待 Pod 就绪
wait_for_pods() {
    local namespace=$1
    local label=$2
    local timeout=${3:-300}
    
    info "等待 $namespace 命名空间中 $label 的 Pod 就绪..."
    
    local end_time=$((SECONDS + timeout))
    while [[ $SECONDS -lt $end_time ]]; do
        local ready_pods=$(kubectl get pods -n "$namespace" -l "$label" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | tr ' ' '\n' | grep -c "True" || echo "0")
        local total_pods=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | wc -l || echo "0")
        
        if [[ $total_pods -gt 0 && $ready_pods -eq $total_pods ]]; then
            info "所有 Pod 已就绪 ($ready_pods/$total_pods)"
            return 0
        fi
        
        echo -n "."
        sleep 5
    done
    
    echo ""
    warn "等待超时，部分 Pod 可能未就绪"
    return 1
}


# ============================================================================
# 模块 1: 禁用 Swap (需求 1.1)
# ============================================================================
disable_swap() {
    info "=== 禁用 Swap ==="
    
    # 检查当前 swap 状态
    local swap_status=$(swapon --show 2>/dev/null | wc -l)
    
    if [[ $swap_status -eq 0 ]]; then
        info "Swap 已禁用，跳过此步骤"
    else
        info "正在禁用 swap..."
        swapoff -a
        info "Swap 已禁用"
    fi
    
    # 注释 /etc/fstab 中的 swap 条目（幂等性：检查是否已注释）
    if grep -q "^[^#].*swap" /etc/fstab 2>/dev/null; then
        info "正在注释 /etc/fstab 中的 swap 条目..."
        sed -i '/swap/s/^/#/' /etc/fstab
        info "/etc/fstab 中的 swap 条目已注释"
    else
        info "/etc/fstab 中无需注释的 swap 条目"
    fi
    
    info "Swap 禁用模块完成"
}


# ============================================================================
# 模块 2: 加载内核模块 (需求 1.2)
# ============================================================================
load_kernel_modules() {
    info "=== 加载内核模块 ==="
    
    local modules=("overlay" "br_netfilter")
    local config_file="/etc/modules-load.d/k8s.conf"
    
    # 加载内核模块（幂等性：检查是否已加载）
    for mod in "${modules[@]}"; do
        if lsmod | grep -q "^$mod"; then
            info "内核模块 $mod 已加载"
        else
            info "正在加载内核模块 $mod..."
            modprobe "$mod"
            info "内核模块 $mod 加载成功"
        fi
    done
    
    # 创建持久化配置（幂等性：检查文件内容）
    local expected_content="overlay
br_netfilter"
    
    if [[ -f "$config_file" ]] && [[ "$(cat "$config_file")" == "$expected_content" ]]; then
        info "内核模块持久化配置已存在"
    else
        info "正在创建内核模块持久化配置..."
        cat > "$config_file" <<EOF
overlay
br_netfilter
EOF
        info "内核模块持久化配置已创建: $config_file"
    fi
    
    info "内核模块加载模块完成"
}


# ============================================================================
# 模块 3: 配置 sysctl 网络参数 (需求 1.3)
# ============================================================================
configure_sysctl() {
    info "=== 配置 sysctl 网络参数 ==="
    
    local config_file="/etc/sysctl.d/k8s.conf"
    local expected_content="net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1"
    
    # 检查配置文件是否已存在且内容正确（幂等性）
    if [[ -f "$config_file" ]] && [[ "$(cat "$config_file")" == "$expected_content" ]]; then
        info "sysctl 配置已存在且正确"
    else
        info "正在创建 sysctl 配置..."
        cat > "$config_file" <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
        info "sysctl 配置已创建: $config_file"
    fi
    
    # 应用配置
    info "正在应用 sysctl 配置..."
    sysctl --system >/dev/null 2>&1
    
    # 验证配置
    local ip_forward=$(sysctl -n net.ipv4.ip_forward)
    if [[ "$ip_forward" == "1" ]]; then
        info "sysctl 配置验证成功 (ip_forward=$ip_forward)"
    else
        warn "sysctl 配置可能未正确应用"
    fi
    
    info "sysctl 网络配置模块完成"
}


# ============================================================================
# 模块 4: 安装和配置 containerd (需求 2.1, 2.2, 2.3)
# ============================================================================
install_containerd() {
    info "=== 安装和配置 containerd ==="
    
    # 检查 containerd 是否已安装（幂等性）
    if check_command containerd; then
        local version=$(containerd --version 2>/dev/null | awk '{print $3}')
        info "containerd 已安装 (版本: $version)"
        
        # 检查配置是否正确
        if grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
            info "containerd 配置已正确，跳过安装"
            
            # 确保服务运行
            if ! systemctl is-active --quiet containerd; then
                info "启动 containerd 服务..."
                systemctl start containerd
            fi
            return 0
        fi
    fi
    
    # 安装依赖
    info "正在安装依赖包..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release apt-transport-https
    
    # 添加 Docker 官方 GPG 密钥和仓库（containerd 来自 Docker 仓库）
    info "正在添加 Docker 仓库..."
    install -m 0755 -d /etc/apt/keyrings
    
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    
    local arch=$(dpkg --print-architecture)
    local codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    
    echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable" > /etc/apt/sources.list.d/docker.list
    
    # 安装 containerd
    info "正在安装 containerd.io..."
    apt-get update -qq
    apt-get install -y -qq containerd.io
    
    # 生成默认配置
    info "正在生成 containerd 配置..."
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    
    # 修改配置启用 SystemdCgroup
    info "正在启用 SystemdCgroup..."
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    
    # 启动并设置开机自启
    info "正在启动 containerd 服务..."
    systemctl daemon-reload
    systemctl enable containerd
    systemctl restart containerd
    
    # 验证
    if systemctl is-active --quiet containerd; then
        info "containerd 服务已启动并设置开机自启"
    else
        error_exit "containerd 服务启动失败"
    fi
    
    info "containerd 安装和配置模块完成"
}


# ============================================================================
# 模块 5: 安装 Kubernetes 组件 (需求 3.1, 3.2, 3.3)
# ============================================================================
install_kubernetes() {
    info "=== 安装 Kubernetes 组件 ==="
    
    # 检查 kubeadm 是否已安装（幂等性）
    if check_command kubeadm; then
        local version=$(kubeadm version -o short 2>/dev/null)
        if [[ "$version" == *"$K8S_VERSION"* ]]; then
            info "Kubernetes 组件已安装 (版本: $version)"
            
            # 检查是否已锁定版本
            if apt-mark showhold | grep -q "kubeadm"; then
                info "Kubernetes 组件版本已锁定，跳过安装"
                return 0
            fi
        fi
    fi
    
    # 安装依赖
    info "正在安装依赖包..."
    apt-get update -qq
    apt-get install -y -qq apt-transport-https ca-certificates curl gpg
    
    # 添加 Kubernetes apt 仓库
    info "正在添加 Kubernetes apt 仓库..."
    mkdir -p /etc/apt/keyrings
    
    local k8s_keyring="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
    if [[ ! -f "$k8s_keyring" ]]; then
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --dearmor -o "$k8s_keyring"
    fi
    
    echo "deb [signed-by=$k8s_keyring] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
    
    # 安装 kubelet, kubeadm, kubectl
    info "正在安装 kubelet, kubeadm, kubectl..."
    apt-get update -qq
    apt-get install -y -qq kubelet kubeadm kubectl
    
    # 锁定版本防止意外升级
    info "正在锁定 Kubernetes 组件版本..."
    apt-mark hold kubelet kubeadm kubectl
    
    # 验证安装
    local installed_version=$(kubeadm version -o short 2>/dev/null)
    info "Kubernetes 组件安装完成 (版本: $installed_version)"
    
    info "Kubernetes 组件安装模块完成"
}


# ============================================================================
# 模块 6: 初始化 Kubernetes 集群 (需求 4.1, 4.2)
# ============================================================================
init_cluster() {
    info "=== 初始化 Kubernetes 集群 ==="
    
    # 检查集群是否已初始化（幂等性）
    if [[ -f /etc/kubernetes/admin.conf ]]; then
        info "检测到已存在的集群配置"
        
        # 尝试获取集群信息
        if kubectl --kubeconfig=/etc/kubernetes/admin.conf cluster-info &>/dev/null; then
            info "Kubernetes 集群已初始化且运行正常，跳过初始化"
            
            # 确保 kubeconfig 已配置
            setup_kubeconfig
            return 0
        else
            warn "集群配置存在但无法连接，可能需要手动检查"
        fi
    fi
    
    # 构建 kubeadm init 命令
    local init_cmd="kubeadm init --pod-network-cidr=$POD_CIDR"
    
    # 如果使用阿里云镜像源
    if [[ "$USE_ALIYUN_MIRROR" == "true" ]]; then
        info "使用阿里云镜像源..."
        init_cmd="$init_cmd --image-repository=registry.aliyuncs.com/google_containers"
    fi
    
    # 执行集群初始化
    info "正在初始化 Kubernetes 集群..."
    info "执行命令: $init_cmd"
    
    eval "$init_cmd"
    
    # 配置 kubectl 访问
    setup_kubeconfig
    
    info "Kubernetes 集群初始化模块完成"
}

# 配置 kubeconfig
setup_kubeconfig() {
    info "正在配置 kubectl 访问..."
    
    # 为 root 用户配置
    mkdir -p /root/.kube
    cp -f /etc/kubernetes/admin.conf /root/.kube/config
    chown root:root /root/.kube/config
    
    # 为 SUDO_USER 配置（如果存在）
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        local user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        if [[ -n "$user_home" ]]; then
            mkdir -p "$user_home/.kube"
            cp -f /etc/kubernetes/admin.conf "$user_home/.kube/config"
            chown -R "$SUDO_USER:$SUDO_USER" "$user_home/.kube"
            info "已为用户 $SUDO_USER 配置 kubectl"
        fi
    fi
    
    info "kubectl 配置完成"
}


# ============================================================================
# 模块 7: 安装 Calico CNI (需求 4.3)
# ============================================================================
install_calico() {
    info "=== 安装 Calico CNI ==="
    
    # 检查 Calico 是否已安装（幂等性）
    if kubectl get namespace tigera-operator &>/dev/null; then
        local calico_pods=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | wc -l)
        if [[ $calico_pods -gt 0 ]]; then
            info "Calico CNI 已安装，跳过安装"
            return 0
        fi
    fi
    
    # 安装 Calico Operator
    info "正在安装 Calico Operator..."
    kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" 2>/dev/null || \
        kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
    
    # 等待 Operator 就绪
    info "等待 Calico Operator 就绪..."
    sleep 10
    
    # 安装 Calico CRDs
    info "正在安装 Calico 自定义资源..."
    kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml" 2>/dev/null || \
        kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"
    
    # 等待 Calico Pods 就绪
    info "等待 Calico Pods 就绪（这可能需要几分钟）..."
    sleep 30
    
    # 等待 calico-system 命名空间中的 Pod 就绪
    local timeout=300
    local end_time=$((SECONDS + timeout))
    
    while [[ $SECONDS -lt $end_time ]]; do
        local ready=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local total=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | wc -l || echo "0")
        
        if [[ $total -gt 0 && $ready -eq $total ]]; then
            info "Calico CNI 安装完成 ($ready/$total Pods 运行中)"
            return 0
        fi
        
        echo -n "."
        sleep 10
    done
    
    echo ""
    warn "Calico Pods 可能未完全就绪，请手动检查: kubectl get pods -n calico-system"
    
    info "Calico CNI 安装模块完成"
}


# ============================================================================
# 模块 8: 移除 control-plane 污点 (需求 4.4)
# ============================================================================
untaint_control_plane() {
    info "=== 移除 control-plane 污点 ==="
    
    local node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -z "$node_name" ]]; then
        error_exit "无法获取节点名称"
    fi
    
    info "节点名称: $node_name"
    
    # 移除 control-plane 污点（幂等性：检查污点是否存在）
    local taints=("node-role.kubernetes.io/control-plane:NoSchedule" "node-role.kubernetes.io/master:NoSchedule")
    
    for taint in "${taints[@]}"; do
        local taint_key="${taint%%:*}"
        
        # 检查污点是否存在
        if kubectl get node "$node_name" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null | grep -q "$taint_key"; then
            info "正在移除污点: $taint_key"
            kubectl taint nodes "$node_name" "$taint-" 2>/dev/null || true
            info "污点 $taint_key 已移除"
        else
            info "污点 $taint_key 不存在，跳过"
        fi
    done
    
    info "control-plane 去污点模块完成"
}

# ============================================================================
# 主函数
# ============================================================================
main() {
    info "=========================================="
    info "开始执行 Kubernetes 集群初始化脚本"
    info "=========================================="
    
    # 检查 root 权限
    check_root
    
    # 执行各模块
    disable_swap
    load_kernel_modules
    configure_sysctl
    install_containerd
    install_kubernetes
    init_cluster
    install_calico
    untaint_control_plane
    
    info "=========================================="
    info "Kubernetes 集群初始化完成！"
    info "=========================================="
    
    # 显示集群状态
    info "集群节点状态:"
    kubectl get nodes -o wide
    
    info ""
    info "下一步: 运行 02_setup_storage.sh 配置存储类"
}

# 执行主函数
main "$@"
