"""Verify storage mutations and bootstrap network checks with local command doubles."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("BASH_EXECUTABLE") or shutil.which("bash")


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)
        self.log = self.folder / "commands.log"
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.folder) + os.pathsep + self.env["PATH"],
                        MOCK_LOG=self.log.as_posix(), MOCK_DEPLOYMENT="present")
        self.write_command("kubectl", r'''#!/usr/bin/env bash
set -euo pipefail
[[ $1 != --request-timeout=* ]] || shift
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$1 $2" in
    'get --raw=/readyz') exit "${MOCK_API_FAILURE:-0}" ;;
    'get storageclasses') printf '%s' "${MOCK_CLASSES:-}" ;;
    'get deployment')
        [[ ${MOCK_DEPLOYMENT:-} != present ]] || printf 'deployment.apps/local-path-provisioner\n'
        ;;
    'get storageclass')
        if [[ $* != *--ignore-not-found* ]]; then printf 'local-path\n'; fi
        ;;
    'apply -f') exit "${MOCK_APPLY_FAILURE:-0}" ;;
    'rollout status') exit "${MOCK_ROLLOUT_FAILURE:-0}" ;;
    'annotate storageclass') ;;
    *) printf 'Unexpected kubectl call: %s\n' "$*" >&2; exit 99 ;;
esac
''')
        self.write_command("curl", r'''#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
    if [[ $1 == --output ]]; then
        printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: local-path-storage\n' > "$2"
        exit 0
    fi
    shift
done
exit 99
''')

    def write_command(self, name, content):
        path = self.folder / name
        path.write_text(content, encoding="utf-8", newline="\n")
        path.chmod(0o755)

    def run_storage(self, **environment):
        self.env.update(environment)
        return subprocess.run([BASH, str(ROOT / "scripts" / "storage.sh")],
                              env=self.env, cwd=self.directory.name, text=True,
                              encoding="utf-8", capture_output=True, timeout=20)

    def commands(self):
        return self.log.read_text(encoding="utf-8") if self.log.exists() else ""

    def test_existing_installation_preserves_configuration(self):
        result = self.run_storage(MOCK_CLASSES="local-path|rancher.io/local-path|true|\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("apply -f", self.commands())
        self.assertIn("rollout status", self.commands())
        self.assertIn("annotate storageclass local-path", self.commands())

    def test_fresh_installation_applies_and_waits_before_defaulting(self):
        result = self.run_storage(MOCK_DEPLOYMENT="absent")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.commands()
        self.assertLess(calls.index("apply -f"), calls.index("rollout status"))
        self.assertLess(calls.index("rollout status"), calls.index("annotate storageclass"))

    def test_other_default_class_is_not_changed(self):
        for annotations in ("true|", "|true"):
            with self.subTest(annotations=annotations):
                result = self.run_storage(MOCK_CLASSES="existing|custom/provisioner|" + annotations + "\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("already default", result.stderr)
                self.assertNotIn("apply -f", self.commands())
                self.assertNotIn("annotate storageclass", self.commands())

    def test_unrelated_local_path_class_is_not_changed(self):
        result = self.run_storage(MOCK_CLASSES="local-path|custom/provisioner||\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different provisioner", result.stderr)
        self.assertNotIn("annotate storageclass", self.commands())

    def test_apply_failure_stops_before_rollout_and_defaulting(self):
        result = self.run_storage(MOCK_DEPLOYMENT="absent", MOCK_APPLY_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("rollout status", self.commands())
        self.assertNotIn("annotate storageclass", self.commands())

    def test_rollout_failure_does_not_default_storage(self):
        result = self.run_storage(MOCK_ROLLOUT_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("annotate storageclass", self.commands())

    def test_api_failure_stops_before_storage_queries(self):
        result = self.run_storage(MOCK_API_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("get storageclasses", self.commands())

    def run_network_check(self, cidr, host_address="192.168.1.10", prefix=24):
        self.write_command("ip", '#!/usr/bin/env bash\nprintf "%s\\n" "$MOCK_ADDRESSES"\n')
        self.write_command("python3", '#!/usr/bin/env bash\nexec ' +
                           shlex.quote(Path(sys.executable).as_posix()) + ' "$@"\n')
        self.env.update(POD_CIDR=cidr, BOOTSTRAP_PATH=(ROOT / "scripts" / "bootstrap.sh").as_posix(),
                        MOCK_ADDRESSES=json.dumps([{"addr_info": [
                            {"local": host_address, "prefixlen": prefix}]}]))
        return subprocess.run([BASH, "-c", 'source "$BOOTSTRAP_PATH"; validate_network'],
                              env=self.env, cwd=self.directory.name, text=True,
                              encoding="utf-8", capture_output=True, timeout=20)

    def test_non_overlapping_pod_network_is_accepted(self):
        result = self.run_network_check("10.244.0.0/16")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pod_network_overlap_with_host_is_rejected(self):
        result = self.run_network_check("192.168.0.0/16")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("overlaps host network", result.stderr)

    def test_pod_network_overlap_with_services_is_rejected(self):
        result = self.run_network_check("10.96.0.0/16")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("overlaps the kubeadm default service CIDR", result.stderr)

    def test_invalid_pod_network_is_rejected(self):
        result = self.run_network_check("not-a-network")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not appear to be", result.stderr)
