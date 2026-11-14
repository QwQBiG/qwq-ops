# 参与维护 / Contributing

请先阅读 [README](README.md) 和[架构说明](docs/architecture.md)，确认改动属于脚本、Helm values 还是 Kubernetes 清单。代码、配置和文档应在同一项改动中保持一致。

Read the [English README](README.en.md) and [architecture guide](docs/architecture.en.md) before making changes. Decide whether the change belongs in a script, Helm values, or a Kubernetes manifest, and update the related documentation with it.

## 本地检查 / Local checks

在 Linux、WSL 或其他具备 Bash 的环境中执行，需要 ShellCheck 和支持 `venv` 的 Python 3。Ubuntu 可先安装以下依赖：

Use Linux, WSL, or another environment with Bash. You need ShellCheck and Python 3 with `venv` support. On Ubuntu, install these dependencies first:

```bash
sudo apt-get update
sudo apt-get install -y python3-venv shellcheck
```

随后创建虚拟环境并安装 Python 检查依赖：

Then create a virtual environment and install the Python check dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements-dev.txt
bash scripts/check.sh
```

安装 Helm 3 后，还可检查固定 chart 的实际输出与集成约定。此步骤会下载 chart，不连接集群；CI 也会执行：

With Helm 3 installed, validate the pinned chart output and integration contracts. This downloads charts without connecting to a cluster, and also runs in CI:

```bash
bash scripts/deploy.sh --render > /tmp/qwq-ops-rendered.yaml
python3 tests/validate_rendered.py /tmp/qwq-ops-rendered.yaml
```

渲染输出包含 Secret，不要提交仓库或公开分享。

Rendered output includes Secrets; do not commit it or share it publicly.

CI 还会创建临时 Kubernetes 1.35 集群，建立命名空间、CRD 和 Pod 准入检查需要的 ServiceAccount，再通过 API 服务端校验其余资源。这个检查用于确认资源能被目标 API 接受；组件运行、指标和日志传输及模型推理仍需单独验证。

CI also creates a temporary Kubernetes 1.35 cluster, establishes namespaces, CRDs, and ServiceAccounts required by Pod admission, then validates the remaining resources with a server-side dry run. This checks API acceptance. Component operation, metrics and log transport, and model inference require separate validation.

检查脚本不应改动主机或连接真实集群。涉及部署行为时，补充能够复现问题的命令替身测试，并同时覆盖成功路径与相关失败路径。静态检查与替身测试通过，不能证明组件已在真实集群中运行。

Checks must not modify the host or connect to a real cluster. For deployment behavior, add command-stub tests that reproduce the problem and cover the relevant success and failure paths. Passing static checks and stub tests does not establish that the components run in a real cluster.

## 版本与配置 / Versions and configuration

- 版本统一放在 `config/versions.env`。升级前核对上游发布说明、兼容要求及数据迁移步骤。
- 组件参数放在 `config/helm/`；跨组件资源放在 `manifests/`。不要把真实凭据写入仓库。
- 文本文件使用 UTF-8、LF 换行。中文和英文文档中的命令、路径与行为边界需要对应。

- Keep versions in `config/versions.env`. Review upstream release notes, compatibility requirements, and data migration steps before upgrading.
- Put component settings in `config/helm/` and integration resources in `manifests/`. Keep real credentials out of the repository.
- Use UTF-8 and LF line endings. Keep commands, paths, and operating limits consistent between the Chinese and English documentation.

## Issue 与 PR / Issues and pull requests

报告问题时提供仓库提交、操作系统、相关组件版本、执行命令、退出码和错误输出。请隐去令牌、密码和私有地址。说明期望行为与实际行为；如果无法复现，也请注明目前掌握的证据。

Include the repository commit, operating system, relevant component versions, command, exit code, and error output in a bug report. Redact tokens, passwords, and private addresses. Describe expected and actual behavior, and distinguish a reproduced failure from a suspected problem.

PR 应说明解决的具体问题、最终行为、验证命令与结果，以及尚未验证的事项。改变入口、存储格式或升级方式时，补充迁移说明。请把无关的重排或新功能留给单独的 PR。

A pull request should explain the concrete problem, resulting behavior, validation commands and results, and anything left unverified. Include migration guidance when changing entry points, storage formats, or upgrade behavior. Keep unrelated formatting changes and features in separate pull requests.
