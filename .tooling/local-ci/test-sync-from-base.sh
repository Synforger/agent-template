#!/bin/bash
# .tooling/distribute/sync-from-base.sh の test。 作り物の base と派生を組み、 base の列挙が派生に何も書かなくても
# 全部降りる事、 base が後から足した path も降りる事、 理由つきの `!` は外れて理由が並ぶ事、 理由の無い `!` は
# 名指して何も写さずに止まる事、 base の `!` は降ろさない事を確かめる。 base が git の repo の時は、 前の取り込みの
# 版を記録し、 その後に派生だけが変えた file を名指して止まる事、 記録が無い時は base の履歴に無い版で止まる事、 最後の docs-check が赤なら commit の案内を出さない
# 事も確かめる。
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

# 出力に <文字列> が無い
lacks() { ! grep -qF -- "$1" "${T}/out"; }

sync() { BASE_REPO_PATH="${BASE}" bash "${AGENT}/.tooling/distribute/sync-from-base.sh" "$@" > "${T}/out" 2>&1; }

# --- --help は説明だけを出して何も写さず、 知らない引数は断る ------------------------------
setup
printf '%s\n' "# exceptions only" > "${AGENT}/.synced-paths.txt"
sync --help
check "--help は exit 0" [ $? -eq 0 ]
check "--help は Usage を出す" grep -qF "Usage:" "${T}/out"
check "--help は何も写さない" [ ! -e "${AGENT}/.tooling/startup/status.sh" ]
sync --bogus
check "知らない引数は exit 2" [ $? -eq 2 ]
check "知らない引数を名指す" grep -qF "unknown argument '--bogus'" "${T}/out"
check "知らない引数では何も写さない" [ ! -e "${AGENT}/.tooling/startup/status.sh" ]

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

# --- 最後の行が注釈の宣言 ----------------------------------------------------------
setup
printf '%s\n' "!.tooling/lib/helper.sh   # this agent keeps its own" "# trailing note" > "${AGENT}/.synced-paths.txt"
sync
check "最後の行が注釈の宣言でも通る" [ $? -eq 0 ]

# --- 機械全体の印 `# @machine-wide`: 印つきの path を `!@machine-wide` の 1 行で外す ---------------------
mark_base() {
    setup
    mkdir -p "${BASE}/src/.tooling/hooks"
    echo "gate v2" > "${BASE}/src/.tooling/hooks/gate.py"
    echo "gate test v2" > "${BASE}/src/.tooling/hooks/test-gate.sh"
    printf '%s\n' ".tooling/hooks/gate.py   # @machine-wide the account settings call one copy" \
        ".tooling/hooks/test-gate.sh   # @machine-wide" >> "${BASE}/.synced-paths.txt"
}

mark_base
printf '%s\n' "# exceptions only" > "${AGENT}/.synced-paths.txt"
sync
check "印つきの path も、 何も書かない派生には降りる" [ "$(cat "${AGENT}/.tooling/hooks/gate.py" 2>/dev/null)" = "gate v2" ]

mark_base
printf '%s\n' "!@machine-wide  # this machine's hooks come from another agent" > "${AGENT}/.synced-paths.txt"
sync
check "!@machine-wide に理由があれば通る" [ $? -eq 0 ]
check "!@machine-wide で印つきの path を全部外す" [ ! -e "${AGENT}/.tooling/hooks/gate.py" ] && [ ! -e "${AGENT}/.tooling/hooks/test-gate.sh" ]
check "!@machine-wide でも印の無い path は写す" [ "$(cat "${AGENT}/.tooling/lib/helper.sh" 2>/dev/null)" = "helper v2" ]
check "!@machine-wide を理由つきで並べる" grep -qxF "    @machine-wide  # this machine's hooks come from another agent" "${T}/out"

