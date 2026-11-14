"""Keep health-check expectations aligned with resources produced by the charts."""
from pathlib import Path
import tempfile
import unittest

from validate_rendered import validate_workload_inventory


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
