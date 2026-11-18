# qwq-ops

[English](README.en.md) · [架构说明](docs/architecture.md) · [操作手册](docs/operations.md) · [参与维护](CONTRIBUTING.md)

在一台 Ubuntu 主机上搭建 Kubernetes 运维实验环境：用 VictoriaMetrics 和 Grafana 查看指标，用 Loki 和 Grafana Alloy 查询日志，用 Argo CD 练习应用交付，再通过 K8sGPT 与 Ollama 分析集群问题。

项目面向学习、测试和个人实验室。它使用单节点控制面与本地磁盘存储，不提供高可用或自动备份。请在专用主机上部署，避免用于已有业务的服务器。

## 开始之前

- 主机初始化入口面向 **Ubuntu 22.04 / 24.04**，需要 `sudo`，会修改 swap、内核参数、软件源和容器运行时。
- 准备 Bash、`curl`、Python 3、`ip`（iproute2），以及可访问的软件仓库、镜像仓库、Helm 仓库和模型下载源。国内网络选项仅替换 kubeadm 使用的镜像仓库，不覆盖所有下载。
- 平台部署需要可访问集群的 `kubectl` 和与 Kubernetes 1.35 兼容的 **Helm 3**。推荐使用 CI 固定的 [v3.22.1](https://github.com/helm/helm/releases/tag/v3.22.1)，按 [Helm 3 官方安装说明](https://helm.sh/docs/v3/intro/install/)选择对应系统和架构的 release 安装包，并核对下载内容；使用包管理器时也需显式指定版本。
- 给指标、日志和模型预留资源。可从 8 核 CPU、16 GB 内存、100 GB 可用 SSD 空间规划实验机；这不是经过负载测试的容量保证，模型大小与数据保留期会改变实际用量。

安装 Helm 后先核对版本；使用推荐版本时，输出应以 `v3.22.1` 开头。选择其他版本前，先确认[官方 Kubernetes 兼容范围](https://helm.sh/docs/v3/topics/version_skew/)覆盖本项目的 Kubernetes 1.35。

```bash
helm version --short
```

复用已按本仓库配置的集群时，可跳过主机初始化，先核对版本、权限与现有组件。部署和验证流程预期使用 Calico 与 Local Path Provisioner；其他网络、存储或多节点拓扑需要自行适配。请先阅读[架构中的取舍](docs/architecture.md#单节点的取舍)。

## 部署

以下命令在目标 Linux 主机上执行。只有第一步需要 `sudo`；其余步骤使用当前用户的 kubeconfig。

```bash
git clone https://github.com/QwQBiG/qwq-ops.git
cd qwq-ops

# 仅在尚未初始化集群的专用 Ubuntu 主机上运行。
sudo bash scripts/bootstrap.sh

# 确认当前上下文就是准备部署的集群。
kubectl config current-context
kubectl get nodes

bash scripts/storage.sh
bash scripts/deploy.sh
bash scripts/verify.sh
```

初始化脚本发现已有集群状态或 kubeconfig 会停止。存储脚本发现其他默认 StorageClass 也会停止，交由使用者明确选择。失败时先检查错误和当前状态，处理原因后再继续；不要通过删除集群数据来跳过检查。

每个入口都支持 `--help`。初始化支持 `--use-aliyun-mirror`；部署支持 `--model MODEL` 和 `--render`，默认模型为 `qwen2.5:1.5b`。渲染模式输出 Helm 与集成清单，不连接集群，但仍需下载 chart。部署顺序、组件版本与参数分别放在 `scripts/`、`config/versions.env` 和 `config/helm/`。

验证脚本只读取集群状态。检查失败会返回非零退出码；检查通过表示当时检查项正常，不代表完成了业务负载、备份恢复或升级测试。Grafana、Argo CD 和诊断结果的访问方法见[操作手册](docs/operations.md)。

## 目录

```text
qwq-ops/
├── scripts/                 # 初始化、存储、部署、验证和本地检查入口
│   └── lib/                 # 公共命令与错误处理
├── config/
│   ├── versions.env         # 固定版本
│   └── helm/                # 按组件拆分的 Helm values
├── manifests/               # 跨组件集成资源
├── examples/                # 按需运行的实验示例
├── tests/                   # 无需真实集群的回归检查
├── docs/                    # 中英文架构与操作手册
├── .github/workflows/       # 自动检查
├── CONTRIBUTING.md
├── README.md
└── README.en.md
```

脚本处理执行流程，配置文件处理部署参数，文档解释如何使用与维护。各组件职责和数据流见[架构说明](docs/architecture.md)。

## 从旧目录迁移

| 旧入口 | 现在的位置 |
| --- | --- |
| `01_init_k8s.sh` | `scripts/bootstrap.sh` |
| `02_setup_storage.sh` | `scripts/storage.sh` |
| `03_deploy_stack.sh` | `scripts/deploy.sh` |
| `verify_deployment.sh` | `scripts/verify.sh` |
| `k8sgpt_integration.yaml` | 由部署入口管理 `manifests/` 中的集成资源 |

这次整理同时更换了日志采集方案和组件配置。已有安装先备份 PVC 数据、Helm values 与集群配置，再按[迁移说明](docs/operations.md#已有安装与升级)逐项评估；不要把新入口当作旧平台的一键升级工具。

## 检查与维护

开发检查入口是 `bash scripts/check.sh`。安装依赖与提交要求见[参与维护](CONTRIBUTING.md)。

遇到问题时，在 [issue](https://github.com/QwQBiG/qwq-ops/issues) 中提供执行命令、退出码、版本和已脱敏日志。上游组件的能力和兼容性以各自项目为准。

## 许可证

本项目采用 [Apache License 2.0](LICENSE)。通过部署脚本安装的上游组件适用各自的许可证。
