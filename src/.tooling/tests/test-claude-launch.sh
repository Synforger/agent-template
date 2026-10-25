#!/bin/bash
# .tooling/lib/claude-launch.py の test。 作り物の HOME とエージェントの folder (= 入口と本体の写しを置く) で、 発話から決まる階層・口座と、
# claude (= 身代わり) に渡る引数と環境変数を確かめる。
#
#   bash .tooling/tests/test-claude-launch.sh
set -uo pipefail

TOOLING="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
T="$(cd -P "${T}" && pwd)"
pass=0
fail=0
# 本体は作り物のエージェントの folder に写して呼ぶ (= 根は起動の file の置き場で決まる)。 入口 (= agent ごとに旗を
# 足してよい shell) は最後に 1 件だけ、 渡した引数が claude まで届く事を見る
LAUNCH="${T}/agent/.tooling/lib/claude-launch.py"
ENTRY="${T}/agent/.tooling/claude-launch.sh"

check() { # <説明> <コマンド...>
    local what="$1"
    shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}
has() { grep -qxF -- "$2" "$1"; }
lacks() { ! grep -qxF -- "$2" "$1"; }

setup() {
    rm -rf "${T}/home" "${T}/agent" "${T}/out"
    mkdir -p "${T}/home/.claude" "${T}/agent/projects/_template-project" "${T}/agent/projects/Client" \
        "${T}/agent/projects/ClientApp/subprojects/viewer" "${T}/agent/projects/家計/subprojects/_x" "${T}/out"
    printf '{"fastMode": true, "theme": "dark"}\n' > "${T}/home/.claude/settings.json"
    mkdir -p "${T}/agent/.tooling/lib"
    cp "${TOOLING}/claude-launch.sh" "${T}/agent/.tooling/"
    cp "${TOOLING}/lib/claude-launch.py" "${T}/agent/.tooling/lib/"
    # claude の身代わり: 引数を 1 行ずつ、 環境変数を別 file に記録する。
    cat > "${T}/claude" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "${OUT}/args"
printf 'AGENT_ROOT=%s\n' "${AGENT_ROOT-unset}" > "${OUT}/root"
printf 'AGENT_TIER=%s\nCLAUDE_CONFIG_DIR=%s\nGUARD_WORK_FOLDER=%s\nPWA_NOTE=%s\nAGENT_CHILD=%s\n' "${AGENT_TIER-unset}" \
    "${CLAUDE_CONFIG_DIR-unset}" "${GUARD_WORK_FOLDER-unset}" "${PWA_NOTE-unset}" "${AGENT_CHILD-unset}" > "${OUT}/env"
printf 'VIRTUAL_ENV=%s\nUV_PROJECT_ENVIRONMENT=%s\nPATH=%s\n' "${VIRTUAL_ENV-unset}" "${UV_PROJECT_ENVIRONMENT-unset}" "${PATH}" >> "${OUT}/env"
SH
    chmod +x "${T}/claude"
}

launch() { # 引数は launcher へ。 標準入力は端末の 1 行の代わり
    env -u CLAUDE_CONFIG_DIR -u PWA_SID -u AGENT_TIER -u GUARD_WORK_FOLDER -u AGENT_CHILD HOME="${T}/home" AGENT_ROOT="${T}/elsewhere" \
        AGENT_CLAUDE_BIN="${T}/claude" OUT="${T}/out" python3 "${LAUNCH}" "$@" 2> "${T}/out/stderr"
}

# --- 呼び手の道具の Python の環境は渡さない ---------------------------------------------

setup
printf 'Client の件で' > "${T}/msg"
VIRTUAL_ENV="${T}/tool-env" UV_PROJECT_ENVIRONMENT="${T}/tool-env" PATH="${T}/tool-env/bin:${PATH}" \
    launch --first-message-file "${T}/msg"
check "呼び手の VIRTUAL_ENV を渡さない" has "${T}/out/env" "VIRTUAL_ENV=unset"
check "呼び手の UV_PROJECT_ENVIRONMENT を渡さない" has "${T}/out/env" "UV_PROJECT_ENVIRONMENT=unset"
check "PATH から呼び手の環境の bin を外す" bash -c "! grep -q '${T}/tool-env/bin' '${T}/out/env'"

# --- 最初の発話から階層 ---------------------------------------------------------------

