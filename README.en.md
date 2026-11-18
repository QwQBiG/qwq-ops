# qwq-ops

[中文](README.md) · [Architecture](docs/architecture.en.md) · [Operations](docs/operations.en.md) · [Contributing](CONTRIBUTING.md)

Build a Kubernetes operations lab on an Ubuntu host: inspect metrics with VictoriaMetrics and Grafana, query logs with Loki and Grafana Alloy, practice application delivery with Argo CD, and investigate cluster issues with K8sGPT and Ollama.

This project is intended for learning, testing, and personal labs. It uses a single control plane and local disk storage, with no high availability or automatic backups. Deploy it on a dedicated host rather than a server running existing workloads.

## Before you begin

- Host initialization targets **Ubuntu 22.04 / 24.04** and requires `sudo`. It changes swap, kernel settings, package repositories, and the container runtime.
- Prepare Bash, `curl`, Python 3, `ip` (iproute2), and access to package, image, Helm, and model repositories. The mirror option only changes the image repository used by kubeadm; it does not redirect every download.
- Platform deployment requires `kubectl` with cluster access and **Helm 3** compatible with Kubernetes 1.35. Use [v3.22.1](https://github.com/helm/helm/releases/tag/v3.22.1) to match CI. Follow the [Helm 3 installation guide](https://helm.sh/docs/v3/intro/install/), select the release archive for your operating system and architecture, and verify the download. If using a package manager, explicitly select the version as well.
- Reserve resources for metrics, logs, and models. An 8-core CPU, 16 GB RAM, and 100 GB of free SSD space can serve as an initial lab plan. This is not a load-tested capacity guarantee; model size and retention settings affect actual usage.

Check the installed Helm version; the recommended version should print output starting with `v3.22.1`. Before choosing another version, confirm that its [official Kubernetes compatibility range](https://helm.sh/docs/v3/topics/version_skew/) covers this project's Kubernetes 1.35 target.

```bash
helm version --short
```

When reusing a cluster already configured from this repository, skip host initialization and review its version, permissions, and installed components first. Deployment and verification expect Calico and Local Path Provisioner; other networking, storage, or multi-node topologies require adaptation. Read the [architecture tradeoffs](docs/architecture.en.md#single-node-tradeoffs) before deploying.

## Deploy

Run these commands on the target Linux host. Only the first script requires `sudo`; the remaining scripts use the current user's kubeconfig.

```bash
git clone https://github.com/QwQBiG/qwq-ops.git
cd qwq-ops

# Run only on a dedicated Ubuntu host without an initialized cluster.
sudo bash scripts/bootstrap.sh

# Confirm that the current context is the intended cluster.
kubectl config current-context
kubectl get nodes

bash scripts/storage.sh
bash scripts/deploy.sh
bash scripts/verify.sh
```

Initialization stops if it finds existing cluster state or a kubeconfig. Storage setup stops if another default StorageClass exists, leaving that choice to the operator. After a failure, inspect the error and current state before continuing. Do not delete cluster data to bypass a check.

Each entry point supports `--help`. Initialization accepts `--use-aliyun-mirror`; deployment accepts `--model MODEL` and `--render`, with `qwen2.5:1.5b` as the default model. Rendering prints Helm and integration manifests without connecting to a cluster, but still downloads charts. Deployment order, component versions, and settings live in `scripts/`, `config/versions.env`, and `config/helm/`, respectively.

Verification only reads cluster state and returns a nonzero exit code when a check fails. A passing result describes the checks at that moment; it does not establish workload capacity, backup recovery, or upgrade readiness. See the [operations guide](docs/operations.en.md) for Grafana, Argo CD, and diagnostic access.

## Layout

```text
qwq-ops/
├── scripts/                 # Bootstrap, storage, deploy, verify, and local checks
│   └── lib/                 # Shared commands and error handling
├── config/
│   ├── versions.env         # Pinned versions
│   └── helm/                # Component-specific Helm values
├── manifests/               # Integration resources
├── examples/                # Optional lab exercises
├── tests/                   # Checks that do not need a real cluster
├── docs/                    # Chinese and English guides
├── .github/workflows/       # Automated checks
├── CONTRIBUTING.md
├── README.md
└── README.en.md
```

Scripts control execution, configuration files hold deployment settings, and documentation explains use and maintenance. The [architecture guide](docs/architecture.en.md) describes responsibilities and data flow.

## Migrating from the old layout

| Previous entry point | Current location |
| --- | --- |
| `01_init_k8s.sh` | `scripts/bootstrap.sh` |
| `02_setup_storage.sh` | `scripts/storage.sh` |
| `03_deploy_stack.sh` | `scripts/deploy.sh` |
| `verify_deployment.sh` | `scripts/verify.sh` |
| `k8sgpt_integration.yaml` | The deploy script manages integration resources in `manifests/` |

This revision also changes log collection and component configuration. Back up PVC data, Helm values, and cluster configuration before assessing an existing installation against the [migration guidance](docs/operations.en.md#existing-installations-and-upgrades). The new entry points are not an automatic upgrade path for the old platform.

## Checks and maintenance

Run development checks with `bash scripts/check.sh`. See [Contributing](CONTRIBUTING.md) for dependencies and submission requirements.

When opening an [issue](https://github.com/QwQBiG/qwq-ops/issues), include the command, exit code, versions, and redacted logs. Refer to each upstream project for its capabilities, compatibility requirements, and license.
