# Operations guide

[中文](operations.md) · [Back to README](../README.en.md) · [Architecture](architecture.en.md)

Cluster commands in this guide use the current user's kubeconfig. Check the target with `kubectl config current-context` first. Host initialization is only for a fresh, dedicated host; it does not repair or upgrade an existing cluster.

## Configuration and preview

Component versions and defaults live in `config/versions.env`. Resource settings, persistence, and retention live in `config/helm/`. Environment variables can override the version file for a single invocation:

| Variable | Default | Purpose |
| --- | --- | --- |
| `POD_CIDR` | `10.244.0.0/16` | Pod IPv4 network used during cluster initialization |
| `WAIT_TIMEOUT` | `300s` | Limit for each resource creation, readiness, or rollout wait |
| `HELM_TIMEOUT` | `15m` | Installation or upgrade wait limit for each Helm release |
| `REQUEST_TIMEOUT` | `30s` | Timeout for an individual kubectl API request |

The Pod network must be an IPv4 `/24` or larger network, with a prefix length no greater than 24. It must not overlap the host network or the default Service network, `10.96.0.0/12`. For example, after confirming that `10.245.0.0/16` does not conflict in the target environment, select it for initial setup:

```bash
sudo env POD_CIDR=10.245.0.0/16 bash scripts/bootstrap.sh
```

Initialization also checks the fixed Service network against host interface networks. If the host already uses an address within `10.96.0.0/12`, changing `POD_CIDR` alone cannot resolve the conflict; adjust host networking or plan the cluster separately.

Existing containerd configuration is checked for `SystemdCgroup` on the actual default runtime. Settings on an unused runtime do not satisfy that requirement. Installation stops when the configuration cannot be identified reliably so it can be reviewed.

`sudo` may discard the caller's environment variables; use `sudo env` to pass the required values explicitly. Rerunning bootstrap cannot change an existing cluster's network. If deployment is making progress but needs more time, increase the limits below. They apply per request or component, not to the deployment as a whole:

```bash
HELM_TIMEOUT=30m WAIT_TIMEOUT=900s REQUEST_TIMEOUT=60s bash scripts/deploy.sh
```

Inspect rendered output after changing configuration:

```bash
bash scripts/deploy.sh --help
bash scripts/deploy.sh --render
```

`--render` accesses Helm repositories but does not connect to a cluster. It checks whether templates can be generated, not target permissions, CRDs, available capacity, or data compatibility. It is not a complete diff against installed releases. Rendered output includes Secrets; do not commit it or share it publicly.

Select a model with `--model MODEL` during deployment. The script uses the same model in Ollama and the K8sGPT integration. `--model` only overrides the current invocation. Pass the same model on the next deployment, or set `OLLAMA_MODEL` in `config/versions.env` first; otherwise, deployment returns to the default selection. Before switching, assess memory and disk requirements and confirm that the model is available from its source.

On startup, Ollama uses the locally cached model and downloads it only if missing. Restarting or redeploying does not refresh an existing model tag. To update the default model, `qwen2.5:1.5b`, run:

```bash
kubectl exec -n ai deploy/ollama -- ollama pull qwen2.5:1.5b
```

If you selected another model, replace the model name in this command with your selection. `ollama pull` downloads or updates the local model without changing K8sGPT's selection.

## Accessing services

Run each port-forward command below in a separate terminal. Stop it with `Ctrl+C`. The default listener is the local loopback interface.

```bash
kubectl port-forward -n monitoring svc/grafana 3000:80
kubectl port-forward -n argocd svc/argocd-server 8080:443
kubectl port-forward -n monitoring svc/vmsingle-vm 8428:8428
kubectl port-forward -n ai svc/ollama 11434:11434
```

| Component | Local address |
| --- | --- |
| Grafana | `http://127.0.0.1:3000` |
| Argo CD | `https://127.0.0.1:8080`, initially with a self-signed certificate |
| VictoriaMetrics | `http://127.0.0.1:8428/vmui` |
| Ollama model list | `http://127.0.0.1:11434/api/tags` |

The initial username for Grafana and Argo CD is `admin`. Read passwords from Secrets rather than assuming a default:

```bash
kubectl get secret -n monitoring grafana -o jsonpath='{.data.admin-password}' | base64 --decode
kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode
```

Change passwords after the first login. An administrator may already have removed the Argo CD initial password Secret; use existing credentials or the upstream recovery procedure in that case. For remote access, use an SSH tunnel to the host running port-forward. Design TLS, authentication, and access control before exposing a persistent service.

## Verification and troubleshooting

```bash
bash scripts/verify.sh
kubectl get nodes -o wide
kubectl get pods -A
kubectl get events -A --sort-by=.metadata.creationTimestamp
helm list -A
```