setup
printf 'Client の件で\n2 行目も渡る\n' > "${T}/msg"
launch --first-message-file "${T}/msg"
check "プロジェクト名で階層が決まる" has "${T}/out/env" "AGENT_TIER=projects/Client"
check "既定の口座では CLAUDE_CONFIG_DIR を書かない" has "${T}/out/env" "CLAUDE_CONFIG_DIR=unset"
check "受け継いだ AGENT_ROOT ではなく、 起動の file の置き場を根にする" has "${T}/out/env" "GUARD_WORK_FOLDER=${T}/agent/projects/Client"
check "決めたエージェントの folder を AGENT_ROOT で session に渡す" has "${T}/out/root" "AGENT_ROOT=${T}/agent"
check "model と effort を固定する" has "${T}/out/args" "opus"
check "発話は複数行のまま最後の引数" [ "$(tail -2 "${T}/out/args")" = "$(printf 'Client の件で\n2 行目も渡る')" ]
check "発話の file は読んだら消す" [ ! -e "${T}/msg" ]

setup
printf 'clientapp の viewer を見て' > "${T}/msg"
launch --first-message-file "${T}/msg"
check "長い名前を採り、 大文字小文字を問わない" has "${T}/out/env" "AGENT_TIER=projects/ClientApp/subprojects/viewer"
check "番人へ階層の folder を渡す" has "${T}/out/env" "GUARD_WORK_FOLDER=${T}/agent/projects/ClientApp/subprojects/viewer"

setup
mkdir -p "${T}/agent/projects/ClientApp/.claude/skills" "${T}/agent/projects/ClientApp/subprojects/viewer/.claude/skills"
printf 'clientapp の viewer を見て' > "${T}/msg"
launch --first-message-file "${T}/msg"
check "skill を持つ親プロの folder を追加の作業 folder に渡す" has "${T}/out/args" "${T}/agent/projects/ClientApp"
check "skill を持つサブプロの folder も渡す" has "${T}/out/args" "${T}/agent/projects/ClientApp/subprojects/viewer"
check "--add-dir は --model より前 (= 後ろの発話を folder として吸わない)" \
    [ "$(grep -nxF -- --add-dir "${T}/out/args" | tail -1 | cut -d: -f1)" -lt "$(grep -nxF -- --model "${T}/out/args" | cut -d: -f1)" ]

setup
printf 'Client の件で' > "${T}/msg"
launch --first-message-file "${T}/msg"
check "skill を持たない階層には --add-dir を付けない" lacks "${T}/out/args" "--add-dir"

setup
mkdir -p "${T}/agent/projects/AP/subprojects/番人"
printf 'AP・番人' > "${T}/msg"
launch --first-message-file "${T}/msg"
check "英字だけの名前は、 前後が英字でない所で当たる" has "${T}/out/env" "AGENT_TIER=projects/AP/subprojects/番人"

setup
mkdir -p "${T}/agent/projects/AP/subprojects/番人"
printf 'API の番人と app の話' > "${T}/msg"
launch --first-message-file "${T}/msg"
check "英字だけの名前は、 長い英字の単語の中では当たらない" has "${T}/out/env" "AGENT_TIER=normal"

setup
printf 'viewer は後で。 ClientApp の話' > "${T}/msg"
launch --first-message-file "${T}/msg"
check "サブプロは親プロの名前より後ろだけで探す" has "${T}/out/env" "AGENT_TIER=projects/ClientApp"

setup
printf '家計の _x と _template-project' > "${T}/msg"
launch --first-message-file "${T}/msg"
check "_ 始まりはサブプロにならない" has "${T}/out/env" "AGENT_TIER=projects/家計"

setup
mkdir -p "${T}/agent/projects/ミカン/subprojects/はたけ"
printf 'みかんの ハタケ を見て' > "${T}/msg"
launch --first-message-file "${T}/msg"
check "ひらがなとカタカナを問わない (= 親プロもサブプロも)" has "${T}/out/env" "AGENT_TIER=projects/ミカン/subprojects/はたけ"

setup
printf 'おはよう' > "${T}/msg"
launch --first-message-file "${T}/msg"
check "名前が無ければ normal" has "${T}/out/env" "AGENT_TIER=normal"
check "normal はエージェントの直下を番人へ渡す" has "${T}/out/env" "GUARD_WORK_FOLDER=${T}/agent"

