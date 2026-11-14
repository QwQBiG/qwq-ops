"""Validate the default runtime in a normalized `containerd config dump`.

Only the known CRI tables and their normalized scalar values are recognized.
This intentionally does not parse arbitrary TOML configuration files.
"""
import re
import sys


PLUGIN_IDS = ("io.containerd.grpc.v1.cri", "io.containerd.cri.v1.runtime")
ROOT_TABLES = {
    f"plugins.{quote}{plugin}{quote}.containerd": plugin
    for plugin in PLUGIN_IDS for quote in ("'", '"')
}
RUNTIME_NAME = r"[A-Za-z0-9_-]+"
QUOTED_NAME = re.compile(r"(['\"])(" + RUNTIME_NAME + r")\1")


def validate(config):
    roots, options = {}, {}
    current = None
    for line in config.splitlines():
        line = line.strip()
        if line.startswith("["):
            current = None
            if not line.endswith("]"):
                continue
            table = line[1:-1]
            for root, plugin in ROOT_TABLES.items():
                if table == root:
                    if plugin in roots:
                        raise ValueError("Ambiguous CRI runtime configuration tables.")
                    roots[plugin] = {}
                    current = roots[plugin]
                    break
                prefix = root + ".runtimes."
                if table.startswith(prefix) and table.endswith(".options"):
                    name = table[len(prefix):-len(".options")]
                    quoted = QUOTED_NAME.fullmatch(name)
                    name = quoted.group(2) if quoted else name
                    if not re.fullmatch(RUNTIME_NAME, name):
                        continue
                    key = (plugin, name)
                    if key in options:
                        raise ValueError("Ambiguous runtime options for " + name + ".")
                    options[key] = {}
                    current = options[key]
                    break
        elif current is not None and "=" in line:
            key, value = (part.strip() for part in line.split("=", 1))
            if key in ("default_runtime_name", "SystemdCgroup"):
                if key in current:
                    raise ValueError("Ambiguous runtime setting: " + key + ".")
                current[key] = value

    if len(roots) != 1:
        raise ValueError("Cannot identify a single CRI runtime table in containerd config dump.")
    plugin, runtime = next(iter(roots.items()))
    name = QUOTED_NAME.fullmatch(runtime.get("default_runtime_name", ""))
    if name is None:
        raise ValueError("Cannot identify default_runtime_name in containerd config dump.")
    name = name.group(2)
    settings = options.get((plugin, name))
    if settings is None:
        raise ValueError("Cannot identify the default runtime options for " + name + ".")
    if settings.get("SystemdCgroup") != "true":
        raise ValueError("Default runtime " + name + " must explicitly enable SystemdCgroup.")


if __name__ == "__main__":
    try:
        validate(sys.stdin.read())
    except ValueError as error:
        sys.exit("[ERROR] " + str(error) + " Review the existing containerd configuration manually.")