mark_base
printf '%s\n' "!@machine-wide" > "${AGENT}/.synced-paths.txt"
sync
check "理由の無い !@machine-wide は止まる" [ $? -ne 0 ]
check "理由の無い !@machine-wide を名指す" grep -qxF "    !@machine-wide" "${T}/out"
check "理由の無い !@machine-wide では何も写さない" [ ! -e "${AGENT}/.tooling/startup/status.sh" ]

# --- 宣言を持たない古い base -------------------------------------------------------
setup
rm "${BASE}/.synced-paths.txt"
printf '%s\n' ".tooling/startup/status.sh" > "${AGENT}/.synced-paths.txt"
sync
check "宣言を持たない base からは派生の列挙を写す" [ "$(cat "${AGENT}/.tooling/startup/status.sh" 2>/dev/null)" = "status v2" ]
check "宣言を持たない base からは派生が列挙しない path を写さない" [ ! -e "${AGENT}/.tooling/lib/helper.sh" ]

# --- base が git の repo: 前の取り込みの版を記録し、 派生だけの変更で止まる -----------------------
GIT_ID=(-c user.name=test -c user.email=noreply@github.com -c commit.gpgsign=false)

base_commit() { git "${GIT_ID[@]}" -C "${BASE}" add -A && git "${GIT_ID[@]}" -C "${BASE}" commit -qm "$1"; }

# 単体の file 2 本と、 folder ごと配る skill 1 本を持つ git の base
setup_git() {
    setup
    mkdir -p "${BASE}/src/.claude/skills/demo"
    echo "demo v1" > "${BASE}/src/.claude/skills/demo/SKILL.md"
    echo ".claude/skills/demo/" >> "${BASE}/.synced-paths.txt"
    git -C "${BASE}" init -q
    base_commit "base v1"
    printf '%s\n' "# exceptions only" > "${AGENT}/.synced-paths.txt"
}

recorded_sha() { sed -n 's/^# synced from base: \([0-9a-f]\{40\}\)$/\1/p' "${AGENT}/.synced-paths.txt"; }

setup_git
sync
check "git の base からの最初の取り込みは通る" [ $? -eq 0 ]
check "最初の取り込みは記録が無いと言う" grep -qF "has no record of the last sync" "${T}/out"
check "取り込んだ base の版を記録する" [ "$(recorded_sha)" = "$(git -C "${BASE}" rev-parse HEAD)" ]
check "記録の行は 1 本だけ" [ "$(grep -c '^# synced from base: ' "${AGENT}/.synced-paths.txt")" -eq 1 ]
check "folder の path も写す" [ "$(cat "${AGENT}/.claude/skills/demo/SKILL.md" 2>/dev/null)" = "demo v1" ]
check "commit の案内は写した path の一覧を渡す" grep -qF "git add -A --pathspec-from-file=.git/sync-from-base.pathspec" "${T}/out"
check "写した path の一覧に記録と写した path が並ぶ" [ "$(head -2 "${AGENT}/.git/sync-from-base.pathspec" 2>/dev/null | tr '\n' ' ')" = ".synced-paths.txt .tooling/startup/status.sh " ]

# base だけが変えた: 止まらず、 記録が進む
echo "status v3" > "${BASE}/src/.tooling/startup/status.sh"
base_commit "base v3"
sync
check "base だけが変えた時は通る" [ $? -eq 0 ]
check "base の新しい版が降りる" [ "$(cat "${AGENT}/.tooling/startup/status.sh")" = "status v3" ]
check "記録が今の base の版へ進む" [ "$(recorded_sha)" = "$(git -C "${BASE}" rev-parse HEAD)" ]
check "記録の行は進めても 1 本だけ" [ "$(grep -c '^# synced from base: ' "${AGENT}/.synced-paths.txt")" -eq 1 ]

