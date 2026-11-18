"""Run deployment entry points against isolated command stubs."""
from pathlib import Path
import tempfile
import unittest

import yaml

from helpers import run_script, write_command

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
get_k8sgpt_config() {
    if [[ -f $COMMAND_LOG.config ]]; then cat "$COMMAND_LOG.config"
    else printf '%s' "${K8SGPT_CONFIG-qwen2.5:1.5b|localai|http://ollama.ai.svc.cluster.local:11434/v1|ghcr.io/k8sgpt-ai/k8sgpt|v0.4.41}"; fi
}
case "$*" in
    'cluster-info') ;;
    'get storageclass '*)
        if [[ $* == *metadata.name* ]]; then printf 'local-path|true|\n'
        else printf '%s\n' "${FAKE_STORAGE:-true}"; fi ;;
    'get nodes '*'.status.allocatable.nvidia'*)
        [[ -z ${FAIL_GPU_QUERY:-} ]] || exit 48
        printf '%s\n' "${GPU_CAPACITY:-}" ;;
    'get nodes '*) printf '%s\n' "${FAKE_NODES-node|True}" ;;
    'get pods -n logging '*) printf '%s\n' "${LOGGING_PODS-${FAKE_PODS-pod|Running||True}}" ;;
    'get pods '*) printf '%s\n' "${FAKE_PODS-pod|Running||True}" ;;
    'get vmsingle/vm '*|'get vmagent/vm '*|'get vmalert/vm '*|'get vmalertmanager/vm '*)
        [[ ${MISSING_MONITORING_RESOURCE:-} != "$2" ]] || exit 47
        if [[ $* == *status.observedGeneration* ]]; then
            printf '%s' "${MONITORING_STATUS-2|2|operational}"
        else printf '%s' "${MONITORING_GENERATION-2}"; fi ;;
    'get k8sgpt '*)
        [[ -z ${FAIL_K8SGPT_CONFIG:-} ]] || exit 45
        get_k8sgpt_config ;;
    'get deployment/k8sgpt '*'.spec.template.spec.containers'*)
        [[ -z ${FAIL_K8SGPT_TEMPLATE:-} ]] || exit 45
        IFS='|' read -r model backend base_url repository version <<< "$(get_k8sgpt_config)"
        printf '%s\n' "${DEPLOYMENT_MODEL-$model}" "${DEPLOYMENT_BACKEND-$backend}" \
            "${DEPLOYMENT_BASEURL-$base_url}" "${DEPLOYMENT_IMAGE-$repository:${version:-latest}}" ;;
    'get deployment/'*|'get statefulset/'*|'get daemonset/'*)
        if [[ $* == "get ${MISSING_WORKLOAD:-no-match} "* ]]; then exit 44; fi
        if [[ $* == *'/k8sgpt '* && -n ${MISSING_DIAGNOSIS:-} ]]; then exit; fi
        if [[ $* == *'/vmsingle-vm '* && -n ${MISSING_METRICS:-} ]]; then exit; fi
        if [[ $* == 'get daemonset/'* ]]; then
            printf '%s' "${DAEMONSET_STATUS:-1|1|1|1|1}"
        else printf '%s' "${WORKLOAD_STATUS:-1|1|1|1|1}"; fi ;;
    'exec '*) [[ -z ${FAIL_MODEL:-} ]] ;;
    'wait --for=jsonpath='*)
        [[ $* != *"${FAIL_CONFIG_WAIT:-no-match}"* ]] || exit 46 ;;
    'wait '*|'rollout status '*) ;;
    'apply -f -')
        manifest=$(cat)
        model=$(sed -n 's/^    model: "\(.*\)"/\1/p' <<< "$manifest")
        version=$(sed -n 's/^  version: "\(.*\)"/\1/p' <<< "$manifest")
        printf '%s|localai|http://ollama.ai.svc.cluster.local:11434/v1|ghcr.io/k8sgpt-ai/k8sgpt|%s' \
            "$model" "$version" > "$COMMAND_LOG.config" ;;
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
            write_command(self.folder, name, source)

    def run_script(self, name, *args, **overrides):
        env = {"COMMAND_LOG": self.log.as_posix(), **overrides}
        result = run_script(name, *args, folder=self.folder, env=env)
        commands = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
        return result, commands

    def test_render_is_cluster_free_and_propagates_selected_model(self):
        result, commands = self.run_script("deploy.sh", "--render", "--model", "tinyllama:latest")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("kubectl|", commands)
        self.assertEqual(commands.count("helm|template "), 6)
        self.assertEqual(commands.count("--version "), 6)
        self.assertIn("extraEnv[0].value=tinyllama:latest", commands)
        self.assertNotIn("ollama.gpu.enabled", commands)
        resources = [doc for doc in yaml.safe_load_all(result.stdout) if doc]
        diagnosis = next(doc for doc in resources if doc["kind"] == "K8sGPT")
        self.assertEqual(diagnosis["spec"]["ai"]["model"], "tinyllama:latest")

    def test_gpu_preview_works_without_a_cluster(self):
        result, commands = self.run_script("deploy.sh", "--render", "--nvidia-gpu")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("kubectl|", commands)
        ollama = next(line for line in commands.splitlines() if line.startswith("helm|template ollama "))
        for setting in ("ollama.gpu.enabled=true", "ollama.gpu.type=nvidia", "ollama.gpu.number=1"):
            self.assertIn(setting, ollama)

    def test_gpu_deployment_requires_allocatable_capacity_before_helm(self):
        for capacity in ("", "0"):
            with self.subTest(capacity=capacity):
                self.log.unlink(missing_ok=True)
                result, commands = self.run_script("deploy.sh", "--nvidia-gpu", GPU_CAPACITY=capacity)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("allocatable nvidia.com/gpu", result.stderr)
                self.assertNotIn("helm|", commands)
        self.log.unlink(missing_ok=True)
        result, commands = self.run_script("deploy.sh", "--nvidia-gpu", GPU_CAPACITY="0\n1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ollama.gpu.enabled=true", commands)

    def test_gpu_capacity_api_failure_stops_deployment(self):
        result, commands = self.run_script("deploy.sh", "--nvidia-gpu", FAIL_GPU_QUERY="yes")
        self.assertEqual(result.returncode, 48)
        self.assertNotIn("helm|", commands)

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

    def test_installation_waits_for_the_selected_analyzer_configuration(self):
        result, commands = self.run_script(
            "deploy.sh", "--model", "tinyllama:latest", K8SGPT_VERSION="v0.4.42", WAIT_TIMEOUT="17s")
        self.assertEqual(result.returncode, 0, result.stderr)
        waits = [line for line in commands.splitlines()
                 if "wait --for=jsonpath=" in line and " deployment/k8sgpt " in line]
        self.assertEqual(len(waits), 4)
        for expected in ("K8SGPT_MODEL", "tinyllama:latest", "K8SGPT_BACKEND", "localai",
                         "K8SGPT_BASEURL", "http://ollama.ai.svc.cluster.local:11434/v1",
                         "ghcr.io/k8sgpt-ai/k8sgpt:v0.4.42", "--timeout=17s"):
            self.assertIn(expected, "\n".join(waits))
        self.assertLess(commands.index("apply -f -"), commands.index(waits[0]))
        self.assertLess(commands.index(waits[-1]), commands.index("rollout status deployment/k8sgpt"))

    def test_installation_stops_when_the_operator_keeps_an_old_configuration(self):
        for field in ("K8SGPT_MODEL", "K8SGPT_BACKEND", "K8SGPT_BASEURL", "].image}"):
            with self.subTest(field=field):
                self.log.unlink(missing_ok=True)
                result, commands = self.run_script("deploy.sh", FAIL_CONFIG_WAIT=field)
                self.assertEqual(result.returncode, 46, result.stderr)
                self.assertNotIn("rollout status deployment/k8sgpt", commands)
                self.assertNotIn("checks passed", result.stdout)

    def test_installation_waits_for_current_monitoring_resources_before_rollouts(self):
        result, commands = self.run_script("deploy.sh", WAIT_TIMEOUT="17s")
        self.assertEqual(result.returncode, 0, result.stderr)
        waits = [line for line in commands.splitlines()
                 if "wait --for=jsonpath=" in line and " -n monitoring " in line]
        self.assertEqual(len(waits), 8)
        for resource in ("vmsingle/vm", "vmagent/vm", "vmalert/vm", "vmalertmanager/vm"):
            matching = [line for line in waits if f" {resource} " in line]
            self.assertEqual(len(matching), 2, resource)
            self.assertIn("{.status.observedGeneration}=2", matching[0])
            self.assertIn("{.status.updateStatus}=operational", matching[1])
            self.assertTrue(all("--timeout=17s" in line for line in matching))
        self.assertLess(commands.index(waits[-1]), commands.index("rollout status deployment/vmsingle-vm"))

    def test_installation_stops_for_unreconciled_monitoring_resources(self):
        for field in (".status.observedGeneration", ".status.updateStatus"):
            with self.subTest(field=field):
                self.log.unlink(missing_ok=True)
                result, commands = self.run_script("deploy.sh", FAIL_CONFIG_WAIT=field)
                self.assertEqual(result.returncode, 46, result.stderr)
                self.assertNotIn("rollout status deployment/vmsingle-vm", commands)
                self.assertNotIn("checks passed", result.stdout)

    def test_installation_requires_a_readable_monitoring_generation(self):
        for overrides in ({"MISSING_MONITORING_RESOURCE": "vmsingle/vm"},
                          {"MONITORING_GENERATION": ""}):
            with self.subTest(overrides=overrides):
                self.log.unlink(missing_ok=True)
                result, commands = self.run_script("deploy.sh", **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("rollout status deployment/vmsingle-vm", commands)

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

    def test_verification_rejects_stale_analyzer_configuration_despite_ready_replicas(self):
        for field, value in (("DEPLOYMENT_MODEL", "old:latest"),
                             ("DEPLOYMENT_BACKEND", "openai"),
                             ("DEPLOYMENT_BASEURL", "http://old:11434/v1"),
                             ("DEPLOYMENT_IMAGE", "ghcr.io/k8sgpt-ai/k8sgpt:v0.4.40"),
                             ("DEPLOYMENT_MODEL", "")):
            with self.subTest(field=field, value=value):
                result, _ = self.run_script("verify.sh", **{field: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("does not match its integration", result.stderr)

    def test_verification_reads_the_current_integration_instead_of_version_defaults(self):
        config = ("tinyllama:latest|localai|http://ollama.ai.svc.cluster.local:11434/v1|"
                  "ghcr.io/k8sgpt-ai/k8sgpt|v0.4.42")
        result, _ = self.run_script("verify.sh", K8SGPT_CONFIG=config)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_verification_fails_for_unreadable_analyzer_configuration(self):
        for failure in ("FAIL_K8SGPT_CONFIG", "FAIL_K8SGPT_TEMPLATE"):
            with self.subTest(failure=failure):
                result, _ = self.run_script("verify.sh", **{failure: "yes"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Cannot read", result.stderr)

    def test_verification_rejects_old_or_failed_monitoring_reconciliation(self):
        for state in ("2|1|operational", "2|2|failed", "2|2|expanding"):
            with self.subTest(state=state):
                result, _ = self.run_script("verify.sh", MONITORING_STATUS=state)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("vmsingle/vm is not fully reconciled", result.stderr)

    def test_verification_requires_every_monitoring_resource_status(self):
        for resource in ("vmsingle/vm", "vmagent/vm", "vmalert/vm", "vmalertmanager/vm"):
            with self.subTest(resource=resource):
                result, _ = self.run_script("verify.sh", MISSING_MONITORING_RESOURCE=resource)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"Cannot read monitoring/{resource}", result.stderr)
        result, _ = self.run_script("verify.sh", MONITORING_STATUS="2||")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete reconciliation status", result.stderr)

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

    def test_retained_platform_pods_do_not_hide_a_recovered_controller(self):
        for retained in ("old|Failed||False", "old|Running|2026-11-16T00:00:00Z|False"):
            with self.subTest(retained=retained):
                result, _ = self.run_script(
                    "verify.sh", LOGGING_PODS="current|Running||True\n" + retained)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("retained Pod", result.stderr)

    def test_retained_platform_pods_alone_are_not_healthy(self):
        result, _ = self.run_script("verify.sh", LOGGING_PODS="old|Failed||False")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("logging has no active Pods", result.stderr)

    def test_retained_infrastructure_pods_remain_failures(self):
        result, _ = self.run_script("verify.sh", FAKE_PODS="current|Running||True\nold|Failed||False")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("kube-system/old", result.stderr)

    def test_pending_platform_pods_remain_failures(self):
        result, _ = self.run_script("verify.sh", LOGGING_PODS="current|Pending||False")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("logging/current: phase=Pending", result.stderr)
