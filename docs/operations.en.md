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

### Run Ollama on an NVIDIA GPU

Ollama uses the CPU by default. If your lab node already has the NVIDIA drivers, runtime support, and device plugin, you can request one GPU for Ollama. Check for a positive `nvidia.com/gpu` count under `Allocatable` in the node description, then deploy. See the [Kubernetes GPU scheduling guide](https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/) for the prerequisites.

```bash
kubectl describe nodes
bash scripts/deploy.sh --nvidia-gpu
```

Pass the flag again on later deployments to keep GPU mode. Omit it to return to CPU mode. If the node advertises a GPU but the Ollama Pod stays `Pending`, check scheduling events and whether the GPU is already in use. If your cluster requires a RuntimeClass, set `runtimeClassName` in `config/helm/ollama.yaml` to the class configured in your cluster. With a model loaded, run `ollama ps` in the Ollama container to check whether it uses the CPU or GPU.

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

Change passwords after the first login; Grafana also needs the credential sync below. An administrator may already have removed the Argo CD initial password Secret; use existing credentials or the upstream recovery procedure in that case. For remote access, use an SSH tunnel to the host running port-forward. Design TLS, authentication, and access control before exposing a persistent service.

### Changing the Grafana admin password

Prepare a long random ASCII password, then change the password for `admin` in the Grafana UI, keeping the username. Use English letters, digits, and ASCII symbols to match the fixed sidecar client's [Basic Authentication password encoding](https://github.com/psf/requests/blob/v2.32.5/src/requests/auth.py#L51-L55). Grafana's provisioning sidecars use credentials from the `monitoring/grafana` Secret to call [reload endpoints that require Basic Authentication](https://grafana.com/docs/grafana/latest/developer-resources/api-reference/http-api/api-legacy/admin/#reload-provisioning-configurations). After changing the UI password, sync the same password to the Secret and restart Grafana. Otherwise, the sidecars keep using the old password and receive `401` responses. Changing only the Secret does not update the existing administrator's database password; [`admin_password` is set only on first run](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/#admin_password).

Run the following in an interactive terminal on the target Linux host, entering the password just set in the UI. Input is hidden and stays out of command arguments and history. The patch updates only `admin-password`, preserving `admin-user` and the Secret's metadata. Empty, non-ASCII, or mismatched input stops the operation. If you already set a non-ASCII password, change it to a compatible password in the UI before retrying. The restart briefly interrupts Grafana and ends existing port-forward sessions.

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

After the rollout succeeds, restart the Grafana port-forward from this section, sign out, and sign in with the new password. Then call each reload endpoint using the credentials currently loaded by its sidecar. The commands below should each print `200`. A `401` means the UI password, Secret, or recreated Pod credentials still differ.

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

## Verification and troubleshooting

```bash
bash scripts/verify.sh
kubectl get nodes -o wide
kubectl get pods -A
kubectl get events -A --sort-by=.metadata.creationTimestamp
helm list -A
```

Verification checks nodes, storage classes, Pods in the relevant namespaces, Helm releases, monitoring resource reconciliation, K8sGPT configuration, and model availability. It also checks that key Deployments, StatefulSets, and DaemonSets exist and have completed their rollouts. Investigate every failed check; API failures, empty Pod lists, and running Pods that are not ready must not count as success. Passing does not verify actual metric and log delivery or diagnosis quality.

In platform namespaces covered by the full controller inventory, retained failed Pods and old Pods being deleted produce warnings and do not count as current instances. Current instances must still exist and all corresponding controllers must be ready. Infrastructure namespaces such as `kube-system`, Calico, and local storage retain strict Pod checks.

The VictoriaMetrics Operator applies monitoring configuration. Before checking workload rollouts, deployment waits for VMSingle, VMAgent, VMAlert, and VMAlertmanager to report `status.observedGeneration` equal to the current `metadata.generation` and `status.updateStatus` set to `operational`. Independent verification requires both as well; an old workload being Ready does not establish that new configuration was applied. If the wait times out, inspect the resource status, events, and Operator logs. For example, use `kubectl describe vmsingle vm -n monitoring` to inspect metric storage. Before changing PVC capacity, also check whether the storage class supports expansion.

During K8sGPT redeployment, the script first waits for the analyzer template's model, backend, service URL, and image to match the current K8sGPT resource, then waits for the rollout. An old Deployment being Ready does not mean the Operator has applied new configuration. If that configuration wait times out, inspect Operator logs and resource events before retrying.

| Symptom | Start here |
| --- | --- |
| Pod `Pending` | Scheduling events from `kubectl describe pod -n <namespace> <pod>`, allocatable memory, and PVCs |
| PVC `Pending` | `kubectl get storageclass` and `kubectl describe pvc -n <namespace> <pvc>`; local-path normally waits for a consumer to be scheduled before binding |
| Storage setup rejects replica count | Check whether the `local-path-storage/local-path-provisioner` Deployment was scaled to zero for maintenance. The script does not scale it automatically; review the configuration before restoring it |
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

On a lab cluster, use a temporary rule to check that VMAlert delivers an alert to Alertmanager. If you have configured external receivers, check where the test alert will be routed before creating the rule.

```bash
kubectl create -f examples/alerting/smoke-rule.yaml
kubectl port-forward -n monitoring svc/vmalertmanager-vm 9093:9093
```

Open `http://127.0.0.1:9093` and look for `QwqOpsSmokeTest` after VMAlert loads and evaluates the rule. The rule uses a constant expression so you can check alert delivery independently. Metric collection and external notifications need separate checks. Press `Ctrl+C` to stop port forwarding, then remove the temporary rule.

```bash
kubectl delete vmrule qwq-ops-alert-smoke -n monitoring
```

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
