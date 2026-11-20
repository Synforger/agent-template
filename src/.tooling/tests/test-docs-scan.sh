#!/bin/bash
# .tooling/docs-check/docs-scan.py の test。 作り物の木を --root で渡し、 道具の cache の folder (印の file CACHEDIR.TAG を
# 持つ folder) の下の .md は frontmatter の検査に掛けず、 同じ形の印の無い folder の .md は今までどおり掛ける事を確かめる。
#
#   bash .tooling/tests/test-docs-scan.sh
set -uo pipefail

SCAN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs-check/docs-scan.py"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

check() { # <説明> <コマンド...>
    local what="$1"
    shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}

# 作り物の木: frontmatter の無い README.md を、 cache の印を持つ folder と持たない folder に 1 本ずつ置く
mkdir -p "${T}/tool/.pytest_cache" "${T}/tool/notes"
printf 'Signature: 8a477f597d28d172789f06886806bc55\n' > "${T}/tool/.pytest_cache/CACHEDIR.TAG"
printf '# cache\n' > "${T}/tool/.pytest_cache/README.md"
printf '# notes\n' > "${T}/tool/notes/README.md"

python3 "${SCAN}" --root "${T}" > "${T}/out" 2>&1
check "cache の印を持つ folder の .md は検査しない" bash -c "! grep -qF '.pytest_cache/README.md' '${T}/out'"
check "印の無い folder の .md は今までどおり検査する" grep -qF "notes/README.md: no frontmatter" "${T}/out"

echo "test-docs-scan: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