# 派生だけが変えた: 名指して何も写さずに止まる
setup_git
sync
echo "helper changed in the agent" > "${AGENT}/.tooling/lib/helper.sh"
echo "status v4" > "${BASE}/src/.tooling/startup/status.sh"
base_commit "base v4"
before="$(recorded_sha)"
sync
check "派生だけが変えた file があると止まる" [ $? -ne 0 ]
check "派生だけが変えた file を名指す" grep -qE "changed here +\.tooling/lib/helper\.sh" "${T}/out"
check "止まった時は base の新しい版も写さない" [ "$(cat "${AGENT}/.tooling/startup/status.sh")" = "status v2" ]
check "止まった時は派生の直しを残す" [ "$(cat "${AGENT}/.tooling/lib/helper.sh")" = "helper changed in the agent" ]
check "止まった時は記録を進めない" [ "$(recorded_sha)" = "${before}" ]

# SYNC_OVERWRITE=1 は名指した上で上書きする
SYNC_OVERWRITE=1 BASE_REPO_PATH="${BASE}" bash "${AGENT}/.tooling/distribute/sync-from-base.sh" > "${T}/out" 2>&1
check "SYNC_OVERWRITE=1 は通る" [ $? -eq 0 ]
check "SYNC_OVERWRITE=1 も上書きする file を名指す" grep -qE "changed here +\.tooling/lib/helper\.sh" "${T}/out"
check "SYNC_OVERWRITE=1 は base の版で上書きする" [ "$(cat "${AGENT}/.tooling/lib/helper.sh")" = "helper v2" ]

# 両方が変えた
setup_git
sync
echo "helper changed in the agent" > "${AGENT}/.tooling/lib/helper.sh"
echo "helper v5" > "${BASE}/src/.tooling/lib/helper.sh"
base_commit "base v5"
sync
check "両方が変えた file があると止まる" [ $? -ne 0 ]
check "両方が変えた file を名指す" grep -qE "changed here and in the base +\.tooling/lib/helper\.sh" "${T}/out"

# folder の中に派生が足した file (= rsync --delete で消える物) と、 派生が消した file
setup_git
printf '%s\n' "*.pyc" > "${AGENT}/.gitignore"
sync
echo "agent note" > "${AGENT}/.claude/skills/demo/notes.md"
echo "ignored" > "${AGENT}/.claude/skills/demo/cache.pyc"
rm "${AGENT}/.tooling/startup/status.sh"
sync
check "派生が足した・消した file があると止まる" [ $? -ne 0 ]
check "folder の中に派生が足した file を名指す" grep -qE "added here +\.claude/skills/demo/notes\.md" "${T}/out"
check "派生が消した file を名指す" grep -qE "deleted here +\.tooling/startup/status\.sh" "${T}/out"
check "git が無視する file は名指さない" lacks "cache.pyc"

# 記録の版が base から消えた (= 履歴の書き換え): base の履歴で見分ける
drop_record() {
    grep -v '^# synced from base: ' "${AGENT}/.synced-paths.txt" > "${T}/sp"
    cat "${T}/sp" > "${AGENT}/.synced-paths.txt"
}
setup_git
sync
drop_record
echo "# synced from base: 0123456789abcdef0123456789abcdef01234567" >> "${AGENT}/.synced-paths.txt"
sync
check "記録の版が base に無くても、 派生が変えていなければ進む" [ $? -eq 0 ]
check "記録の版が base に無いと言う" grep -qF "no longer has the last synced version" "${T}/out"
check "記録を今の版で書き直す" [ "$(recorded_sha)" = "$(git -C "${BASE}" rev-parse HEAD)" ]
drop_record
echo "# synced from base: 0123456789abcdef0123456789abcdef01234567" >> "${AGENT}/.synced-paths.txt"
echo "helper changed in the agent" > "${AGENT}/.tooling/lib/helper.sh"
sync
check "記録の版が base に無い時も、 派生の直しで止まる" [ $? -ne 0 ]
check "記録の版が base に無い時も、 派生の直しを名指す" grep -qE "changed here +\.tooling/lib/helper\.sh" "${T}/out"

