"""Small command-stub helpers shared by the script regression tests."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("BASH_EXECUTABLE") or shutil.which("bash")


def write_command(folder, name, source):
    path = folder / name
    path.write_text(source, encoding="utf-8", newline="\n")
    path.chmod(0o755)


def run_bash(command, *args, folder=None, env=None, timeout=20):
    environment = os.environ.copy()
    environment.update(env or {})
    if folder is not None:
        stub_bin = folder.as_posix()
        if os.name == "nt":
            stub_bin = "/" + stub_bin[0].lower() + stub_bin[2:]
        environment["QWQ_TEST_BIN"] = stub_bin
        # Git Bash may reorder the Windows PATH on startup. Prepend stubs inside
        # the running shell so tests cannot fall through to installed tools.
        command = 'export PATH="$QWQ_TEST_BIN:$PATH"; ' + command
    return subprocess.run(
        [BASH, "-c", command, "script-test", *args],
        cwd=folder or tempfile.gettempdir(), env=environment,
        text=True, encoding="utf-8", capture_output=True, timeout=timeout,
    )


def run_script(name, *args, folder=None, env=None):
    environment = dict(env or {})
    environment["QWQ_TEST_SCRIPT"] = (ROOT / "scripts" / name).as_posix()
    return run_bash('exec bash "$QWQ_TEST_SCRIPT" "$@"', *args,
                    folder=folder, env=environment)
