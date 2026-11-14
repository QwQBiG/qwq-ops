"""Execute the configured model bootstrap hook with an isolated Ollama CLI."""
from pathlib import Path
import tempfile
import unittest

import yaml

from helpers import ROOT, run_bash, write_command

OLLAMA = r'''#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COMMAND_LOG"
case "$1" in
    ps) exit 0 ;;
    show) exit "${SHOW_STATUS:-0}" ;;
    pull) exit "${PULL_STATUS:-0}" ;;
    *) exit 64 ;;
esac
'''


class OllamaBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="qwq ollama ")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.log = self.folder / "commands.log"
        write_command(self.folder, "ollama", OLLAMA)
        self.values = yaml.safe_load(
            (ROOT / "config/helm/ollama.yaml").read_text(encoding="utf-8"))

    def run_hook(self, show_status, pull_status):
        model_env = self.values["extraEnv"][0]["name"]
        command = self.values["lifecycle"]["postStart"]["exec"]["command"]
        env = {"COMMAND_LOG": self.log.as_posix(), "SHOW_STATUS": str(show_status),
               "PULL_STATUS": str(pull_status)}
        env[model_env] = "tinyllama:latest"
        # Git Bash supplies /bin/sh on Windows; execute the values command intact.
        result = run_bash('exec "$@"', *command, folder=self.folder, env=env, timeout=10)
        calls = self.log.read_text(encoding="utf-8").splitlines()
        return result, calls

    def test_cached_model_starts_without_registry_access(self):
        result, calls = self.run_hook(show_status=0, pull_status=42)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["ps", "show tinyllama:latest"])

    def test_missing_model_is_downloaded(self):
        result, calls = self.run_hook(show_status=1, pull_status=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["ps", "show tinyllama:latest", "pull tinyllama:latest"])

    def test_download_failure_remains_a_startup_failure(self):
        result, calls = self.run_hook(show_status=1, pull_status=42)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(calls, ["ps", "show tinyllama:latest", "pull tinyllama:latest"])
