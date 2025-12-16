#!/bin/bash
#
# verify_deployment.sh - AIOps 平台部署验证脚本
# 
# 用途: 验证所有组件健康状态并输出访问信息
# 前置条件: 已运行 01_init_k8s.sh, 02_setup_storage.sh, 03_deploy_stack.sh
#
# 使用方法:
#   ./verify_deployment.sh
#

set -euo pipefail

# ============================================================================
# 全局变量
# ============================================================================
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# ============================================================================
# 通用函数
# ============================================================================

# 日志输出函数
info() {
    echo -e "\033[32m[INFO]\033[0m $(date '+%Y-%m-%d %H:%M:%S') $*"
}

warn() {
    echo -e "\033[33m[WARN]\033[0m $(date '+%Y-%m-%d %H:%M:%S') $*"
    ((WARN_COUNT++)) || true
}

error() {
    echo -e "\033[31m[ERROR]\033[0m $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

pass() {
    echo -e "\033[32m[PASS]\033[0m $*"
    ((PASS_COUNT++)) || true
}

fail() {
    echo -e "\033[31m[FAIL]\033[0m $*"
    ((FAIL_COUNT++)) || true
}

# 检查命令是否存在
check_command() {
    local cmd=$1
    if ! command -v "$cmd" &>/dev/null; then
        return 1
    fi
    return 0
}

# 打印分隔线
print_separator() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}


# ============================================================================
# 健康检查函数
# ============================================================================

# 检查 kubectl 可用性
check_kubectl() {
    print_separator "检查 kubectl 可用性"
    
    if ! check_command kubectl; then
        fail "kubectl 未找到"
        return 1
    fi
    pass "kubectl 已安装"
    
    if ! kubectl cluster-info &>/dev/null; then
        fail "无法连接到 Kubernetes 集群"
        return 1
    fi
    pass "Kubernetes 集群连接正常"
    
    return 0
}

# 检查节点状态
check_nodes() {
    print_separator "检查 Kubernetes 节点"
    
    local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo "0")
    local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [[ $ready_nodes -eq $total_nodes && $total_nodes -gt 0 ]]; then
        pass "所有节点就绪 ($ready_nodes/$total_nodes)"
    else
        fail "部分节点未就绪 ($ready_nodes/$total_nodes)"
    fi
    
    kubectl get nodes -o wide
}

# 检查 StorageClass
check_storageclass() {
    print_separator "检查 StorageClass"
    
    local default_sc=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)
    
    if [[ -n "$default_sc" ]]; then
        pass "默认 StorageClass: $default_sc"
    else
        fail "未找到默认 StorageClass"
    fi
    
    kubectl get storageclass
}

# 检查命名空间中的 Pod 状态
check_namespace_pods() {
    local namespace=$1
    local component_name=$2
    
    if ! kubectl get namespace "$namespace" &>/dev/null; then
        fail "$component_name: 命名空间 $namespace 不存在"
        return 1
    fi
    
    local total_pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | wc -l || echo "0")
    local running_pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    local pending_pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep -c "Pending" || echo "0")
    local failed_pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep -cE "(Error|CrashLoopBackOff|Failed)" || echo "0")
    
    if [[ $total_pods -eq 0 ]]; then
        warn "$component_name: 命名空间 $namespace 中没有 Pod"
        return 1
    elif [[ $running_pods -eq $total_pods ]]; then
        pass "$component_name: 所有 Pod 运行正常 ($running_pods/$total_pods)"
        return 0
    elif [[ $failed_pods -gt 0 ]]; then
        fail "$component_name: 存在失败的 Pod ($failed_pods 个失败, $running_pods/$total_pods 运行中)"
        return 1
    elif [[ $pending_pods -gt 0 ]]; then
        warn "$component_name: 存在等待中的 Pod ($pending_pods 个等待, $running_pods/$total_pods 运行中)"
        return 1
    else
        warn "$component_name: 部分 Pod 状态异常 ($running_pods/$total_pods 运行中)"
        return 1
    fi
}

