# 操作手册

[English](operations.en.md) · [返回首页](../README.md) · [架构说明](architecture.md)

本手册中的集群操作使用当前用户的 kubeconfig。执行前先运行 `kubectl config current-context`，确认目标；主机初始化只用于空白专用主机，不负责修复或升级已有集群。

## 配置与预览

组件版本与默认值集中在 `config/versions.env`，各组件的资源、持久化和保留期在 `config/helm/`。环境变量可以临时覆盖版本文件中的值：

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `POD_CIDR` | `10.244.0.0/16` | 初始化集群时使用的 Pod IPv4 网段 |
| `WAIT_TIMEOUT` | `300s` | 每次资源创建、就绪或滚动更新的等待上限 |
| `HELM_TIMEOUT` | `15m` | 每个 Helm release 的安装或升级等待上限 |
| `REQUEST_TIMEOUT` | `30s` | 单次 kubectl API 请求的超时 |

Pod 网段需要为 `/24` 或更大的 IPv4 网络（前缀长度不超过 24），并避开主机网络与默认 Service 网段 `10.96.0.0/12`。例如，确认 `10.245.0.0/16` 在目标环境中不冲突后，可在首次初始化时指定：

```bash
sudo env POD_CIDR=10.245.0.0/16 bash scripts/bootstrap.sh
```

初始化也会检查固定 Service 网段是否与主机地址网段冲突。若主机已经使用 `10.96.0.0/12` 范围内的网络，只调整 `POD_CIDR` 无法解决冲突，需要先调整主机网络或另行规划集群。

已有 containerd 配置会按实际默认运行时检查 `SystemdCgroup`；其他未使用运行时的设置不能代替它。无法确认的配置会停止安装，交由使用者检查。

`sudo` 不一定保留调用者的环境变量；使用 `sudo env` 明确传入需要的值。已有集群不能通过重新运行初始化脚本更换网段。部署时若仍有正常进展而等待时间不足，可以增加上限；这些时间按请求或组件分别计算，并非整个部署的总时限：

```bash
HELM_TIMEOUT=30m WAIT_TIMEOUT=900s REQUEST_TIMEOUT=60s bash scripts/deploy.sh
```

修改配置后先检查渲染结果：

```bash
bash scripts/deploy.sh --help
bash scripts/deploy.sh --render
```

`--render` 需要访问 Helm 仓库，但不访问集群。它验证模板能否生成，不验证目标集群的权限、CRD、可用资源或数据兼容性，也不是对已有 release 的完整差异比较。渲染输出包含 Secret，不要提交仓库或公开分享。

部署时通过 `--model MODEL` 选择模型。脚本会把同一模型写入 Ollama 配置和 K8sGPT 集成。`--model` 只覆盖本次调用；下次部署时需要再次传入同一模型，或先在 `config/versions.env` 中设置 `OLLAMA_MODEL`，否则会恢复默认选择。换模型前评估内存与磁盘，并确认该模型在下载源可用。

Ollama 启动时优先使用本地已有模型，缺失时才下载。重启或重复部署不会自动刷新同名 tag；要更新默认模型 `qwen2.5:1.5b`，显式执行：

```bash
kubectl exec -n ai deploy/ollama -- ollama pull qwen2.5:1.5b
```

如果选择了其他模型，将命令中的模型名替换为当前选择。`ollama pull` 只下载或更新本地模型，不会更改 K8sGPT 使用的模型。

## 访问界面

下面每条端口转发命令在单独的终端中运行，按 `Ctrl+C` 停止。默认只监听本机回环地址。

```bash
kubectl port-forward -n monitoring svc/grafana 3000:80
kubectl port-forward -n argocd svc/argocd-server 8080:443
kubectl port-forward -n monitoring svc/vmsingle-vm 8428:8428
kubectl port-forward -n ai svc/ollama 11434:11434
```

| 组件 | 本机地址 |
| --- | --- |
| Grafana | `http://127.0.0.1:3000` |
| Argo CD | `https://127.0.0.1:8080`，初始为自签名证书 |
| VictoriaMetrics | `http://127.0.0.1:8428/vmui` |
| Ollama 模型列表 | `http://127.0.0.1:11434/api/tags` |

Grafana 与 Argo CD 的初始用户名均为 `admin`。从 Secret 获取密码，不猜测默认值：

```bash
kubectl get secret -n monitoring grafana -o jsonpath='{.data.admin-password}' | base64 --decode
kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode
```