setup
echo "Client について" | launch
check "端末の 1 行でも受け取る" has "${T}/out/env" "AGENT_TIER=projects/Client"
check "端末の 1 行が発話になる" [ "$(tail -1 "${T}/out/args")" = "Client について" ]

setup
launch < /dev/null
check "空の発話は normal で、 発話を渡さない" [ "$(tail -1 "${T}/out/args")" = "high" ]

setup
mkdir -p "${T}/home/.claude-work"
printf 'Client' > "${T}/msg"
env -u PWA_SID CLAUDE_CONFIG_DIR="${T}/home/.claude-work" HOME="${T}/home" AGENT_ROOT="${T}/elsewhere" \
    AGENT_CLAUDE_BIN="${T}/claude" OUT="${T}/out" python3 "${LAUNCH}" --first-message-file "${T}/msg" 2> /dev/null
check "CLAUDE_CONFIG_DIR の口座のまま起動する (= PWA のアカウント)" has "${T}/out/env" "CLAUDE_CONFIG_DIR=${T}/home/.claude-work"

# --- タブのメモ (= PWA の 📋) は階層の folder に置く ------------------------------------------

note_launch() { # <PWA_NOTE> 引数は launcher へ
    local handed="$1"
    shift
    env -u CLAUDE_CONFIG_DIR -u AGENT_TIER -u GUARD_WORK_FOLDER PWA_SID=ses_x PWA_NOTE="${handed}" \
        HOME="${T}/home" AGENT_ROOT="${T}/elsewhere" AGENT_CLAUDE_BIN="${T}/claude" OUT="${T}/out" \
        python3 "${LAUNCH}" "$@" 2> /dev/null
}

setup
ROOT_NOTE="${T}/agent/pages/ses_x/memo.md"
TIER_NOTE="${T}/agent/projects/Client/pages/ses_x/memo.md"
mkdir -p "${T}/agent/pages/ses_x"
printf 'Client' > "${T}/msg"
printf '子のメモ\n' > "${ROOT_NOTE}"
note_launch "${ROOT_NOTE}" --first-message-file "${T}/msg"
check "渡された置き場のメモを階層の pages へ連れて行く" [ "$(cat "${TIER_NOTE}")" = "子のメモ" ]
check "連れて行った後、 渡された置き場は残さない" [ ! -e "${ROOT_NOTE}" ]
check "階層の置き場は普通の file" bash -c "[ -f '${TIER_NOTE}' ] && [ ! -L '${TIER_NOTE}' ]"
check "エージェントには階層の置き場を渡す" has "${T}/out/env" "PWA_NOTE=${TIER_NOTE}"

setup
printf 'Client' > "${T}/msg"
note_launch "${T}/agent/pages/ses_x/memo.md" --first-message-file "${T}/msg"
check "渡された置き場に file が無ければ、 階層の側に空の file を置く" bash -c "[ -f '${TIER_NOTE}' ] && [ ! -s '${TIER_NOTE}' ]"

setup
mkdir -p "${T}/agent/pages/ses_x" "$(dirname "${TIER_NOTE}")"
printf '新しい方\n' > "${ROOT_NOTE}"
printf '階層のメモ\n' > "${TIER_NOTE}"
printf 'Client' > "${T}/msg"
note_launch "${ROOT_NOTE}" --first-message-file "${T}/msg"
check "階層の側に既にメモが在れば上書きしない" [ "$(cat "${TIER_NOTE}")" = "階層のメモ" ]

setup
printf 'normal' > "${T}/msg"
note_launch "${ROOT_NOTE}" --first-message-file "${T}/msg"
check "normal は渡された置き場がそのまま正しい" has "${T}/out/env" "PWA_NOTE=${ROOT_NOTE}"
check "normal の置き場に file を置く" [ -f "${ROOT_NOTE}" ]

setup
mkdir -p "${T}/home/.claude/projects/-agent"
printf '%s\n' '{"type":"user","message":{"content":"Client"}}' > "${T}/home/.claude/projects/-agent/note-1.jsonl"
note_launch "${ROOT_NOTE}" --resume note-1
check "再開でも最初の発話の階層の置き場を渡す" has "${T}/out/env" "PWA_NOTE=${TIER_NOTE}"

