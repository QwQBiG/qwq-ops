"""Keep health-check expectations aligned with resources produced by the charts."""
from pathlib import Path
import tempfile
import unittest

import yaml

from helpers import ROOT
from validate_rendered import validate_diagnosis_integration, validate_workload_inventory


class DiagnosisIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.diagnosis = yaml.safe_load(
            (ROOT / "manifests/integrations/k8sgpt.yaml.template").read_text(encoding="utf-8"))
        self.diagnosis["spec"]["ai"]["model"] = "tinyllama:latest"
        values = yaml.safe_load((ROOT / "config/helm/ollama.yaml").read_text(encoding="utf-8"))
        self.container = {
            "env": [{"name": "OLLAMA_BOOTSTRAP_MODEL", "value": "tinyllama:latest"}],
            "lifecycle": values["lifecycle"],
        }
        self.ollama = {"spec": {"template": {"spec": {"containers": [self.container]}}}}

    def test_local_backend_and_model_bootstrap_match(self):
        validate_diagnosis_integration(self.diagnosis, self.ollama)

    def test_wrong_diagnosis_backend_is_rejected(self):
        self.diagnosis["spec"]["ai"]["backend"] = "openai"
        with self.assertRaisesRegex(ValueError, "backend"):
            validate_diagnosis_integration(self.diagnosis, self.ollama)

    def test_wrong_ollama_endpoint_is_rejected(self):
        self.diagnosis["spec"]["ai"]["baseUrl"] = "http://wrong.invalid:11434/v1"
        with self.assertRaisesRegex(ValueError, "Ollama service"):
            validate_diagnosis_integration(self.diagnosis, self.ollama)

    def test_different_bootstrap_model_is_rejected(self):
        self.container["env"][0]["value"] = "other:latest"
        with self.assertRaisesRegex(ValueError, "model"):
            validate_diagnosis_integration(self.diagnosis, self.ollama)


class RenderedInventoryTests(unittest.TestCase):
    def validate(self, resources, entries):
        with tempfile.TemporaryDirectory() as folder:
            script = Path(folder) / "verify.sh"
            script.write_text("cat <<'WORKLOADS'\n" + entries + "\nWORKLOADS\n",
                              encoding="utf-8", newline="\n")
            validate_workload_inventory(resources, script)

    def test_chart_and_operator_workloads_are_both_required(self):
        self.validate([
            {"kind": "StatefulSet", "metadata": {"namespace": "logging", "name": "loki"}},
            {"kind": "VMSingle", "metadata": {"namespace": "monitoring", "name": "vm"}},
        ], "logging statefulset/loki\nmonitoring deployment/vmsingle-vm")

    def test_missing_health_check_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing="):
            self.validate([
                {"kind": "DaemonSet", "metadata": {"namespace": "logging", "name": "alloy"}},
            ], "")

    def test_outdated_workload_name_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "extra="):
            self.validate([], "logging statefulset/old-loki")

    def test_duplicate_inventory_entry_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.validate([], "logging statefulset/loki\nlogging statefulset/loki")