# 检查 Calico CNI
check_calico() {
    print_separator "检查 Calico CNI"
    
    # 检查 tigera-operator 命名空间
    if kubectl get namespace tigera-operator &>/dev/null; then
        check_namespace_pods "tigera-operator" "Calico Operator"
    fi
    
    # 检查 calico-system 命名空间
    if kubectl get namespace calico-system &>/dev/null; then
        check_namespace_pods "calico-system" "Calico System"
    else
        warn "Calico: calico-system 命名空间不存在"
    fi
}

# 检查 VictoriaMetrics
check_victoria_metrics() {
    print_separator "检查 VictoriaMetrics Stack"
    
    check_namespace_pods "monitoring" "VictoriaMetrics"
    
    # 检查 Helm release
    if helm status victoria-metrics -n monitoring &>/dev/null; then
        pass "VictoriaMetrics Helm release 存在"
    else
        fail "VictoriaMetrics Helm release 不存在"
    fi
    
    echo ""
    kubectl get pods -n monitoring
}

# 检查 Loki Stack
check_loki() {
    print_separator "检查 Loki Stack"
    
    check_namespace_pods "logging" "Loki"
    
    # 检查 Helm release
    if helm status loki -n logging &>/dev/null; then
        pass "Loki Helm release 存在"
    else
        fail "Loki Helm release 不存在"
    fi
    
    echo ""
    kubectl get pods -n logging
}

# 检查 Argo CD
check_argocd() {
    print_separator "检查 Argo CD"
    
    check_namespace_pods "argocd" "Argo CD"
    
    # 检查 Helm release
    if helm status argocd -n argocd &>/dev/null; then
        pass "Argo CD Helm release 存在"
    else
        fail "Argo CD Helm release 不存在"
    fi
    
    echo ""
    kubectl get pods -n argocd
}

# 检查 Ollama
check_ollama() {
    print_separator "检查 Ollama AI 后端"
    
    check_namespace_pods "ai" "Ollama"
    
    # 检查 Helm release
    if helm status ollama -n ai &>/dev/null; then
        pass "Ollama Helm release 存在"
    else
        fail "Ollama Helm release 不存在"
    fi
    
    # 检查服务端点
    if kubectl get svc ollama -n ai &>/dev/null; then
        pass "Ollama 服务端点存在"
    else
        warn "Ollama 服务端点不存在"
    fi
    
    echo ""
    kubectl get pods -n ai
}

# 检查 K8sGPT
check_k8sgpt() {
    print_separator "检查 K8sGPT Operator"
    
    check_namespace_pods "k8sgpt" "K8sGPT"
    
    # 检查 Helm release
    if helm status k8sgpt-operator -n k8sgpt &>/dev/null; then
        pass "K8sGPT Operator Helm release 存在"
    else
        fail "K8sGPT Operator Helm release 不存在"
    fi
    
    # 检查 K8sGPT CR
    if kubectl get k8sgpt -n k8sgpt &>/dev/null 2>&1; then
        local cr_count=$(kubectl get k8sgpt -n k8sgpt --no-headers 2>/dev/null | wc -l || echo "0")
        if [[ $cr_count -gt 0 ]]; then
            pass "K8sGPT CR 已配置 ($cr_count 个)"
        else
            warn "K8sGPT CR 未配置，请运行: kubectl apply -f k8sgpt_integration.yaml"
        fi
    else
        warn "K8sGPT CRD 可能未安装或 CR 未配置"
    fi
    
    echo ""
    kubectl get pods -n k8sgpt
}


# ============================================================================
# 访问信息输出函数
# ============================================================================

# 输出 Grafana 访问信息
print_grafana_info() {
    print_separator "Grafana 访问信息"
    
    echo "获取 Grafana 初始管理员密码:"
    echo ""
    echo "  # VictoriaMetrics Stack 部署的 Grafana"
    echo "  kubectl get secret -n monitoring victoria-metrics-grafana -o jsonpath=\"{.data.admin-password}\" | base64 -d; echo"
    echo ""
    echo "  # 或者如果使用默认密码"
    echo "  默认用户名: admin"
    echo "  默认密码: admin (如果部署时未修改)"
    echo ""
}

# 输出 Argo CD 访问信息
print_argocd_info() {
    print_separator "Argo CD 访问信息"
    
    echo "获取 Argo CD 初始管理员密码:"
    echo ""
    echo "  kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d; echo"
    echo ""
    echo "  用户名: admin"
    echo ""
}