# --- 自動の入れ替えで起動し直された時 -----------------------------------------------------

# 封筒の 1 行目は "client" を含む (= 作り物のエージェントには Client という階層が在る)
ROLLED='Automatic session rollover, sent by the client (the operator did not type this):'

setup
printf '%s\n<session-rollover phase="start">\ntier=projects/ClientApp/subprojects/viewer\nmode=continue\n</session-rollover>' "${ROLLED}" > "${T}/msg"
launch --first-message-file "${T}/msg"
check "引き継いだ階層で起動する" has "${T}/out/env" "AGENT_TIER=projects/ClientApp/subprojects/viewer"
check "封筒ごと最初の発話として渡る" [ "$(tail -1 "${T}/out/args")" = "</session-rollover>" ]

setup
printf '%s\n<session-rollover phase="start">\ntier=normal\nmode=wait\n</session-rollover>' "${ROLLED}" > "${T}/msg"
launch --first-message-file "${T}/msg"
check "引き継いだ階層が normal なら、 発話に階層の名前が在っても normal" has "${T}/out/env" "AGENT_TIER=normal"

setup
printf '%s\n<session-rollover phase="start">\ntier=projects/Nowhere\nmode=wait\n</session-rollover>' "${ROLLED}" > "${T}/msg"
launch --first-message-file "${T}/msg"
check "引き継いだ階層が無ければ発話から決め直す" has "${T}/out/env" "AGENT_TIER=projects/Client"
check "決め直したことを 1 行で言う" grep -q "引き継いだ階層が見つかりません" "${T}/out/stderr"

setup
printf '%s\n<session-rollover phase="start">\ntier=projects/_template-project\n</session-rollover>' "${ROLLED}" > "${T}/msg"
launch --first-message-file "${T}/msg"
check "_ 始まりの folder は引き継ぐ階層にならない" lacks "${T}/out/env" "AGENT_TIER=projects/_template-project"

# --- client が階層ごとに立てたタブ -----------------------------------------------------

# 封筒の 1 行目は "client" を含む (= 発話の名前で当てると Client の階層を採る)
OPENED='Tab opened by the client for its tier (the operator did not type this):'

setup
printf '%s\n<tab-open>\ntier=normal\n</tab-open>' "${OPENED}" > "${T}/msg"
launch --first-message-file "${T}/msg"
check "立てたタブの階層が normal なら、 1 行目に階層の名前が在っても normal" has "${T}/out/env" "AGENT_TIER=normal"

# AP は Client より短い名前 (= 発話の名前で当てると、 1 行目の client で長い Client を採って外れる)
setup
mkdir -p "${T}/agent/projects/AP/subprojects/番人"
printf '%s\n<tab-open>\ntier=projects/AP\n</tab-open>' "${OPENED}" > "${T}/msg"
launch --first-message-file "${T}/msg"
check "立てたタブはプロジェクトの階層で起動する" has "${T}/out/env" "AGENT_TIER=projects/AP"

setup
mkdir -p "${T}/agent/projects/AP/subprojects/番人"
printf '%s\n<tab-open>\ntier=projects/AP/subprojects/番人\n</tab-open>' "${OPENED}" > "${T}/msg"
launch --first-message-file "${T}/msg"
check "立てたタブはサブプロジェクトの階層で起動する" has "${T}/out/env" "AGENT_TIER=projects/AP/subprojects/番人"
check "立てたタブの封筒は最初の発話として渡る" [ "$(tail -1 "${T}/out/args")" = "</tab-open>" ]

setup
printf '%s\n<tab-open>\ntier=projects/Nowhere\n</tab-open>' "${OPENED}" > "${T}/msg"
launch --first-message-file "${T}/msg"
check "立てたタブの階層の folder が無ければ発話から決め直す" has "${T}/out/env" "AGENT_TIER=projects/Client"
check "立てたタブの決め直しを 1 行で言う" grep -q "引き継いだ階層が見つかりません" "${T}/out/stderr"

# --- fastMode の固定 ---------------------------------------------------------------

setup
printf 'Client' > "${T}/msg"
launch --first-message-file "${T}/msg"
check "口座の fastMode を戻す" [ "$(jq .fastMode "${T}/home/.claude/settings.json")" = "false" ]
check "口座の他の設定は残す" [ "$(jq -r .theme "${T}/home/.claude/settings.json")" = "dark" ]

