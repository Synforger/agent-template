#!/bin/bash
# .tooling/distribute/sync-from-base.sh の test。 作り物の base と派生を組み、 base が宣言して派生が宣言していない
# path が在る時は名指して何も写さずに止まる事、 宣言が揃えば写す事、 `!` 除外の path は写さない事を確かめる。
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

# 作り物の base: 出荷する file 3 本と、 その宣言
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
    echo "status v1" > "${AGENT}/.tooling/startup-status-v1"
}

sync() { BASE_REPO_PATH="${BASE}" bash "${AGENT}/.tooling/distribute/sync-from-base.sh" > "${T}/out" 2>&1; }

# --- 宣言が揃っている -------------------------------------------------------------
setup
printf '%s\n' ".tooling/startup/status.sh" ".tooling/lib/helper.sh" "!.tooling/startup/labels.example.txt" > "${AGENT}/.synced-paths.txt"
sync
check "宣言が揃えば exit 0" [ $? -eq 0 ]
check "列挙の path を写す" [ "$(cat "${AGENT}/.tooling/startup/status.sh" 2>/dev/null)" = "status v2" ]
check "! 除外の path は写さない" [ ! -e "${AGENT}/.tooling/startup/labels.example.txt" ]

# --- base が後から足した file を派生が宣言していない (= この test が実証する本体) ----------
setup
printf '%s\n' ".tooling/startup/status.sh" "!.tooling/startup/labels.example.txt" > "${AGENT}/.synced-paths.txt"
sync
check "宣言の欠けが在れば止まる" [ $? -ne 0 ]
check "欠けた path を名指す" grep -qxF "    .tooling/lib/helper.sh" "${T}/out"
check "止まった時は何も写さない (= 半端な取り込みを作らない)" [ ! -e "${AGENT}/.tooling/startup/status.sh" ]

setup
printf '%s\n' ".tooling/startup/status.sh" ".tooling/lib/helper.sh" > "${AGENT}/.synced-paths.txt"
sync
check "base の ! 除外を派生が宣言していなければ止まる" [ $? -ne 0 ]
check "! 除外は ! の付いた行のまま名指す" grep -qxF "    !.tooling/startup/labels.example.txt" "${T}/out"

# --- 派生が base の列挙を ! で外している ---------------------------------------------
setup
printf '%s\n' ".tooling/startup/status.sh" "!.tooling/lib/helper.sh   # this agent keeps its own" \
    "!.tooling/startup/labels.example.txt" > "${AGENT}/.synced-paths.txt"
sync
check "base の列挙を ! で外した派生は通る" [ $? -eq 0 ]
check "! で外した path は写さない" [ ! -e "${AGENT}/.tooling/lib/helper.sh" ]

# --- 宣言を持たない古い base -------------------------------------------------------
setup
rm "${BASE}/.synced-paths.txt"
printf '%s\n' ".tooling/startup/status.sh" > "${AGENT}/.synced-paths.txt"
sync
check "宣言を持たない base からは今までどおり写す" [ "$(cat "${AGENT}/.tooling/startup/status.sh" 2>/dev/null)" = "status v2" ]

echo "test-sync-from-base: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
