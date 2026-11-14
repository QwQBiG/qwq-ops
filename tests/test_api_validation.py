"""Check the resource split needed before Kubernetes server dry-run validation."""
from pathlib import Path
import tempfile
import unittest

import yaml

from prepare_api_validation import prepare


class ApiValidationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)
        self.manifest = self.folder / "rendered.yaml"
        self.output = self.folder / "prepared"

    def write(self, resources):
        self.manifest.write_text(yaml.safe_dump_all(resources), encoding="utf-8", newline="\n")

    def test_namespaces_and_crds_are_separated_without_changing_other_resources(self):
        namespace = {"apiVersion": "v1", "kind": "Namespace",
                     "metadata": {"name": "apps", "labels": {"scope": "test"}}}
        crd = {"apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition",
               "metadata": {"name": "widgets.example.test"}}
        resource = {"apiVersion": "example.test/v1", "kind": "Widget",
                    "metadata": {"name": "sample", "namespace": "other"}}
        self.write([namespace, None, crd, resource])
        prepare(self.manifest, self.output)
        namespaces = list(yaml.safe_load_all((self.output / "namespaces.yaml").read_text(encoding="utf-8")))
        self.assertEqual(namespaces, [namespace, {"apiVersion": "v1", "kind": "Namespace",
                                                "metadata": {"name": "other"}}])
        for name, expected in (("crds", crd), ("resources", resource)):
            actual = list(yaml.safe_load_all((self.output / (name + ".yaml")).read_text(encoding="utf-8")))
            self.assertEqual(actual, [expected])

    def test_empty_input_is_rejected_before_output_is_created(self):
        self.write([])
        with self.assertRaisesRegex(ValueError, "no resources"):
            prepare(self.manifest, self.output)
        self.assertFalse(self.output.exists())

    def test_missing_crds_are_rejected_before_output_is_created(self):
        self.write([{"apiVersion": "v1", "kind": "ConfigMap",
                     "metadata": {"name": "sample", "namespace": "apps"}}])
        with self.assertRaisesRegex(ValueError, "no CRDs"):
            prepare(self.manifest, self.output)
        self.assertFalse(self.output.exists())
