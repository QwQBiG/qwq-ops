"""Run deployment entry points against isolated command stubs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("BASH_EXECUTABLE") or shutil.which("bash")

HELM = r'''#!/usr/bin/env bash
printf 'helm|%s\n' "$*" >> "$COMMAND_LOG"
[[ ${FAIL_HELM:-} != "$1" ]] || exit 42
case "$1" in
    list)
        if [[ $* != *--deployed* ]]; then
            if [[ -n ${LEGACY_LOKI:-} ]]; then
                printf '[{"name":"loki","chart":"loki-stack-2.10.2"}]\n'
            else printf '[]\n'; fi
            exit
        fi
        while (($#)); do
            if [[ $1 == --filter ]]; then
                release=$(printf '%s' "$2" | tr -d '^$')
                [[ ${MISSING_RELEASE:-} == "$release" ]] || printf '%s\n' "$release"
                exit
            fi
            shift
        done ;;
    template) printf '\n---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n' "$2" ;;
    upgrade) ;;
    *) printf 'Unexpected Helm command: %s\n' "$*" >&2; exit 64 ;;
esac
'''

KUBECTL = r'''#!/usr/bin/env bash
printf 'kubectl|%s\n' "$*" >> "$COMMAND_LOG"
[[ -z ${FAIL_KUBE:-} ]] || exit 43
if [[ $1 == --request-timeout=* ]]; then shift; fi
case "$*" in
    'cluster-info') ;;
    'get storageclass '*)
        if [[ $* == *metadata.name* ]]; then printf 'local-path|true|\n'
        else printf '%s\n' "${FAKE_STORAGE:-true}"; fi ;;
    'get nodes '*) printf '%s\n' "${FAKE_NODES-node|True}" ;;
    'get pods -n logging '*) printf '%s\n' "${LOGGING_PODS-${FAKE_PODS-pod|Running||True}}" ;;
    'get pods '*) printf '%s\n' "${FAKE_PODS-pod|Running||True}" ;;
    'get k8sgpt '*) printf 'qwen2.5:1.5b' ;;
    'get deployment/'*|'get statefulset/'*|'get daemonset/'*)
        if [[ $* == "get ${MISSING_WORKLOAD:-no-match} "* ]]; then exit 44; fi
        if [[ $* == *'/k8sgpt '* && -n ${MISSING_DIAGNOSIS:-} ]]; then exit; fi
        if [[ $* == *'/vmsingle-vm '* && -n ${MISSING_METRICS:-} ]]; then exit; fi
        if [[ $* == 'get daemonset/'* ]]; then
            printf '%s' "${DAEMONSET_STATUS:-1|1|1|1|1}"
        else printf '%s' "${WORKLOAD_STATUS:-1|1|1|1|1}"; fi ;;
    'exec '*) [[ -z ${FAIL_MODEL:-} ]] ;;
    'wait '*|'rollout status '*) ;;
    'apply -f -') cat >/dev/null ;;
    'apply -f '*) ;;
    *) printf 'Unexpected kubectl command: %s\n' "$*" >&2; exit 64 ;;
esac
'''


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="qwq tooling ")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.log = self.folder / "commands.log"
        for name, source in (("helm", HELM), ("kubectl", KUBECTL)):
            path = self.folder / name
            path.write_text(source, encoding="utf-8", newline="\n")
            path.chmod(0o755)

    def run_script(self, name, *args, **overrides):
        env = os.environ.copy()
        env.update(PATH=str(self.folder) + os.pathsep + env["PATH"],
                   COMMAND_LOG=self.log.as_posix())
        env.update(overrides)
        result = subprocess.run(
            [BASH, str(ROOT / "scripts" / name), *args], env=env,
            cwd=self.folder, capture_output=True, text=True, encoding="utf-8", timeout=20,
        )
        commands = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
        return result, commands

    def test_render_is_cluster_free_and_propagates_selected_model(self):
        result, commands = self.run_script("deploy.sh", "--render", "--model", "tinyllama:latest")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("kubectl|", commands)
        self.assertEqual(commands.count("helm|template "), 6)
        self.assertEqual(commands.count("--version "), 6)
        self.assertIn("ollama.models.pull[0]=tinyllama:latest", commands)
        resources = [doc for doc in yaml.safe_load_all(result.stdout) if doc]
        diagnosis = next(doc for doc in resources if doc["kind"] == "K8sGPT")
        self.assertEqual(diagnosis["spec"]["ai"]["model"], "tinyllama:latest")

    def test_chart_render_failure_stops_the_sequence(self):
        result, commands = self.run_script("deploy.sh", "--render", FAIL_HELM="template")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(commands.count("helm|template "), 1)
        self.assertNotIn("kind: K8sGPT", result.stdout)

    def test_cluster_failure_prevents_installation(self):
        result, commands = self.run_script("deploy.sh", FAIL_KUBE="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("helm|upgrade ", commands)

    def test_missing_default_storage_prevents_installation(self):
        result, commands = self.run_script("deploy.sh", FAKE_STORAGE="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("StorageClass", result.stderr)
        self.assertNotIn("helm|upgrade ", commands)

    def test_multiple_default_storage_classes_prevent_installation(self):
        result, commands = self.run_script("deploy.sh", FAKE_STORAGE="true|\n|true")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("helm|upgrade ", commands)

    def test_old_logging_chart_requires_a_migration(self):
        result, commands = self.run_script("deploy.sh", LEGACY_LOKI="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Migrate", result.stderr)
        self.assertNotIn("helm|upgrade ", commands)

    def test_chart_install_failure_stops_the_sequence(self):
        result, commands = self.run_script("deploy.sh", FAIL_HELM="upgrade")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(commands.count("helm|upgrade "), 1)
        self.assertNotIn("apply ", commands)

    def test_installation_applies_integrations_then_verifies(self):
        result, commands = self.run_script("deploy.sh", "--model", "qwen2.5:1.5b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands.count("helm|upgrade "), 6)
        self.assertIn("--wait-for-jobs", commands)
        self.assertIn("apply -f -", commands)
        self.assertIn("checks passed", result.stdout)

    def test_verification_healthy_path_is_read_only(self):
        result, commands = self.run_script("verify.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("checks passed", result.stdout)
        self.assertNotIn("apply ", commands)
        self.assertNotIn("upgrade ", commands)
        self.assertNotIn("delete ", commands)

    def test_verification_fails_for_empty_pods(self):
        result, _ = self.run_script("verify.sh", FAKE_PODS="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no active Pods", result.stderr)

    def test_verification_fails_for_unready_running_pods(self):
        result, _ = self.run_script("verify.sh", FAKE_PODS="pod|Running||False")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Ready=False", result.stderr)

    def test_verification_fails_for_empty_nodes(self):
        result, _ = self.run_script("verify.sh", FAKE_NODES="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no nodes", result.stderr)

    def test_verification_fails_for_missing_release(self):
        result, _ = self.run_script("verify.sh", MISSING_RELEASE="alloy")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("logging/alloy", result.stderr)

    def test_verification_fails_for_helm_api_error(self):
        result, _ = self.run_script("verify.sh", FAIL_HELM="list")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot read Helm release", result.stderr)

    def test_verification_fails_for_missing_model(self):
        result, _ = self.run_script("verify.sh", FAIL_MODEL="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot load", result.stderr)

    def test_verification_fails_without_diagnosis_workload(self):
        result, _ = self.run_script("verify.sh", MISSING_DIAGNOSIS="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("k8sgpt/deployment/k8sgpt", result.stderr)

    def test_verification_fails_without_metric_storage_workload(self):
        result, _ = self.run_script("verify.sh", MISSING_METRICS="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("vmsingle", result.stderr)

    def test_verification_fails_for_an_old_workload_generation(self):
        result, _ = self.run_script("verify.sh", WORKLOAD_STATUS="2|1|1|1|1")
        self.assertNotEqual(result.returncode, 0)

    def test_verification_fails_without_loki_despite_ready_logging_pods(self):
        result, commands = self.run_script(
            "verify.sh", MISSING_WORKLOAD="statefulset/loki",
            LOGGING_PODS="alloy-a|Running||True\nloki-gateway-a|Running||True",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot read logging/statefulset/loki", result.stderr)
        self.assertIn("get statefulset/loki -n logging", commands)

    def test_verification_fails_without_a_primary_chart_controller(self):
        for workload in (
            "deployment/grafana", "deployment/argocd-server",
            "deployment/k8sgpt-operator-controller-manager",
        ):
            with self.subTest(workload=workload):
                result, _ = self.run_script("verify.sh", MISSING_WORKLOAD=workload)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(workload, result.stderr)

    def test_verification_uses_daemonset_scheduling_and_availability(self):
        result, commands = self.run_script("verify.sh", DAEMONSET_STATUS="2|2|3|3|3")
        self.assertEqual(result.returncode, 0, result.stderr)
        query = next(line for line in commands.splitlines()
                     if "get daemonset/alloy " in line)
        self.assertIn(".status.desiredNumberScheduled", query)
        self.assertIn(".status.updatedNumberScheduled", query)
        self.assertIn(".status.numberAvailable", query)
        self.assertNotIn(".spec.replicas", query)

    def test_verification_fails_for_a_daemonset_with_no_scheduled_pods(self):
        result, _ = self.run_script("verify.sh", DAEMONSET_STATUS="1|1|0|0|0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("daemonset/alloy is not fully rolled out", result.stderr)

    def test_verification_fails_for_a_daemonset_without_available_pods(self):
        result, _ = self.run_script("verify.sh", DAEMONSET_STATUS="1|1|1|1|0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("daemonset/alloy is not fully rolled out", result.stderr)

    def test_verification_fails_for_a_daemonset_with_stale_replicas(self):
        result, _ = self.run_script("verify.sh", DAEMONSET_STATUS="2|2|2|1|2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("daemonset/alloy is not fully rolled out", result.stderr)
