#!/bin/bash
#
# 03_deploy_stack.sh - AIOps 技术栈部署脚本
# 
# 用途: 使用 Helm 部署完整的 AIOps 技术栈
# 前置条件: 已运行 01_init_k8s.sh 和 02_setup_storage.sh
#
# 使用方法:
#   sudo ./03_deploy_stack.sh [--model MODEL_NAME]
#
# 选项:
#   --model MODEL_NAME  指定 Ollama 使用的模型 (默认: llama3)
#                       可选: gemma:2b, qwen:1.8b, tinyllama
#

set -euo pipefail

# ============================================================================
# 全局变量
# ============================================================================
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3}"

# Helm 仓库配置
declare -A HELM_REPOS=(
    ["vm"]="https://victoriametrics.github.io/helm-charts"
    ["grafana"]="https://grafana.github.io/helm-charts"
    ["argo"]="https://argoproj.github.io/argo-helm"
    ["k8sgpt"]="https://charts.k8sgpt.ai"
    ["ollama-helm"]="https://otwld.github.io/ollama-helm"
)

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            OLLAMA_MODEL="$2"
            shift 2
            ;;
        *)
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

# 检查 kubectl 可用性
check_kubectl() {
    if ! check_command kubectl; then
        error_exit "kubectl 未找到，请先运行 01_init_k8s.sh 初始化集群"
    fi
    
    if ! kubectl cluster-info &>/dev/null; then
        error_exit "无法连接到 Kubernetes 集群，请检查集群状态"
    fi
    
    info "kubectl 可用性检查通过"
}

# 检查 helm 可用性
check_helm() {
    if ! check_command helm; then
        error_exit "helm 未找到，请先安装 Helm: https://helm.sh/docs/intro/install/"
    fi
    
    info "helm 可用性检查通过"
}

# 创建命名空间（幂等）
ensure_namespace() {
    local ns=$1
    if ! kubectl get namespace "$ns" &>/dev/null; then
        info "创建命名空间: $ns"
        kubectl create namespace "$ns"
    else
        info "命名空间 $ns 已存在"
    fi
}

# 等待 Pods 就绪
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
    kubectl get pods -n "$namespace" -l "$label"
    return 1
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

# 检查 Helm release 是否存在
helm_release_exists() {
    local release=$1
    local namespace=$2
    helm status "$release" -n "$namespace" &>/dev/null
}


# ============================================================================
# 模块 1: Helm 仓库配置 (需求 6.1, 6.2, 6.3)
# ============================================================================
configure_helm_repos() {
    info "=== 配置 Helm 仓库 ==="
    
    # 获取已存在的仓库列表
    local existing_repos=$(helm repo list -o json 2>/dev/null | grep -o '"name":"[^"]*"' | cut -d'"' -f4 || echo "")
    
    # 添加所有必要的 Helm 仓库（幂等性：已存在则跳过）
    for repo_name in "${!HELM_REPOS[@]}"; do
        local repo_url="${HELM_REPOS[$repo_name]}"
        
        if echo "$existing_repos" | grep -q "^${repo_name}$"; then
            info "Helm 仓库 $repo_name 已存在，跳过添加"
        else
            info "添加 Helm 仓库: $repo_name ($repo_url)"
            helm repo add "$repo_name" "$repo_url"
        fi
    done
    
    # 更新仓库索引
    info "更新 Helm 仓库索引..."
    helm repo update
    
    info "Helm 仓库配置模块完成"
}


