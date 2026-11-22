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

# 親の skill は owner を持つ (= 全階層のタブが読むので直すタブを名乗る)。 階層の中の skill は置き場が持ち主を決めるので見ない
S="${T}/skills"
mkdir -p "${S}/.claude/skills/no-owner" "${S}/.claude/skills/owned" "${S}/projects/P/.claude/skills/tier-local"
printf -- '---\ntitle: a\ndescription: a\n---\n' > "${S}/.claude/skills/no-owner/SKILL.md"
printf -- '---\ntitle: b\ndescription: b\nowner: normal\n---\n' > "${S}/.claude/skills/owned/SKILL.md"
printf -- '---\ntitle: c\ndescription: c\n---\n' > "${S}/projects/P/.claude/skills/tier-local/SKILL.md"
mkdir -p "${S}/.claude/skills/empty-owner"
printf -- '---\ntitle: d\ndescription: d\nowner:\n---\n' > "${S}/.claude/skills/empty-owner/SKILL.md"
python3 "${SCAN}" --root "${S}" > "${T}/skills.out" 2>&1
check "owner の無い親の skill は赤" grep -qF "no-owner/SKILL.md: frontmatter owner missing" "${T}/skills.out"
check "owner の在る親の skill は赤にしない" bash -c "! grep -qF 'owned/SKILL.md: frontmatter owner' '${T}/skills.out'"
check "値の無い owner: は赤" grep -qF "empty-owner/SKILL.md: frontmatter owner missing" "${T}/skills.out"
check "階層の中の skill は owner を見ない" bash -c "! grep -qF 'tier-local/SKILL.md: frontmatter owner' '${T}/skills.out'"

echo "test-docs-scan: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
