"""Exercise command boundaries without changing a host or contacting a cluster."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("BASH_EXECUTABLE") or shutil.which("bash")


class ToolingTests(unittest.TestCase):
    def run_script(self, name, *args, env=None):
        merged = os.environ.copy()
        if env:
            merged.update(env)
        return subprocess.run(
            [BASH, str(ROOT / "scripts" / name), *args],
            cwd=tempfile.gettempdir(), env=merged, text=True,
            encoding="utf-8", capture_output=True, timeout=20,
        )

    def test_help_is_available_without_cluster_tools(self):
        for name in ("bootstrap.sh", "storage.sh", "deploy.sh", "verify.sh"):
            with self.subTest(name=name):
                result = self.run_script(name, "--help")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Usage:", result.stdout)

    def test_unknown_options_fail_before_work(self):
        for name in ("bootstrap.sh", "storage.sh", "deploy.sh", "verify.sh"):
            with self.subTest(name=name):
                result = self.run_script(name, "--unknown-option")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Unknown", result.stderr)

    def test_model_argument_requires_a_value(self):
        result = self.run_script("deploy.sh", "--model")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("model", result.stderr.lower())

    def test_model_rejects_template_metacharacters(self):
        result = self.run_script("deploy.sh", "--model", "invalid&model")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("model", result.stderr.lower())

    def test_configuration_documents_are_mappings(self):
        paths = list((ROOT / "config" / "helm").glob("*.yaml"))
        paths += list((ROOT / "manifests").rglob("*.yaml"))
        self.assertGreater(len(paths), 6)
        for path in paths:
            with self.subTest(path=str(path.relative_to(ROOT))):
                documents = list(yaml.safe_load_all(path.read_text(encoding="utf-8")))
                self.assertTrue(documents)
                self.assertTrue(all(isinstance(doc, dict) for doc in documents))

    def test_repository_text_uses_utf8_and_lf(self):
        paths = [ROOT / "README.md", ROOT / "README.en.md"]
        for folder in ("scripts", "config", "manifests", "tests", "docs"):
            paths.extend(p for p in (ROOT / folder).rglob("*")
                         if p.is_file() and p.suffix in (".sh", ".env", ".yaml", ".md", ".py", ".template"))
        for path in paths:
            with self.subTest(path=str(path.relative_to(ROOT))):
                content = path.read_bytes()
                content.decode("utf-8")
                self.assertNotIn(b"\r", content)
                self.assertFalse(content.startswith(b"\xef\xbb\xbf"))

    def test_local_documentation_links_resolve(self):
        pages = [ROOT / "README.md", ROOT / "README.en.md", ROOT / "CONTRIBUTING.md"]
        pages.extend((ROOT / "docs").glob("*.md"))
        for page in pages:
            for target in re.findall(r"\]\(([^)]+)\)", page.read_text(encoding="utf-8")):
                if "://" in target or target.startswith("#"):
                    continue
                target = target.split("#", 1)[0]
                with self.subTest(page=page.name, target=target):
                    self.assertTrue((page.parent / target).exists())


if __name__ == "__main__":
    unittest.main()
