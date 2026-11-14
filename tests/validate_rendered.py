"""Check the chart output contracts used by scripts and operator documentation."""
import argparse
from pathlib import Path
import re

import yaml


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
    print(f"Validated {len(resources)} resources and platform integration contracts")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    try:
        validate(args.manifest)
    except (OSError, ValueError, KeyError, TypeError, yaml.YAMLError) as error:
        parser.exit(1, f"Invalid rendered platform: {error}\n")