首次登录后更改密码；Grafana 还需要按下述步骤同步凭据。Argo CD 初始密码 Secret 可能已被管理员删除，此时使用现有凭据或按上游恢复流程处理。远程使用时，通过 SSH 隧道访问端口转发所在主机；需要长期对外服务时，先设计 TLS、认证和访问控制。

### 修改 Grafana 管理员密码

先准备一个长随机 ASCII 密码，再在 Grafana 界面中修改 `admin` 的密码，保留用户名。使用英文字母、数字和 ASCII 符号，以兼容固定 sidecar 客户端的 [Basic Authentication 密码编码](https://github.com/psf/requests/blob/v2.32.5/src/requests/auth.py#L51-L55)。Grafana 的配置 sidecar 使用 `monitoring/grafana` Secret 中的凭据调用需要 Basic Authentication 的 [reload 接口](https://grafana.com/docs/grafana/latest/developer-resources/api-reference/http-api/api-legacy/admin/#reload-provisioning-configurations)。界面改密后，需要把同一密码同步到 Secret，再重启 Grafana，否则 sidecar 会继续使用旧密码并收到 `401`。单独修改 Secret 也不会更新数据库中已有管理员的密码；[`admin_password` 只在首次启动时设置](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/#admin_password)。

在目标 Linux 主机的交互终端执行下面命令，提示时输入刚在界面设置的新密码。密码不会显示，也不会写入命令参数或历史；补丁只更新 `admin-password`，保留 `admin-user` 和 Secret 的元数据。输入为空、含非 ASCII 字符或两次不一致时会停止；若已经设置了非 ASCII 密码，先在界面换成兼容的密码再重试。重启会短暂中断 Grafana，并结束已有的端口转发。

```bash
(
set -euo pipefail
python3 - <<'PY' | kubectl patch secret grafana -n monitoring --type=merge --patch-file=/dev/stdin
import base64
import getpass
import json
import sys

password = getpass.getpass("Grafana password just set in the UI: ")
if not password.isascii():
    sys.exit("First set an ASCII password in the Grafana UI, then retry; Secret unchanged.")
if not password or password != getpass.getpass("Repeat password: "):
    sys.exit("Passwords are empty or do not match; Secret unchanged.")
encoded = base64.b64encode(password.encode("ascii")).decode("ascii")
print(json.dumps({"data": {"admin-password": encoded}}))
PY
kubectl rollout restart deployment/grafana -n monitoring
kubectl rollout status deployment/grafana -n monitoring --timeout=300s
)
```

滚动更新成功后，重新运行本节中的 Grafana 端口转发，退出并用新密码登录。然后用两个 sidecar 当前加载的凭据分别调用 reload 接口；下面命令应各输出一次 `200`。若出现 `401`，检查界面密码、Secret 和重建后的 Pod 是否一致。

```bash
(
set -e
for container in grafana-sc-datasources grafana-sc-dashboard; do
    kubectl exec -i -n monitoring deployment/grafana -c "$container" -- python - <<'PY'
import os
import requests

response = requests.post(os.environ["REQ_URL"],
                         auth=(os.environ["REQ_USERNAME"], os.environ["REQ_PASSWORD"]), timeout=30)
response.raise_for_status()
print(response.status_code)
PY
done
)
```

## 验证与排障

```bash
bash scripts/verify.sh
kubectl get nodes -o wide
kubectl get pods -A
kubectl get events -A --sort-by=.metadata.creationTimestamp
helm list -A
```

验证脚本检查节点、存储类、相关命名空间的 Pod、Helm release、K8sGPT 配置及模型可用性，也会检查关键 Deployment、StatefulSet 和 DaemonSet 是否存在且完成更新。任何一项失败都需要处理；API 无法访问、空 Pod 列表或运行中但未就绪的 Pod 不应视为成功。检查通过不代表已验证指标和日志的实际传输或诊断质量。

在有完整控制器检查的平台命名空间中，保留的失败 Pod 和正在删除的旧 Pod 会显示警告，不计入当前活动实例；仍必须存在当前实例，且对应控制器全部就绪。`kube-system`、Calico 和本地存储等基础设施命名空间保持严格检查。

重新部署 K8sGPT 时，脚本先等待分析器模板中的模型、后端、服务地址和镜像与当前 K8sGPT 资源一致，再等待滚动更新。旧 Deployment 显示 Ready 并不表示 Operator 已应用新配置；配置等待超时时，先检查 Operator 日志和资源事件，再决定重试。

| 现象 | 先检查什么 |
| --- | --- |
| Pod `Pending` | `kubectl describe pod -n <namespace> <pod>` 中的调度事件、可分配内存和 PVC |
| PVC `Pending` | `kubectl get storageclass` 与 `kubectl describe pvc -n <namespace> <pvc>`；local-path 通常等消费者调度后才绑定 |
| 存储脚本拒绝副本数 | 检查 `local-path-storage/local-path-provisioner` Deployment 是否曾因维护缩容到 0；脚本不会自动扩容，需确认配置后由操作者恢复 |
| `ImagePullBackOff` | Pod 事件中的镜像地址、仓库连通性和凭据 |
| `CrashLoopBackOff` | `kubectl logs -n <namespace> <pod> --all-containers --previous` 与当前日志 |
| Helm 失败或超时 | `helm status -n <namespace> <release>` 和相关 Pod 事件，修复原因后再决定重试或回滚 |
| Grafana 没有日志 | `kubectl logs -n logging -l app.kubernetes.io/name=alloy`，以及 Loki Pod、Service 和数据源配置 |

Alloy 的日志读取位置保存在容器临时目录 `/tmp/alloy`。容器或 Pod 重建会清空这些记录，可能使 Alloy 重新读取 Kubernetes API 仍可提供的日志，增加 API 和日志写入流量。

主机初始化中断后，先查 `journalctl -u kubelet -u containerd` 和实际生成的配置。脚本发现已有集群状态会停止，避免重新初始化覆盖现状；不要直接清空 etcd、网络规则或 kubeconfig 来重试。

## 诊断与告警

```bash
kubectl exec -n ai deploy/ollama -- ollama list
kubectl get k8sgpt -n k8sgpt
kubectl get results -n k8sgpt
kubectl describe results -n k8sgpt
```

K8sGPT 结果需要结合事件和应用日志判断，不会自动修复资源。若未生成结果，先检查 Operator、分析器 Pod 和 Ollama 日志，再确认模型已加载、服务可访问以及集成配置中的模型一致。

监控栈带有规则评估和 Alertmanager 组件，但仓库不配置外部收件人。要接收通知，需要自行配置接收器和凭据，并实际测试发送与恢复通知。第三方机器人接口不一定接受 Alertmanager 的通用 Webhook 格式，应按对应渠道的协议使用接收器或适配服务。

## 已有安装与升级

旧根目录入口已迁到 `scripts/`；旧 `k8sgpt_integration.yaml` 不再单独应用，集成由部署入口管理。已有安装不能直接照着首次安装流程重跑：

1. 记录当前提交、集群版本、`helm list -A`、各 release 的 values、CRD 和持久化卷。
2. 备份数据与所需凭据，在独立环境验证恢复。导出 YAML 或 Helm values 不等于备份卷内数据；模型、日志、指标及集群状态各自需要恢复方案。
3. 阅读目标组件的升级说明。Kubernetes 需按上游允许的顺序升级；修改版本文件后运行 bootstrap 不会升级已有集群。
4. 单独规划 Loki 迁移。旧 `loki-stack` 与现在的 Loki chart、存储布局和 Alloy 采集配置不同；不要对旧 `loki` release 直接执行新部署入口。先验证数据迁移或另建环境，保留旧数据直到查询与恢复验收完成。
5. 核对新的服务名与数据源，确认模型、PVC 和凭据后再切换使用，并运行验证脚本及自己的关键业务检查。

当前日志采集使用 Alloy。Promtail 已停止维护，迁移依据见 [Grafana 官方说明](https://grafana.com/docs/loki/latest/send-data/promtail/)。回滚前同样需要核对存储格式与 CRD 的兼容性；`helm rollback` 不能恢复已经删除或迁移的数据。

## 清理实验环境

先确认当前上下文、备份需求和对应 release，再选择需要卸载的组件。卸载 K8sGPT Operator 前，先删除本项目创建的 `k8sgpt/k8sgpt` 集成实例，让仍在运行的控制器完成清理，再卸载 Operator：

```bash
kubectl delete k8sgpt k8sgpt -n k8sgpt
helm uninstall k8sgpt-operator -n k8sgpt
helm uninstall ollama -n ai
helm uninstall argocd -n argocd
helm uninstall alloy -n logging
helm uninstall loki -n logging
helm uninstall victoria-metrics -n monitoring
```

这些命令会中断对应服务。Helm 卸载后，PVC、CRD 和部分资源可能仍存在；使用 `kubectl get pvc -A` 等命令逐项检查。Grafana 的 Loki 数据源 ConfigMap 由集成清单单独创建，也需要检查留存情况。删除命名空间、PVC 或 Local Path Provisioner 可能影响数据及其他工作负载，只有明确确认归属和备份后才处理。仓库不提供自动重置主机或清空防火墙的命令。
