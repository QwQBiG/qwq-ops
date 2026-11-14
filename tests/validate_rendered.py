"""Check the chart output contracts used by scripts and operator documentation."""
import argparse
from pathlib import Path
import re

import yaml

ROOT = Path(__file__).resolve().parents[1]


def validate_workload_inventory(resources, script):
    block = re.search(r"<<'WORKLOADS'\n(.*?)\nWORKLOADS", script.read_text(encoding="utf-8"), re.S)
    if block is None:
        raise ValueError("Verification workload inventory is missing")
    entries = [tuple(line.split()) for line in block[1].splitlines() if line.strip()]
    if any(len(entry) != 2 for entry in entries) or len(entries) != len(set(entries)):
        raise ValueError("Verification workload inventory has invalid or duplicate entries")

    expected = set()
    generated = {"VMSingle": "deployment/vmsingle-", "VMAgent": "deployment/vmagent-",
                 "VMAlert": "deployment/vmalert-", "VMAlertmanager": "statefulset/vmalertmanager-",
                 "K8sGPT": "deployment/"}
    for item in resources:
        kind = item["kind"]
        metadata = item.get("metadata", {})
        name = metadata.get("name", "")
        namespace = metadata.get("namespace")
        # This chart relies on Helm's release namespace rather than rendering it.
        if name == "k8sgpt-operator-controller-manager" and not namespace:
            namespace = "k8sgpt"
        if kind in ("Deployment", "StatefulSet", "DaemonSet"):
            expected.add((namespace, f"{kind.lower()}/{name}"))
        elif kind in generated:
            expected.add((namespace, generated[kind] + name))
    if set(entries) != expected:
        missing = sorted(expected - set(entries), key=str)
        extra = sorted(set(entries) - expected, key=str)
        raise ValueError(f"Verification inventory differs from rendered workloads: missing={missing}, extra={extra}")


def validate(path):
    resources = [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if doc]
    if not resources or not all(isinstance(doc, dict) and doc.get("kind") for doc in resources):
        raise ValueError("Expected Kubernetes resource mappings")

    def resource(kind, name, namespace):
        matches = [doc for doc in resources if doc["kind"] == kind
                   and doc.get("metadata", {}).get("name") == name
                   and doc["metadata"].get("namespace") == namespace]
        if len(matches) != 1:
            raise ValueError(f"Expected exactly one {namespace}/{kind}/{name}")
        return matches[0]

    for name, namespace, port in (("grafana", "monitoring", 80),
                                  ("loki-gateway", "logging", 80),
                                  ("argocd-server", "argocd", 443),
                                  ("ollama", "ai", 11434)):
        service = resource("Service", name, namespace)
        if port not in [item["port"] for item in service["spec"]["ports"]]:
            raise ValueError(f"Unexpected service port for {namespace}/{name}")
        if service["spec"].get("type", "ClusterIP") != "ClusterIP":
            raise ValueError(f"Unexpected public service: {namespace}/{name}")

    for kind in ("VMSingle", "VMAgent", "VMAlert", "VMAlertmanager"):
        resource(kind, "vm", "monitoring")
    agent = resource("VMAgent", "vm", "monitoring")
    if not any("vmsingle-vm" in item["url"] and ":8428" in item["url"]
               for item in agent["spec"]["remoteWrite"]):
        raise ValueError("Metric writes do not target vmsingle-vm:8428")

    diagnosis = resource("K8sGPT", "k8sgpt", "k8sgpt")
    model = diagnosis["spec"]["ai"]["model"]
    ollama = resource("Deployment", "ollama", "ai")
    containers = ollama["spec"]["template"]["spec"]["containers"]
    hooks = "\n".join(str(part) for item in containers
                      for part in item.get("lifecycle", {}).get("postStart", {})
                      .get("exec", {}).get("command", []))
    if not re.search(r"\bollama\s+pull\b", hooks) or model not in hooks:
        raise ValueError("Ollama does not pull the model configured in K8sGPT")
    datasource = resource("ConfigMap", "grafana-datasource-loki", "monitoring")
    config = yaml.safe_load(datasource["data"]["loki.yaml"])
    if config["datasources"][0]["url"] != "http://loki-gateway.logging.svc.cluster.local":
        raise ValueError("Grafana does not query the configured Loki gateway")
    validate_workload_inventory(resources, ROOT / "scripts" / "verify.sh")
    print(f"Validated {len(resources)} resources and platform integration contracts")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    try:
        validate(args.manifest)
    except (OSError, ValueError, KeyError, TypeError, yaml.YAMLError) as error:
        parser.exit(1, f"Invalid rendered platform: {error}\n")