# ============================================================================
# 模块 2: VictoriaMetrics Stack 部署 (需求 7.1, 7.2, 7.3, 7.4)
# ============================================================================
deploy_victoria_metrics() {
    info "=== 部署 VictoriaMetrics Stack ==="
    
    local namespace="monitoring"
    local release="victoria-metrics"
    
    # 创建命名空间
    ensure_namespace "$namespace"
    
    # 检查 Helm release 是否存在（幂等性）
    if helm_release_exists "$release" "$namespace"; then
        info "Helm release $release 已存在，执行升级..."
    else
        info "安装新的 Helm release: $release"
    fi
    
    # 使用 helm upgrade --install 部署 victoria-metrics-k8s-stack
    info "部署 VictoriaMetrics Stack..."
    helm upgrade --install "$release" vm/victoria-metrics-k8s-stack \
        --namespace "$namespace" \
        --set grafana.enabled=true \
        --set grafana.adminPassword=admin \
        --set grafana.resources.requests.memory=128Mi \
        --set grafana.resources.requests.cpu=100m \
        --set grafana.resources.limits.memory=256Mi \
        --set grafana.resources.limits.cpu=200m \
        --set vmsingle.spec.resources.requests.memory=256Mi \
        --set vmsingle.spec.resources.limits.memory=512Mi \
        --wait \
        --timeout 10m
    
    # 等待 Pods 就绪
    info "等待 VictoriaMetrics Pods 就绪..."
    sleep 10
    wait_for_pods "$namespace" "app.kubernetes.io/instance=$release" 300 || true
    
    info "VictoriaMetrics Stack 部署模块完成"
}


# ============================================================================
# 模块 3: Loki Stack 部署 (需求 8.1, 8.2, 8.3, 8.4)
# ============================================================================
deploy_loki_stack() {
    info "=== 部署 Loki Stack ==="
    
    local namespace="logging"
    local release="loki"
    
    # 创建命名空间
    ensure_namespace "$namespace"
    
    # 检查 Helm release 是否存在（幂等性）
    if helm_release_exists "$release" "$namespace"; then
        info "Helm release $release 已存在，执行升级..."
    else
        info "安装新的 Helm release: $release"
    fi
    
    # 使用 helm upgrade --install 部署 loki-stack
    info "部署 Loki Stack..."
    helm upgrade --install "$release" grafana/loki-stack \
        --namespace "$namespace" \
        --set loki.persistence.enabled=true \
        --set loki.persistence.size=5Gi \
        --set loki.resources.requests.memory=128Mi \
        --set loki.resources.requests.cpu=100m \
        --set loki.resources.limits.memory=256Mi \
        --set loki.resources.limits.cpu=200m \
        --set promtail.enabled=true \
        --set promtail.resources.requests.memory=64Mi \
        --set promtail.resources.requests.cpu=50m \
        --set promtail.resources.limits.memory=128Mi \
        --set promtail.resources.limits.cpu=100m \
        --set grafana.enabled=false \
        --wait \
        --timeout 10m
    
    # 等待 Pods 就绪
    info "等待 Loki Pods 就绪..."
    sleep 10
    wait_for_pods "$namespace" "app=loki" 300 || true
    
    info "Loki Stack 部署模块完成"
}


# ============================================================================
# 模块 4: Argo CD 部署 (需求 9.1, 9.2, 9.3)
# ============================================================================
deploy_argocd() {
    info "=== 部署 Argo CD ==="
    
    local namespace="argocd"
    local release="argocd"
    
    # 创建命名空间
    ensure_namespace "$namespace"
    
    # 检查 Helm release 是否存在（幂等性）
    if helm_release_exists "$release" "$namespace"; then
        info "Helm release $release 已存在，执行升级..."
    else
        info "安装新的 Helm release: $release"
    fi
    
    # 使用 helm upgrade --install 部署 argo-cd
    info "部署 Argo CD..."
    helm upgrade --install "$release" argo/argo-cd \
        --namespace "$namespace" \
        --set server.service.type=ClusterIP \
        --set server.resources.requests.memory=128Mi \
        --set server.resources.requests.cpu=100m \
        --set server.resources.limits.memory=256Mi \
        --set server.resources.limits.cpu=200m \
        --set controller.resources.requests.memory=256Mi \
        --set controller.resources.limits.memory=512Mi \
        --set repoServer.resources.requests.memory=128Mi \
        --set repoServer.resources.limits.memory=256Mi \
        --wait \
        --timeout 10m
    
    # 等待 Pods 就绪
    info "等待 Argo CD Pods 就绪..."
    sleep 10
    wait_for_pods "$namespace" "app.kubernetes.io/instance=$release" 300 || true
    
    info "Argo CD 部署模块完成"
}