# --- 記録が無い (= 初めての取り込み): base の履歴に在った版かで見る -------------------------
# base の古い版を持つだけの file は上書きしてよい
setup_git
printf '%s\n' "*.pyc" > "${AGENT}/.gitignore"
sync
drop_record
echo "status v3" > "${BASE}/src/.tooling/startup/status.sh"
base_commit "base v3"
rm "${AGENT}/.tooling/lib/helper.sh"
echo "ignored" > "${AGENT}/.claude/skills/demo/cache.pyc"
sync
check "記録が無くても、 base の古い版を持つだけなら通る" [ $? -eq 0 ]
check "記録が無い時は、 履歴で見ると言う" grep -qF "has no record of the last sync" "${T}/out"
check "記録が無い時も base の新しい版が降りる" [ "$(cat "${AGENT}/.tooling/startup/status.sh")" = "status v3" ]
check "記録が無い時、 派生が消した file は写して戻す" [ "$(cat "${AGENT}/.tooling/lib/helper.sh" 2>/dev/null)" = "helper v2" ]
check "記録が無い時も、 git が無視する file は名指さない" lacks "cache.pyc"
check "記録が無い取り込みの後は記録が在る" [ "$(recorded_sha)" = "$(git -C "${BASE}" rev-parse HEAD)" ]

# base が持ったことの無い版は、 派生の直しとして止まる
setup_git
sync
drop_record
echo "helper changed in the agent" > "${AGENT}/.tooling/lib/helper.sh"
echo "agent note" > "${AGENT}/.claude/skills/demo/notes.md"
echo "status v3" > "${BASE}/src/.tooling/startup/status.sh"
base_commit "base v3"
sync
check "記録が無い時、 base に無かった版を持つ file で止まる" [ $? -ne 0 ]
check "記録が無い時、 base に無かった版を言う" grep -qF "a version the base never had" "${T}/out"
check "記録が無い時、 派生が変えた file を名指す" grep -qE "changed here +\.tooling/lib/helper\.sh" "${T}/out"
check "記録が無い時、 folder に派生が足した file を名指す" grep -qE "added here +\.claude/skills/demo/notes\.md" "${T}/out"
check "記録が無い時も、 止まったら何も写さない" [ "$(cat "${AGENT}/.tooling/startup/status.sh")" = "status v2" ]

# base に commit していない変更がある時は記録しない
setup_git
sync
before="$(recorded_sha)"
echo "status uncommitted" > "${BASE}/src/.tooling/startup/status.sh"
sync
check "base に commit していない変更があっても写す" [ "$(cat "${AGENT}/.tooling/startup/status.sh")" = "status uncommitted" ]
check "base に commit していない変更がある時は記録を進めない" [ "$(recorded_sha)" = "${before}" ]

# --- 最後の docs-check -------------------------------------------------------------
setup
printf '%s\n' "# exceptions only" > "${AGENT}/.synced-paths.txt"
mkdir -p "${AGENT}/.tooling/docs-check"
printf '%s\n' 'printf "\033[31m  FAIL: layout: demo is not declared\033[0m\n"' 'echo "FAIL: 1"' 'exit 1' > "${AGENT}/.tooling/docs-check/docs-check.sh"
sync
check "docs-check が赤なら exit 1" [ $? -ne 0 ]
check "docs-check の FAIL の行を色なしで出す" grep -qxF "  FAIL: layout: demo is not declared" "${T}/out"
check "docs-check が赤なら commit の案内を出さない" lacks "git add -A"
check "docs-check が赤でも取り込みは済んでいる" [ "$(cat "${AGENT}/.tooling/startup/status.sh" 2>/dev/null)" = "status v2" ]

printf '%s\n' 'exit 0' > "${AGENT}/.tooling/docs-check/docs-check.sh"
sync
check "docs-check が緑なら通る" [ $? -eq 0 ]
check "docs-check が緑なら commit の案内を出す" grep -qF "git add -A --pathspec-from-file=" "${T}/out"

echo "test-sync-from-base: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
