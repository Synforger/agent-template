#!/bin/bash
# .tooling/local-ci/synced-paths-check.sh の test。 作り物の型の木に script を写して流し、 skill の持ち主の印 (C) が
# 列挙した skill の `owner: template` の欠けと、 `!` の skill の `owner: template` を赤にし、 揃った木を緑にする事を確かめる。
#
#   bash .tooling/local-ci/test-synced-paths-check.sh
set -uo pipefail

CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/synced-paths-check.sh"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

check() { # <説明> <コマンド...>
    local what="$1"
    shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}

# tree <shipped の owner> <derived の owner>: 型の作り物の木を作る (= 列挙 1 本・`!` 1 本の skill)。 owner の空は行なし
tree() {
    rm -rf "${T}/repo"
    mkdir -p "${T}/repo/.tooling/local-ci" "${T}/repo/src/.claude/skills/shipped" "${T}/repo/src/.claude/skills/derived"
    cp "${CHECK}" "${T}/repo/.tooling/local-ci/"
    printf '.claude/skills/shipped/SKILL.md\n!.claude/skills/derived/SKILL.md  # the derivation owns it\n' > "${T}/repo/.synced-paths.txt"
    skill "${T}/repo/src/.claude/skills/shipped/SKILL.md" "$1"
    skill "${T}/repo/src/.claude/skills/derived/SKILL.md" "$2"
}
skill() { # <file> <owner>
    { printf -- '---\ntitle: x\n'; [ -n "$2" ] && printf 'owner: %s\n' "$2"; printf -- '---\n# x\n'; } > "$1"
}
run() { bash "${T}/repo/.tooling/local-ci/synced-paths-check.sh" > "${T}/out" 2>&1; }

tree template normal
run
check "揃った木は緑" [ $? -eq 0 ]

tree "" normal
run
check "列挙した skill の owner が無ければ赤" [ $? -eq 1 ]
check "赤の行が列挙した skill を名指す" grep -qF "owner mismatch: .claude/skills/shipped/SKILL.md (listed" "${T}/out"

tree normal ""
run
check "列挙した skill の owner が template でなければ赤" [ $? -eq 1 ]

tree template template
run
check "! の skill が owner: template を持てば赤" [ $? -eq 1 ]
check "赤の行が ! の skill を名指す" grep -qF "owner mismatch: .claude/skills/derived/SKILL.md (declared '!'" "${T}/out"

tree template ""
run
check "! の skill は owner が無くてもよい" [ $? -eq 0 ]

echo "test-synced-paths-check: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
