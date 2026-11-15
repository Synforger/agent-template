#!/bin/bash
# test-commit-paths-guard.sh - hooks/commit_paths_guard.py が、 エージェントの checkout で path を `--` で名指さない
# `git commit` だけを止めるか。 作り物の repo をエージェントの folder (= AGENT_ROOT) にして確かめる。
#
#   bash .tooling/tests/test-commit-paths-guard.sh
set -u
HOOK="$(cd "$(dirname "$0")/../hooks" && pwd)/commit_paths_guard.py"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
T="$(cd -P "${T}" && pwd)"
pass=0; fail=0
check() { # <説明> <コマンド...>
    local what="$1"
    shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}

# 作り物の repo: agent はエージェントの folder、 other は別の repo、 agent/tier は agent の下で自分の .git を持つ階層
for r in agent other agent/tier; do
    mkdir -p "${T}/${r}"
    git -C "${T}/${r}" init -q
done
mkdir -p "${T}/agent/sub" "${T}/elsewhere"

run() { # <作業の folder> <命令> [道具]
    local tool="${3:-Bash}"
    python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":sys.argv[1],"tool_input":{"command":sys.argv[2]},"cwd":sys.argv[3]}))' \
        "${tool}" "$2" "$1" | AGENT_ROOT="${T}/agent" python3 "${HOOK}"
}
denied() { run "$@" | grep -q '"permissionDecision": "deny"'; }
passed() { [ -z "$(run "$@")" ]; }

check "path を名指さない commit を止める" denied "${T}/agent" "git commit -m msg"
check "下の folder からの commit も止める" denied "${T}/agent/sub" "git commit -m msg"
check "add の後に続けた commit を止める" denied "${T}/agent" "git add a.md && git commit -m msg"
check "複数行の message の commit を止める" denied "${T}/agent" "git add a.md && git commit -q -m \"head

Co-Authored-By: x\""
check "-C で agent を指す commit を止める" denied "${T}/elsewhere" "git -C ${T}/agent commit -m msg"
check "前の段の cd の先の commit を止める" denied "${T}/elsewhere" "cd ${T}/agent; git commit -m msg"
check "-- の後に path が無い commit を止める" denied "${T}/agent" "git commit -m msg --"
check "-a を使う commit を止める" denied "${T}/agent" "git commit -a -m msg -- a.md"
check "-qa の束の -a も止める" denied "${T}/agent" "git commit -qa -m msg -- a.md"
check "--all を使う commit を止める" denied "${T}/agent" "git commit --all -m msg -- a.md"
check "--amend でも path が無ければ止める" denied "${T}/agent" "git commit --amend --no-edit"
check "止める理由に path を名指す形を書く" bash -c "$(declare -f run); T='${T}'; HOOK='${HOOK}'; run '${T}/agent' 'git commit -m msg' | grep -q -- '-- <自分が書いた path>'"

check "-- で path を名指す commit は通す" passed "${T}/agent" "git add -A -- a.md && git commit -m msg -- a.md"
check "複数行の message でも -- で名指せば通す" passed "${T}/agent" "git commit -q -m \"head

Co-Authored-By: x\" -- a.md b/"
check "-m の値の a は -a と読まない" passed "${T}/agent" "git commit -ma -- a.md"
check "別の repo の commit は通す" passed "${T}/other" "git commit -m msg"
check "agent の下で自分の .git を持つ階層は通す" passed "${T}/agent/tier" "git commit -m msg"
check "git の外は通す" passed "${T}/elsewhere" "git commit -m msg"
check "commit 以外の git は通す" passed "${T}/agent" "git log --oneline -1 && git status"
check "文字として git commit を含むだけの命令は通す" passed "${T}/agent" "grep -n 'git commit' notes.md"
check "閉じない引用符の命令は通す" passed "${T}/agent" "git commit -m \"msg"
check "Bash 以外の道具は通す" passed "${T}/agent" "git commit -m msg" Read

echo "test-commit-paths-guard: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
