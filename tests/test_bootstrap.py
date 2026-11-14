"""Check bootstrap preconditions and key installation without changing a host."""
import json
from pathlib import Path
import shlex
import sys
import tempfile
import unittest

from helpers import ROOT, run_bash, write_command


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="qwq bootstrap ")
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)
        self.log = self.folder / "commands.log"
        self.env = {"MOCK_LOG": self.log.as_posix(),
                    "BOOTSTRAP_PATH": (ROOT / "scripts/bootstrap.sh").as_posix()}
        self.write_command("python3", '#!/usr/bin/env bash\nexec ' +
                           shlex.quote(Path(sys.executable).as_posix()) + ' "$@"\n')

    def write_command(self, name, content):
        write_command(self.folder, name, content)

    def run_bootstrap_check(self, command, **environment):
        return run_bash('source "$BOOTSTRAP_PATH"; ' + command,
                        folder=self.folder, env={**self.env, **environment})

    def commands(self):
        return self.log.read_text(encoding="utf-8") if self.log.exists() else ""

    def run_network_check(self, cidr, host_address="192.168.1.10", prefix=24):
        self.write_command("ip", '#!/usr/bin/env bash\nprintf "%s\\n" "$MOCK_ADDRESSES"\n')
        return self.run_bootstrap_check("validate_network", POD_CIDR=cidr,
                                       MOCK_ADDRESSES=json.dumps([{"addr_info": [
                                           {"local": host_address, "prefixlen": prefix}]}]))

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

    def test_service_network_overlap_with_host_is_rejected(self):
        for address in ("10.96.0.1", "10.96.0.10", "10.100.0.10"):
            with self.subTest(address=address):
                result = self.run_network_check("10.244.0.0/16", address)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Service CIDR overlaps host network", result.stderr)

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

    @staticmethod
    def runtime_config(plugin="io.containerd.grpc.v1.cri", quote='"',
                       default="true", other="false"):
        root = f"plugins.{quote}{plugin}{quote}.containerd"
        return (f"[{root}]\ndefault_runtime_name = {quote}runc{quote}\n"
                f"[{root}.runtimes.{quote}runc{quote}.options]\nSystemdCgroup = {default}\n"
                f"[{root}.runtimes.nvidia.options]\nSystemdCgroup = {other}\n")

    def run_runtime_check(self, config):
        return self.run_bootstrap_check('validate_runtime_config "$MOCK_RUNTIME_CONFIG"',
                                        MOCK_RUNTIME_CONFIG=config)

    def test_disabled_cri_plugins_are_rejected_in_both_dump_formats(self):
        plugins = ("cri", "io.containerd.grpc.v1.cri", "io.containerd.cri.v1.runtime",
                   "io.containerd.cri.v1.images")
        for plugin in plugins:
            for quote in ("'", '"'):
                with self.subTest(plugin=plugin, quote=quote):
                    config = "disabled_plugins = [" + quote + plugin + quote + "]\n"
                    result = self.run_runtime_check(config + self.runtime_config())
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("disables CRI", result.stderr)

    def test_enabled_cri_allows_unrelated_disabled_plugins(self):
        for disabled in ("[]", "['io.containerd.snapshotter.v1.aufs']"):
            with self.subTest(disabled=disabled):
                result = self.run_runtime_check("disabled_plugins = " + disabled +
                                                 "\n" + self.runtime_config())
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_only_default_runtime_must_enable_systemd_cgroups(self):
        for plugin in ("io.containerd.grpc.v1.cri", "io.containerd.cri.v1.runtime"):
            for quote in ("'", '"'):
                with self.subTest(plugin=plugin, quote=quote):
                    result = self.run_runtime_check(self.runtime_config(plugin, quote))
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_other_runtime_cannot_hide_disabled_default_cgroups(self):
        for plugin in ("io.containerd.grpc.v1.cri", "io.containerd.cri.v1.runtime"):
            for quote in ("'", '"'):
                with self.subTest(plugin=plugin, quote=quote):
                    result = self.run_runtime_check(self.runtime_config(
                        plugin, quote, default="false", other="true"))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Default runtime runc", result.stderr)

    def test_incomplete_default_runtime_configuration_is_rejected(self):
        for plugin in ("io.containerd.grpc.v1.cri", "io.containerd.cri.v1.runtime"):
            for quote in ("'", '"'):
                config = self.runtime_config(plugin, quote)
                root = f"plugins.{quote}{plugin}{quote}.containerd"
                cases = {
                    "table": config.replace(f"[{root}]\n", ""),
                    "runtime name": config.replace(f"default_runtime_name = {quote}runc{quote}\n", ""),
                    "options": config.split(f"[{root}.runtimes.", 1)[0],
                    "cgroup setting": config.replace("SystemdCgroup = true\n", "", 1),
                }
                for missing, incomplete in cases.items():
                    with self.subTest(plugin=plugin, quote=quote, missing=missing):
                        result = self.run_runtime_check(incomplete)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("[ERROR]", result.stderr)

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
