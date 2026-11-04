#!/bin/bash
# .tooling/distribute/sync-from-base.sh の test。 作り物の base と派生を組み、 base の列挙が派生に何も書かなくても
# 全部降りる事、 base が後から足した path も降りる事、 理由つきの `!` は外れて理由が並ぶ事、 理由の無い `!` は
# 名指して何も写さずに止まる事、 base の `!` は降ろさない事を確かめる。
#
#   bash .tooling/local-ci/test-sync-from-base.sh   (= `task ci` が呼ぶ)
set -uo pipefail

SYNC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/distribute/sync-from-base.sh"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

BASE="${T}/base"
AGENT="${T}/agent"

check() { # <説明> <コマンド...>
    local what="$1"
    shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}

# 作り物の base: 列挙する file 2 本と、 派生の持ち物として `!` で宣言する file 1 本
setup() {
    rm -rf "${BASE}" "${AGENT}"
    mkdir -p "${BASE}/src/.tooling/startup" "${BASE}/src/.tooling/lib" "${AGENT}/.tooling/distribute"
    echo "status v2" > "${BASE}/src/.tooling/startup/status.sh"
    echo "helper v2" > "${BASE}/src/.tooling/lib/helper.sh"
    echo "example" > "${BASE}/src/.tooling/startup/labels.example.txt"
    printf '%s\n' "# base" ".tooling/startup/status.sh" ".tooling/lib/helper.sh" \
        "!.tooling/startup/labels.example.txt   # each agent keeps its own" > "${BASE}/.synced-paths.txt"
    cp "${SYNC}" "${AGENT}/.tooling/distribute/"
    git -C "${AGENT}" init -q
}

sync() { BASE_REPO_PATH="${BASE}" bash "${AGENT}/.tooling/distribute/sync-from-base.sh" > "${T}/out" 2>&1; }

# --- 例外を書かない派生は、 base の列挙を全部受け取る ---------------------------------
setup
printf '%s\n' "# exceptions only" > "${AGENT}/.synced-paths.txt"
sync
check "例外の無い派生は exit 0" [ $? -eq 0 ]
check "base の列挙を写す (1)" [ "$(cat "${AGENT}/.tooling/startup/status.sh" 2>/dev/null)" = "status v2" ]
check "base の列挙を写す (2)" [ "$(cat "${AGENT}/.tooling/lib/helper.sh" 2>/dev/null)" = "helper v2" ]
check "base の ! は写さない" [ ! -e "${AGENT}/.tooling/startup/labels.example.txt" ]

# --- base が後から足した file は、 派生が何もしなくても降りる (= この変更が実証する本体) -------
setup
printf '%s\n' "# exceptions only" > "${AGENT}/.synced-paths.txt"
sync
mkdir -p "${BASE}/src/.claude/skills/new-skill"
echo "new skill" > "${BASE}/src/.claude/skills/new-skill/SKILL.md"
echo ".claude/skills/new-skill/SKILL.md" >> "${BASE}/.synced-paths.txt"
sync
check "base が足した path が在っても止まらない" [ $? -eq 0 ]
check "base が足した path が降りる" [ "$(cat "${AGENT}/.claude/skills/new-skill/SKILL.md" 2>/dev/null)" = "new skill" ]

# --- 理由つきの ! は外れて、 理由が並ぶ -------------------------------------------------
setup
printf '%s\n' "!.tooling/lib/helper.sh   # this agent keeps its own" > "${AGENT}/.synced-paths.txt"
sync
check "理由つきの ! は通る" [ $? -eq 0 ]
check "理由つきの ! で外した path は写さない" [ ! -e "${AGENT}/.tooling/lib/helper.sh" ]
check "外した path の残りは写す" [ "$(cat "${AGENT}/.tooling/startup/status.sh" 2>/dev/null)" = "status v2" ]
check "外した path を理由つきで並べる" grep -qxF "    .tooling/lib/helper.sh  # this agent keeps its own" "${T}/out"

# --- base の列挙を、 理由の無い ! で外している ------------------------------------------
setup
printf '%s\n' "!.tooling/lib/helper.sh" > "${AGENT}/.synced-paths.txt"
sync
check "理由の無い ! は止まる" [ $? -ne 0 ]
check "理由の無い ! の行を名指す" grep -qxF "    !.tooling/lib/helper.sh" "${T}/out"
check "止まった時は何も写さない" [ ! -e "${AGENT}/.tooling/startup/status.sh" ]

setup
printf '%s\n' "!.tooling/lib/helper.sh   #   " > "${AGENT}/.synced-paths.txt"
sync
check "# の後ろが空白だけの ! も理由の無い ! として止まる" [ $? -ne 0 ]

# --- base が列挙していない path の ! は理由が無くても通る (= base の ! と同じ宣言) ------------
setup
printf '%s\n' "!.tooling/startup/labels.example.txt" > "${AGENT}/.synced-paths.txt"
sync
check "base が列挙しない path の理由の無い ! は通る" [ $? -eq 0 ]

# --- 派生が足す path と、 base の宣言を全部写した古い派生の file ---------------------------
setup
printf '%s\n' ".tooling/startup/labels.example.txt" > "${AGENT}/.synced-paths.txt"
sync
check "派生が列挙した path は base の ! でも受け取る" [ "$(cat "${AGENT}/.tooling/startup/labels.example.txt" 2>/dev/null)" = "example" ]

setup
cp "${BASE}/.synced-paths.txt" "${AGENT}/.synced-paths.txt"
sync
check "base の宣言を全部写した派生の file は今までどおり通る" [ $? -eq 0 ]
check "同じ path を 2 か所が列挙しても 1 回だけ写す" grep -qF "sync 2 paths" "${T}/out"

# --- 宣言を持たない古い base -------------------------------------------------------
setup
rm "${BASE}/.synced-paths.txt"
printf '%s\n' ".tooling/startup/status.sh" > "${AGENT}/.synced-paths.txt"
sync
check "宣言を持たない base からは派生の列挙を写す" [ "$(cat "${AGENT}/.tooling/startup/status.sh" 2>/dev/null)" = "status v2" ]
check "宣言を持たない base からは派生が列挙しない path を写さない" [ ! -e "${AGENT}/.tooling/lib/helper.sh" ]

echo "test-sync-from-base: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