# --- 再開 ----------------------------------------------------------------------

setup
mkdir -p "${T}/home/.claude/projects/-agent"
touch "${T}/home/.claude/projects/-agent/def-456.jsonl"
launch --resume def-456 --fork-session
check "再開の引数と残りを claude へ渡す" [ "$(tail -3 "${T}/out/args" | paste -sd' ' -)" = "--resume def-456 --fork-session" ]
check "最初の発話が読めない再開は normal" has "${T}/out/env" "AGENT_TIER=normal"
check "既定の口座の記録は CLAUDE_CONFIG_DIR を書かずに開く" has "${T}/out/env" "CLAUDE_CONFIG_DIR=unset"

setup
mkdir -p "${T}/home/.claude-work/projects/-agent"
touch "${T}/home/.claude-work/projects/-agent/abc-123.jsonl"
launch --resume abc-123
check "記録が在る口座で開く" has "${T}/out/env" "CLAUDE_CONFIG_DIR=${T}/home/.claude-work"

setup
mkdir -p "${T}/home/.claude-work/projects/-agent" "${T}/agent/projects/ClientApp/.claude/skills" \
    "${T}/agent/projects/ClientApp/subprojects/viewer/.claude/skills"
{
    printf '%s\n' '{"type":"user","isMeta":true,"message":{"content":"Client の話ではない meta"}}'
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"clientapp の viewer を見て"}]}}'
    printf '%s\n' '{"type":"user","message":{"content":"Client"}}'
} > "${T}/home/.claude-work/projects/-agent/sk-1.jsonl"
launch --resume sk-1
check "再開でも最初の発話の階層の skill の folder を渡す" has "${T}/out/args" "${T}/agent/projects/ClientApp/subprojects/viewer"
check "再開でも親プロの skill の folder を渡す" has "${T}/out/args" "${T}/agent/projects/ClientApp"
check "再開でも最初の発話の階層を渡す (= 番人の folder と同じ階層)" has "${T}/out/env" "AGENT_TIER=projects/ClientApp/subprojects/viewer"

setup
mkdir -p "${T}/home/.claude/projects/-agent" "${T}/agent/projects/ClientApp/.claude/skills"
printf '%s\n' '{"type":"user","message":{"content":"Automatic session rollover, sent by the client (the operator did not type this):\n<session-rollover phase=\"start\">\ntier=projects/ClientApp\nmode=continue\n</session-rollover>"}}' \
    > "${T}/home/.claude/projects/-agent/rolled-1.jsonl"
launch --resume rolled-1
check "入れ替えで始まった会話の再開は、 封筒の階層の skill の folder を渡す" has "${T}/out/args" "${T}/agent/projects/ClientApp"

setup
launch --resume nowhere
check "記録がどこにも無ければ、 起動の口座のまま claude に任せる" [ "$(tail -2 "${T}/out/args" | paste -sd' ' -)" = "--resume nowhere" ]

setup
launch --resume
check "--resume に値が無ければ拒む" [ $? -ne 0 ]

# --- 起動の前のエージェントの pull ----------------------------------------------------------

# tgit — 作り物の HOME で git を走らせる (= この機械の git 設定と、 そこに登録された番人の hook を読まない。
# launch も同じ HOME で走るので、 起動 script の pull も同じ条件になる)
tgit() { HOME="${T}/home" git -c user.name=t -c user.email=t@example.invalid "$@"; }

# pull_setup — 作り物のエージェントを git repo にし、 origin に 1 commit 先行させる。
pull_setup() {
    setup
    rm -rf "${T}/origin.git" "${T}/other"
    tgit init -q --bare "${T}/origin.git"
    tgit -C "${T}/agent" init -q
    tgit -C "${T}/agent" commit -q --allow-empty -m first
    tgit -C "${T}/agent" remote add origin "${T}/origin.git"
    tgit -C "${T}/agent" push -q -u origin HEAD:master
    tgit clone -q "${T}/origin.git" "${T}/other"
    tgit -C "${T}/other" commit -q --allow-empty -m "from the other machine"
    tgit -C "${T}/other" push -q origin HEAD:master
}