# ============================================================================
# 模块 5: Ollama AI 后端部署 (需求 10.1, 10.2, 10.3, 10.4, 10.5)
# ============================================================================
deploy_ollama() {
    info "=== 部署 Ollama AI 后端 ==="
    info "使用模型: $OLLAMA_MODEL"
    
    local namespace="ai"
    local release="ollama"
    
    # 创建命名空间
    ensure_namespace "$namespace"
    
    # 检查 Helm release 是否存在（幂等性）
    if helm_release_exists "$release" "$namespace"; then
        info "Helm release $release 已存在，执行升级..."
    else
        info "安装新的 Helm release: $release"
    fi
    
    # 使用 helm upgrade --install 部署 ollama
    # 配置资源限制和 post-start hook 自动拉取模型
    info "部署 Ollama..."
    helm upgrade --install "$release" ollama-helm/ollama \
        --namespace "$namespace" \
        --set resources.requests.memory=2Gi \
        --set resources.requests.cpu=500m \
        --set resources.limits.memory=4Gi \
        --set resources.limits.cpu=2000m \
        --set ollama.models[0]="$OLLAMA_MODEL" \
        --set service.type=ClusterIP \
        --set service.port=11434 \
        --wait \
        --timeout 15m
    
    # 等待 Pods 就绪
    info "等待 Ollama Pods 就绪..."
    sleep 10
    wait_for_deployment "$namespace" "$release" 600 || true
    
    # 验证模型拉取（可能需要额外时间）
    info "Ollama 部署完成，模型 $OLLAMA_MODEL 将在 Pod 启动后自动拉取"
    info "可用的轻量模型选项: gemma:2b, qwen:1.8b, tinyllama"
    
    info "Ollama AI 后端部署模块完成"
}


# ============================================================================
# 模块 6: K8sGPT Operator 部署 (需求 11.1, 11.4)
# ============================================================================
deploy_k8sgpt() {
    info "=== 部署 K8sGPT Operator ==="
    
    local namespace="k8sgpt"
    local release="k8sgpt-operator"
    
    # 创建命名空间
    ensure_namespace "$namespace"
    
    # 检查 Helm release 是否存在（幂等性）
    if helm_release_exists "$release" "$namespace"; then
        info "Helm release $release 已存在，执行升级..."
    else
        info "安装新的 Helm release: $release"
    fi
    
    # 使用 helm upgrade --install 部署 k8sgpt-operator
    info "部署 K8sGPT Operator..."
    helm upgrade --install "$release" k8sgpt/k8sgpt-operator \
        --namespace "$namespace" \
        --set resources.requests.memory=64Mi \
        --set resources.requests.cpu=50m \
        --set resources.limits.memory=128Mi \
        --set resources.limits.cpu=100m \
        --wait \
        --timeout 10m
    
    # 等待 Operator Pods 就绪
    info "等待 K8sGPT Operator Pods 就绪..."
    sleep 10
    wait_for_pods "$namespace" "app.kubernetes.io/instance=$release" 300 || true
    
    info "K8sGPT Operator 部署模块完成"
}


# ============================================================================
# 主函数
# ============================================================================
main() {
    info "=========================================="
    info "开始执行 AIOps 技术栈部署脚本"
    info "=========================================="
    
    # 检查 root 权限
    check_root
    
    # 检查 kubectl 和 helm 可用性
    check_kubectl
    check_helm
    
    # 执行各模块
    configure_helm_repos
    deploy_victoria_metrics
    deploy_loki_stack
    deploy_argocd
    deploy_ollama
    deploy_k8sgpt
    
    info "=========================================="
    info "AIOps 技术栈部署完成！"
    info "=========================================="
    
    # 显示部署状态
    info "Helm Releases 状态:"
    helm list -A
    
    info ""
    info "各命名空间 Pod 状态:"
    for ns in monitoring logging argocd ai k8sgpt; do
        info "--- $ns ---"
        kubectl get pods -n "$ns" 2>/dev/null || echo "命名空间 $ns 不存在"
    done
    
    info ""
    info "下一步: 运行以下命令应用集成配置:"
    info "  kubectl apply -f k8sgpt_integration.yaml"
    info ""
    info "访问 Grafana:"
    info "  kubectl port-forward -n monitoring svc/victoria-metrics-grafana 3000:80"
    info "  用户名: admin, 密码: admin"
    info ""
    info "访问 Argo CD:"
    info "  kubectl port-forward -n argocd svc/argocd-server 8080:443"
    info "  用户名: admin, 密码: kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

# 执行主函数
main "$@"
