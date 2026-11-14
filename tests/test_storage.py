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
        mock_bin = self.folder.as_posix()
        if os.name == "nt":
            mock_bin = "/" + mock_bin[0].lower() + mock_bin[2:]
        self.env.update(MOCK_BIN=mock_bin)
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
        self.env.update(STORAGE_PATH=(ROOT / "scripts" / "storage.sh").as_posix())
        return subprocess.run([BASH, "-c", 'export PATH="$MOCK_BIN:$PATH"; source "$STORAGE_PATH"'],
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
        return self.run_bootstrap_check("validate_network")

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

    def test_pod_network_accepts_the_default_node_mask(self):
        result = self.run_network_check("10.244.0.0/24")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pod_network_smaller_than_a_node_subnet_is_rejected(self):
        for prefix in (25, 26):
            with self.subTest(prefix=prefix):
                result = self.run_network_check("10.244.0.0/" + str(prefix))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("/24", result.stderr)

    def run_bootstrap_check(self, command, **environment):
        self.env.update(BOOTSTRAP_PATH=(ROOT / "scripts" / "bootstrap.sh").as_posix(),
                        **environment)
        return subprocess.run([BASH, "-c", 'export PATH="$MOCK_BIN:$PATH"; source "$BOOTSTRAP_PATH"; ' + command],
                              env=self.env, cwd=self.directory.name, text=True,
                              encoding="utf-8", capture_output=True, timeout=20)

    def test_disabled_cri_plugins_are_rejected_in_both_dump_formats(self):
        plugins = ("cri", "io.containerd.grpc.v1.cri", "io.containerd.cri.v1.runtime",
                   "io.containerd.cri.v1.images")
        for plugin in plugins:
            for quote in ("'", '"'):
                with self.subTest(plugin=plugin, quote=quote):
                    config = "disabled_plugins = [" + quote + plugin + quote + "]\nSystemdCgroup = true\n"
                    result = self.run_bootstrap_check('validate_runtime_config "$MOCK_RUNTIME_CONFIG"',
                                                      MOCK_RUNTIME_CONFIG=config)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("disables CRI", result.stderr)

    def test_enabled_cri_allows_unrelated_disabled_plugins(self):
        for disabled in ("[]", "['io.containerd.snapshotter.v1.aufs']"):
            with self.subTest(disabled=disabled):
                result = self.run_bootstrap_check('validate_runtime_config "$MOCK_RUNTIME_CONFIG"',
                                                  MOCK_RUNTIME_CONFIG="disabled_plugins = " + disabled +
                                                  "\nSystemdCgroup = true\n")
                self.assertEqual(result.returncode, 0, result.stderr)

    def run_keyring_check(self, curl_exit="0", gpg_exit="0"):
        self.write_command("curl", '#!/usr/bin/env bash\nprintf "curl\\n" >> "$MOCK_LOG"\n'
                           'printf "%s" "$MOCK_KEY_DATA"\nexit "$MOCK_CURL_EXIT"\n')
        self.write_command("gpg", r'''#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
    if [[ $1 == --output ]]; then
        cat > "$2"
        exit "$MOCK_GPG_EXIT"
    fi
    shift
done
exit 99
''')
        return self.run_bootstrap_check('install_keyring "$MOCK_KEYRING" https://example.invalid/Release.key',
                                        MOCK_KEYRING=(self.folder / "keyring.gpg").as_posix(),
                                        MOCK_KEY_DATA="decoded-public-key", MOCK_CURL_EXIT=curl_exit,
                                        MOCK_GPG_EXIT=gpg_exit)

    def test_keyring_is_installed_after_success(self):
        result = self.run_keyring_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.folder / "keyring.gpg").read_text(encoding="utf-8"),
                         "decoded-public-key")
        self.assertEqual(list(self.folder.glob("keyring.gpg.*")), [])

    def test_curl_failure_does_not_publish_a_keyring(self):
        result = self.run_keyring_check(curl_exit="7")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.folder / "keyring.gpg").exists())
        self.assertEqual(list(self.folder.glob("keyring.gpg.*")), [])

    def test_gpg_failure_does_not_publish_a_keyring(self):
        result = self.run_keyring_check(gpg_exit="2")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.folder / "keyring.gpg").exists())
        self.assertEqual(list(self.folder.glob("keyring.gpg.*")), [])

    def test_existing_nonempty_keyring_is_preserved(self):
        keyring = self.folder / "keyring.gpg"
        keyring.write_text("existing-key", encoding="utf-8", newline="\n")
        result = self.run_keyring_check(curl_exit="7", gpg_exit="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(keyring.read_text(encoding="utf-8"), "existing-key")
        self.assertNotIn("curl", self.commands())

    def test_empty_keyring_from_an_interrupted_attempt_is_replaced(self):
        keyring = self.folder / "keyring.gpg"
        keyring.write_text("", encoding="utf-8", newline="\n")
        result = self.run_keyring_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(keyring.read_text(encoding="utf-8"), "decoded-public-key")
