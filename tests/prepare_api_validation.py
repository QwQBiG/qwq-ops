"""Separate rendered resources for validation against a temporary Kubernetes API."""
import argparse
from pathlib import Path

import yaml


def prepare(manifest, output):
    resources = [item for item in yaml.safe_load_all(manifest.read_text(encoding="utf-8"))
                 if item is not None]
    if not resources:
        raise ValueError("Rendered manifest contains no resources")
    namespaces, crds, remaining = {}, [], []
    referenced = set()
    for item in resources:
        if not isinstance(item, dict) or not item.get("apiVersion") or not item.get("kind"):
            raise ValueError("Expected Kubernetes resource mappings")
        metadata = item.get("metadata", {})
        if not isinstance(metadata, dict) or not metadata.get("name"):
            raise ValueError("Every rendered resource must have metadata.name")
        namespace = metadata.get("namespace")
        if namespace is not None:
            if not isinstance(namespace, str) or not namespace:
                raise ValueError("Resource namespace must be a nonempty string")
            referenced.add(namespace)
        if item["kind"] == "Namespace":
            namespaces[metadata["name"]] = item
        elif item["kind"] == "CustomResourceDefinition":
            crds.append(item)
        else:
            remaining.append(item)
    if not crds:
        raise ValueError("Rendered manifest contains no CRDs to establish")
    if not remaining:
        raise ValueError("Rendered manifest contains no remaining resources to validate")
    for name in referenced:
        namespaces.setdefault(name, {"apiVersion": "v1", "kind": "Namespace",
                                     "metadata": {"name": name}})
    if not namespaces:
        raise ValueError("Rendered manifest contains no namespaces")
    output.mkdir(parents=True, exist_ok=False)
    groups = {"namespaces": [namespaces[name] for name in sorted(namespaces)],
              "crds": crds, "resources": remaining}
    for name, items in groups.items():
        (output / (name + ".yaml")).write_text(
            yaml.safe_dump_all(items, explicit_start=True, sort_keys=False, allow_unicode=True),
            encoding="utf-8", newline="\n")
    print(f"Prepared {len(namespaces)} namespaces, {len(crds)} CRDs and {len(remaining)} API resources")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        prepare(args.manifest, args.output)
    except (OSError, ValueError, yaml.YAMLError) as error:
        parser.exit(1, f"[ERROR] {error}\n")