pull_setup
printf 'おはよう' > "${T}/msg"
launch --first-message-file "${T}/msg"
check "新しい起動はエージェントを pull する" [ "$(tgit -C "${T}/agent" log -1 --format=%s)" = "from the other machine" ]

pull_setup
mkdir -p "${T}/home/.claude/projects/-agent"
touch "${T}/home/.claude/projects/-agent/pull-1.jsonl"
launch --resume pull-1
check "再開もエージェントを pull する" [ "$(tgit -C "${T}/agent" log -1 --format=%s)" = "from the other machine" ]

pull_setup
printf 'x' > "${T}/msg"
launch --child --first-message-file "${T}/msg"
check "子のタブはエージェントを pull しない (= 親が同じ clone で作業している)" [ "$(tgit -C "${T}/agent" log -1 --format=%s)" = "first" ]

setup
printf 'おはよう' > "${T}/msg"
launch --first-message-file "${T}/msg"
check "エージェントが pull できなくても起動は続く" [ -e "${T}/out/args" ]
check "pull が止まったら 1 行で言う" grep -q "agent の pull が止まりました" "${T}/out/stderr"

# --- 子のタブ ----------------------------------------------------------------------

RELAYED='Message from another session, relayed by the client (the operator did not type this):'
setup
printf '%s\n<agent-message from="parent" session="ses_p">\n<child-start>\ntier=normal\n</child-start>\n\nClient の資料を直して\n</agent-message>' "${RELAYED}" > "${T}/msg"
launch --child --first-message-file "${T}/msg"
check "子のタブは <child-start> の階層で起動する (= 本文の名前では決めない)" has "${T}/out/env" "AGENT_TIER=normal"
check "子のタブは AGENT_CHILD=1 を session に渡す" has "${T}/out/env" "AGENT_CHILD=1"
check "--child は claude へ渡らない" lacks "${T}/out/args" "--child"
check "子の最初の発話は封筒ごと渡る" [ "$(tail -1 "${T}/out/args")" = "</agent-message>" ]
check "子のタブは CHILD_MODEL (= sonnet) で起動する" [ "$(grep -A1 -xF -- --model "${T}/out/args" | tail -1)" = "sonnet" ]

setup
printf '%s\n<session-rollover phase="start">\ntier=projects/Client\nmode=continue\n</session-rollover>' "${ROLLED}" > "${T}/msg"
launch --child --first-message-file "${T}/msg"
check "入れ替えで起動し直した子も子のまま、 封筒の階層で起動する" \
    bash -c "grep -qxF 'AGENT_CHILD=1' '${T}/out/env' && grep -qxF 'AGENT_TIER=projects/Client' '${T}/out/env'"

setup
printf 'おはよう' > "${T}/msg"
env -u CLAUDE_CONFIG_DIR -u PWA_SID -u AGENT_TIER -u GUARD_WORK_FOLDER AGENT_CHILD=1 HOME="${T}/home" AGENT_ROOT="${T}/elsewhere" \
    AGENT_CLAUDE_BIN="${T}/claude" OUT="${T}/out" python3 "${LAUNCH}" --first-message-file "${T}/msg" 2> "${T}/out/stderr"
check "--child の無い起動は、 受け継いだ子の印を session に渡さない" has "${T}/out/env" "AGENT_CHILD=unset"
check "子でない起動は MODEL (= opus) のまま" [ "$(grep -A1 -xF -- --model "${T}/out/args" | tail -1)" = "opus" ]

# --- 入口 ------------------------------------------------------------------------

setup
mkdir -p "${T}/home/.claude/projects/-agent"
touch "${T}/home/.claude/projects/-agent/entry-1.jsonl"
env -u CLAUDE_CONFIG_DIR -u PWA_SID -u AGENT_TIER -u GUARD_WORK_FOLDER -u AGENT_CHILD HOME="${T}/home" \
    AGENT_CLAUDE_BIN="${T}/claude" OUT="${T}/out" bash "${ENTRY}" --resume entry-1 --fork-session < /dev/null 2> /dev/null
check "入口は渡した引数を本体へ渡し、 claude まで届く" \
    bash -c "grep -qxF -- --resume '${T}/out/args' && grep -qxF entry-1 '${T}/out/args' && grep -qxF -- --fork-session '${T}/out/args'"

echo "claude-launch: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