Verification checks nodes, storage classes, Pods in the relevant namespaces, Helm releases, K8sGPT configuration, and model availability. It also checks that key Deployments, StatefulSets, and DaemonSets exist and have completed their rollouts. Investigate every failed check; API failures, empty Pod lists, and running Pods that are not ready must not count as success. Passing does not verify actual metric and log delivery or diagnosis quality.

| Symptom | Start here |
| --- | --- |
| Pod `Pending` | Scheduling events from `kubectl describe pod -n <namespace> <pod>`, allocatable memory, and PVCs |
| PVC `Pending` | `kubectl get storageclass` and `kubectl describe pvc -n <namespace> <pvc>`; local-path normally waits for a consumer to be scheduled before binding |
| `ImagePullBackOff` | Image address, registry access, and credentials in Pod events |
| `CrashLoopBackOff` | `kubectl logs -n <namespace> <pod> --all-containers --previous` and current logs |
| Helm failure or timeout | `helm status -n <namespace> <release>` and Pod events; resolve the cause before choosing a retry or rollback |
| No logs in Grafana | `kubectl logs -n logging -l app.kubernetes.io/name=alloy`, Loki Pods and Services, and the data source configuration |

Alloy saves log read positions in the container's temporary directory, `/tmp/alloy`. Recreating the container or Pod clears these records, so Alloy may reread logs still available through the Kubernetes API, adding API and log write traffic.

After interrupted initialization, inspect `journalctl -u kubelet -u containerd` and the configuration already written. The bootstrap script stops when it finds existing cluster state to avoid initializing over it. Do not clear etcd, network rules, or kubeconfig just to retry.

## Diagnostics and alerts

```bash
kubectl exec -n ai deploy/ollama -- ollama list
kubectl get k8sgpt -n k8sgpt
kubectl get results -n k8sgpt
kubectl describe results -n k8sgpt
```

Assess K8sGPT findings alongside events and application logs; findings do not trigger automatic repairs. If results are missing, inspect Operator, analyzer Pod, and Ollama logs. Confirm that the model is loaded, the service is reachable, and the integration selects the same model.

The monitoring stack includes rule evaluation and Alertmanager, but this repository does not configure external recipients. Configure receivers and credentials, then test both firing and resolved notifications. Third-party chat robots may not accept Alertmanager's generic Webhook payload; use a receiver or adapter that implements the channel's protocol.

## Existing installations and upgrades

Root-level scripts have moved to `scripts/`. Do not apply the old `k8sgpt_integration.yaml` separately; the deploy script manages integrations. An existing installation needs a migration plan rather than a repeat of the first-install sequence:

1. Record the repository commit, cluster version, `helm list -A`, release values, CRDs, and persistent volumes.
2. Back up data and required credentials, then test restoration in a separate environment. Exporting YAML or Helm values does not back up volume contents. Models, logs, metrics, and cluster state each need a recovery plan.
3. Read the target components' upgrade instructions. Kubernetes upgrades must follow the supported upstream sequence; editing the version file and running bootstrap does not upgrade an existing cluster.
4. Plan the Loki migration separately. The old `loki-stack` differs from the current Loki chart, storage layout, and Alloy collection configuration. Do not run the new deploy script against the old `loki` release. Validate data migration or build a separate environment, and retain old data until queries and recovery pass acceptance checks.
5. Review the new Service names and data sources. Confirm model selection, PVCs, and credentials before switching, then run verification and your own critical workload checks.

Log collection now uses Alloy. Promtail has reached end of life; see the [official Grafana notice](https://grafana.com/docs/loki/latest/send-data/promtail/). Check storage format and CRD compatibility before a rollback as well. `helm rollback` cannot recover data that has been deleted or migrated.

## Removing lab components

Confirm the current context, backup requirements, and release ownership before selecting components to remove. Before uninstalling the K8sGPT Operator, delete this project's `k8sgpt/k8sgpt` integration instance so the running controller can finish cleanup, then uninstall the Operator:

```bash
kubectl delete k8sgpt k8sgpt -n k8sgpt
helm uninstall k8sgpt-operator -n k8sgpt
helm uninstall ollama -n ai
helm uninstall argocd -n argocd
helm uninstall alloy -n logging
helm uninstall loki -n logging
helm uninstall victoria-metrics -n monitoring
```

These commands interrupt the corresponding services. PVCs, CRDs, and some other resources may remain after Helm removal; inspect them individually with commands such as `kubectl get pvc -A`. The Grafana Loki data source ConfigMap is created separately by an integration manifest, so check whether it remains as well. Deleting namespaces, PVCs, or Local Path Provisioner may affect data and other workloads. Confirm ownership and backups before doing so. The repository does not provide automatic host resets or firewall flushing.
