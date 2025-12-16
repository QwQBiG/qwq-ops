#!/bin/bash
#
# 02_setup_storage.sh - 存储类配置脚本
# 
# 用途: 安装 Local Path Provisioner 并配置默认 StorageClass
# 前置条件: 已运行 01_init_k8s.sh 完成 Kubernetes 集群初始化
#
# 使用方法:
#   sudo ./02_setup_storage.sh
#

set -euo pipefail

# ============================================================================
# 全局变量
# ============================================================================
LOCAL_PATH_PROVISIONER_VERSION="v0.0.26"
LOCAL_PATH_PROVISIONER_URL="https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml"

# ============================================================================
# 通用函数 (复用自 01_init_k8s.sh)
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


# 检查 kubectl 可用性
check_kubectl() {
    if ! check_command kubectl; then
        error_exit "kubectl 未找到，请先运行 01_init_k8s.sh 初始化集群"
    fi
    
    # 检查是否能连接到集群
    if ! kubectl cluster-info &>/dev/null; then
        error_exit "无法连接到 Kubernetes 集群，请检查集群状态"
    fi
    
    info "kubectl 可用性检查通过"
}

# 等待 Deployment 就绪
wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=${3:-300}
    
    info "等待 Deployment $deployment 在 $namespace 命名空间中就绪..."
    
    local end_time=$((SECONDS + timeout))
    while [[ $SECONDS -lt $end_time ]]; do
        local ready=$(kubectl get deployment "$deployment" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        local desired=$(kubectl get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        
        if [[ -n "$ready" && "$ready" -ge "$desired" ]]; then
            info "Deployment $deployment 已就绪 ($ready/$desired)"
            return 0
        fi
        
        echo -n "."
        sleep 5
    done
    
    echo ""
    warn "等待超时，Deployment $deployment 可能未就绪"
    return 1
}


# ============================================================================
# 模块 1: 安装 Local Path Provisioner (需求 5.1)
# ============================================================================
install_local_path_provisioner() {
    info "=== 安装 Local Path Provisioner ==="
    
    # 检查 Provisioner 是否已安装（幂等性）
    if kubectl get deployment local-path-provisioner -n local-path-storage &>/dev/null; then
        info "Local Path Provisioner 已安装，跳过安装"
        return 0
    fi
    
    # 使用 kubectl apply 安装 Local Path Provisioner
    info "正在安装 Local Path Provisioner (版本: $LOCAL_PATH_PROVISIONER_VERSION)..."
    kubectl apply -f "$LOCAL_PATH_PROVISIONER_URL"
    
    # 等待 Deployment 就绪
    wait_for_deployment "local-path-storage" "local-path-provisioner" 120
    
    info "Local Path Provisioner 安装模块完成"
}


# ============================================================================
# 模块 2: 配置默认 StorageClass (需求 5.2, 5.3)
# ============================================================================
configure_default_storageclass() {
    info "=== 配置默认 StorageClass ==="
    
    local target_sc="local-path"
    local default_annotation="storageclass.kubernetes.io/is-default-class"
    
    # 检查 local-path StorageClass 是否存在
    if ! kubectl get storageclass "$target_sc" &>/dev/null; then
        error_exit "StorageClass $target_sc 不存在，请先安装 Local Path Provisioner"
    fi
    
    # 获取当前所有默认 StorageClass
    info "检查当前默认 StorageClass..."
    local current_defaults=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
    
    # 移除其他 SC 的默认标记（如有）
    if [[ -n "$current_defaults" ]]; then
        while IFS= read -r sc_name; do
            if [[ -n "$sc_name" && "$sc_name" != "$target_sc" ]]; then
                info "移除 StorageClass $sc_name 的默认标记..."
                kubectl patch storageclass "$sc_name" -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
            fi
        done <<< "$current_defaults"
    fi
    
    # 检查 local-path 是否已是默认
    local is_default=$(kubectl get storageclass "$target_sc" -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || echo "")
    
    if [[ "$is_default" == "true" ]]; then
        info "StorageClass $target_sc 已是默认存储类"
    else
        # 设置 local-path 为默认 StorageClass
        info "设置 StorageClass $target_sc 为默认存储类..."
        kubectl patch storageclass "$target_sc" -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
        info "StorageClass $target_sc 已设置为默认"
    fi
    
    # 验证只有一个默认 SC
    verify_single_default_sc
    
    info "默认 StorageClass 配置模块完成"
}


# ============================================================================
# 验证函数: 确保只有一个默认 StorageClass (需求 5.3)
# ============================================================================
verify_single_default_sc() {
    info "验证默认 StorageClass 配置..."
    
    local default_count=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . || echo "0")
    
    if [[ "$default_count" -eq 1 ]]; then
        info "验证通过: 只有一个默认 StorageClass"
    elif [[ "$default_count" -eq 0 ]]; then
        error_exit "验证失败: 没有默认 StorageClass"
    else
        error_exit "验证失败: 存在 $default_count 个默认 StorageClass"
    fi
}


# ============================================================================
# 主函数
# ============================================================================
main() {
    info "=========================================="
    info "开始执行存储类配置脚本"
    info "=========================================="
    
    # 检查 root 权限
    check_root
    
    # 检查 kubectl 可用性
    check_kubectl
    
    # 执行各模块
    install_local_path_provisioner
    configure_default_storageclass
    
    info "=========================================="
    info "存储类配置完成！"
    info "=========================================="
    
    # 显示 StorageClass 状态
    info "当前 StorageClass 列表:"
    kubectl get storageclass
    
    info ""
    info "下一步: 运行 03_deploy_stack.sh 部署 AIOps 技术栈"
}

# 执行主函数
main "$@"
