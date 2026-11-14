#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"
require_command bash shellcheck python3
cd "$ROOT"

while IFS= read -r -d '' script; do
    bash -n "$script"
    shellcheck --external-sources --source-path=SCRIPTDIR "$script"
done < <(find scripts tests -type f -name '*.sh' -print0)
python3 -m unittest discover -s tests -v
