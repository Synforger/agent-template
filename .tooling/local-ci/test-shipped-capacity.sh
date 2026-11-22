#!/bin/bash
# Fails when a file the template ships is over the `capacity:` it declares, so that a derived agent's docs-check
# does not turn red on its next sync. The judgement is the shipped docs-scan.py's step 2; this file only calls it.
#
#   bash .tooling/local-ci/test-shipped-capacity.sh   (called by `task ci`)
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../src" && pwd)"
SCAN="${SRC}/.tooling/docs-check/docs-scan.py"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

# the capacity failures of one tree, one per line; a scan that cannot run is a failure too
over() { # <root>
    python3 -I "${SCAN}" --root "$1" > "${T}/scan.tsv" || { echo "docs-scan.py did not run on $1"; return; }
    awk -F '\t' '$1 == 2 && $2 == "fail" { print $3 }' "${T}/scan.tsv"
}

failed=0

# the check itself turns red on a file over its capacity
mkdir -p "${T}/sample"
{ printf -- '---\ntitle: sample\ncapacity: 1KB\n---\n'; printf '%01100d\n' 0; } > "${T}/sample/over.md"
case "$(over "${T}/sample")" in
    *"over.md"*"declared capacity 1KB"*) ;;
    *) echo "FAIL: a sample over its capacity was not reported"; failed=1 ;;
esac

found="$(over "${SRC}")"
if [ -n "${found}" ]; then
    echo "FAIL: shipped files over their declared capacity"
    echo "${found}"
    failed=1
fi

echo "shipped-capacity: failed=${failed}"
exit "${failed}"
