#!/bin/bash
# .tooling/distribute/promote-to-base.sh の test。 作り物の base (= 手元の git repo) と派生を組み、 base が列挙して
# 派生が書いていない path の変更を書き戻す事、 派生が `!` で外した path と派生だけの file は書き戻さない事、
# `--file` で外した path を指すと断る事を確かめる。
#
#   bash .tooling/local-ci/test-promote-to-base.sh   (= `task ci` が呼ぶ)
set -uo pipefail

PROMOTE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/distribute/promote-to-base.sh"
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

# 作り物の base: 列挙する file 2 本。 派生は同じ 2 本を持ち、 両方を手元で書き換えてある
setup() {
    rm -rf "${BASE}" "${AGENT}"
    mkdir -p "${BASE}/src/.tooling/startup" "${BASE}/src/.tooling/lib" \
        "${AGENT}/.tooling/startup" "${AGENT}/.tooling/lib" "${AGENT}/.tooling/distribute"
    echo "status v1" > "${BASE}/src/.tooling/startup/status.sh"
    echo "helper v1" > "${BASE}/src/.tooling/lib/helper.sh"
    printf '%s\n' ".tooling/startup/status.sh" ".tooling/lib/helper.sh" > "${BASE}/.synced-paths.txt"
    git -C "${BASE}" init -q -b develop
    # commit の名前は機械の番人が許す公開の名前にする (= 番人の pre-commit は repo の user.email を見る)
    git -C "${BASE}" config user.name test
    git -C "${BASE}" config user.email noreply@github.com
    git -C "${BASE}" add -A
    git -C "${BASE}" commit -q -m "base"
    echo "status v2" > "${AGENT}/.tooling/startup/status.sh"
    echo "helper mine" > "${AGENT}/.tooling/lib/helper.sh"
    echo "only mine" > "${AGENT}/.tooling/startup/mine.sh"
    cp "${PROMOTE}" "${AGENT}/.tooling/distribute/"
    git -C "${AGENT}" init -q
}

promote() { BASE_REPO_PATH="${BASE}" FEATURE_BRANCH=feature/test bash "${AGENT}/.tooling/distribute/promote-to-base.sh" "$@" > "${T}/out" 2>&1; }

# --- 例外だけを書いた派生 -----------------------------------------------------------
setup
printf '%s\n' "!.tooling/lib/helper.sh   # this agent keeps its own" > "${AGENT}/.synced-paths.txt"
promote "chore: promote"
check "例外だけを書いた派生から昇格できる" [ $? -eq 0 ]
check "base が列挙して派生が書いていない path を書き戻す" \
    [ "$(git -C "${BASE}" show feature/test:src/.tooling/startup/status.sh 2>/dev/null)" = "status v2" ]
check "派生が ! で外した path は書き戻さない" \
    [ "$(git -C "${BASE}" show feature/test:src/.tooling/lib/helper.sh 2>/dev/null)" = "helper v1" ]
check "派生だけの file は書き戻さない" [ ! -e "${BASE}/src/.tooling/startup/mine.sh" ]

# --- --file で絞る -----------------------------------------------------------------
setup
printf '%s\n' "!.tooling/lib/helper.sh   # this agent keeps its own" > "${AGENT}/.synced-paths.txt"
promote --file .tooling/lib/helper.sh "chore: promote"
check "--file で派生が外した path を指すと断る" [ $? -ne 0 ]
promote --file .tooling/startup/mine.sh "chore: promote"
check "--file で派生だけの file を指すと断る" [ $? -ne 0 ]
promote --file .tooling/startup/status.sh "chore: promote"
check "--file で base が列挙する path を指せば書き戻す" \
    [ "$(git -C "${BASE}" show feature/test:src/.tooling/startup/status.sh 2>/dev/null)" = "status v2" ]

# --- 宣言を持たない古い base -------------------------------------------------------
setup
git -C "${BASE}" rm -q .synced-paths.txt
git -C "${BASE}" commit -q -m "no list"
printf '%s\n' ".tooling/startup/status.sh" > "${AGENT}/.synced-paths.txt"
promote "chore: promote"
check "宣言を持たない base へは派生の列挙を書き戻す" \
    [ "$(git -C "${BASE}" show feature/test:src/.tooling/startup/status.sh 2>/dev/null)" = "status v2" ]
check "宣言を持たない base へは派生が列挙しない path を書き戻さない" \
    [ "$(git -C "${BASE}" show feature/test:src/.tooling/lib/helper.sh 2>/dev/null)" = "helper v1" ]

echo "test-promote-to-base: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