# 输出端口转发命令
print_port_forward_commands() {
    print_separator "端口转发命令"
    
    echo "使用以下命令访问各组件 Web UI:"
    echo ""
    echo "# Grafana (端口 3000)"
    echo "kubectl port-forward -n monitoring svc/victoria-metrics-grafana 3000:80"
    echo ""
    echo "# Argo CD (端口 8080)"
    echo "kubectl port-forward -n argocd svc/argocd-server 8080:443"
    echo ""
    echo "# VictoriaMetrics (端口 8428)"
    echo "kubectl port-forward -n monitoring svc/vmsingle-victoria-metrics-victoria-metrics-k8s-stack 8428:8428"
    echo ""
    echo "# Ollama API (端口 11434)"
    echo "kubectl port-forward -n ai svc/ollama 11434:11434"
    echo ""
    echo "提示: 添加 --address 0.0.0.0 可从远程访问，例如:"
    echo "kubectl port-forward -n monitoring svc/victoria-metrics-grafana 3000:80 --address 0.0.0.0"
    echo ""
}

# 输出 K8sGPT 测试命令
print_k8sgpt_test_commands() {
    print_separator "K8sGPT 测试命令"
    
    echo "测试 K8sGPT AI 诊断功能:"
    echo ""
    echo "# 查看 K8sGPT CR 状态"
    echo "kubectl get k8sgpt -n k8sgpt -o yaml"
    echo ""
    echo "# 查看 K8sGPT 分析结果"
    echo "kubectl get results -n k8sgpt"
    echo ""
    echo "# 测试 Ollama 连接 (在集群内)"
    echo "kubectl run test-ollama --rm -it --image=curlimages/curl --restart=Never -- \\"
    echo "  curl -s http://ollama.ai.svc.cluster.local:11434/api/tags"
    echo ""
    echo "# 检查 Ollama 已加载的模型"
    echo "kubectl exec -n ai deploy/ollama -- ollama list"
    echo ""
    echo "# 手动触发 K8sGPT 分析 (如果安装了 k8sgpt CLI)"
    echo "# k8sgpt analyze"
    echo ""
}

# 输出 Helm releases 状态
print_helm_releases() {
    print_separator "Helm Releases 状态"
    
    helm list -A
}


# ============================================================================
# 汇总报告
# ============================================================================

print_summary() {
    print_separator "验证汇总报告"
    
    echo ""
    echo "检查结果统计:"
    echo "  通过: $PASS_COUNT"
    echo "  失败: $FAIL_COUNT"
    echo "  警告: $WARN_COUNT"
    echo ""
    
    if [[ $FAIL_COUNT -eq 0 ]]; then
        echo -e "\033[32m✓ 所有关键检查通过！AIOps 平台部署成功。\033[0m"
    else
        echo -e "\033[31m✗ 存在 $FAIL_COUNT 个失败项，请检查上述错误信息。\033[0m"
    fi
    
    if [[ $WARN_COUNT -gt 0 ]]; then
        echo -e "\033[33m! 存在 $WARN_COUNT 个警告项，建议检查。\033[0m"
    fi
    
    echo ""
}


# ============================================================================
# 主函数
# ============================================================================
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           AIOps 平台部署验证脚本                                  ║"
    echo "║           验证所有组件健康状态并输出访问信息                       ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # 检查 kubectl 可用性
    if ! check_kubectl; then
        error "无法继续验证，请确保 kubectl 已配置且集群可访问"
        exit 1
    fi
    
    # 检查 helm 可用性
    if ! check_command helm; then
        warn "helm 未找到，将跳过 Helm release 检查"
    fi
    
    # 执行各组件健康检查
    check_nodes
    check_storageclass
    check_calico
    check_victoria_metrics
    check_loki
    check_argocd
    check_ollama
    check_k8sgpt
    
    # 输出 Helm releases 状态
    if check_command helm; then
        print_helm_releases
    fi
    
    # 输出访问信息
    print_grafana_info
    print_argocd_info
    print_port_forward_commands
    print_k8sgpt_test_commands
    
    # 输出汇总报告
    print_summary
    
    # 返回适当的退出码
    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

# 执行主函数
main "$@"
