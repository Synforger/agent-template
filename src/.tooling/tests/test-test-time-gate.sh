#!/bin/bash
# test-test-time-gate.sh - hooks/test_time_gate.py と work/test-time.py が、 試験がいつもの時間を越えた時だけ鳴り、
# 縮めるか受け入れるまで閉じる手を止めるか。 作り物の HOME・状態の置き場・repo と、 差し替えた時計 (TEST_TIME_NOW) で確かめる。
#
#   bash .tooling/tests/test-test-time-gate.sh
set -u
TOOLING="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${TOOLING}/hooks/test_time_gate.py"
ACCEPT="${TOOLING}/work/test-time.py"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
T="$(cd -P "${T}" && pwd)"
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
export HOME="${T}/home"
export AGENT_PLATFORM_ROOT="${T}/root"
mkdir -p "${HOME}"
STATE="${AGENT_PLATFORM_ROOT}/state/test-times"
REPO="${T}/repo"
git init -q "${REPO}"
mkdir -p "${REPO}/sub" "${T}/plain"
pass=0; fail=0
check() { # <説明> <コマンド...>
    local what="$1"
    shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}

# hook を 1 回呼ぶ: <event> <session> <tool-use-id> <命令> <時刻> [background 1|0] [出力] [cwd] [会話の記録]
hook() {
    python3 -c 'import json,sys
e,s,i,c,_,bg,out,cwd,tp=sys.argv[1:10]
print(json.dumps({"hook_event_name":e,"session_id":s,"tool_use_id":i,"tool_name":"Bash","cwd":cwd,"transcript_path":tp,
  "tool_input":{"command":c,"run_in_background":bg=="1"},"tool_response":{"stdout":out,"stderr":""}}))' \
        "$1" "$2" "$3" "$4" "$5" "${6:-0}" "${7:-}" "${8:-${REPO}}" "${9:-}" | TEST_TIME_NOW="$5" python3 "${HOOK}"
}
# 試験を 1 回流した事にする: <session> <id> <命令> <始まり> <終わり> [出力]。 標準出力は終わりの hook の出力
ran() {
    hook PreToolUse "$1" "$2" "$3" "$4" > /dev/null
    hook PostToolUse "$1" "$2" "$3" "$5" 0 "${6:-}"
}
# 会話の記録に background の終わりの知らせの行 (queue-operation / enqueue) を足す: <記録> <tool-use-id> <時刻> <状態> <output-file>
enqueue() {
    python3 -c 'import json,sys
from datetime import datetime, timezone
f,i,t,st,o=sys.argv[1:6]
at=datetime.fromtimestamp(float(t),timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
content="<task-notification>\n<task-id>b1</task-id>\n<tool-use-id>"+i+"</tool-use-id>\n<output-file>"+o+"</output-file>\n<status>"+st+"</status>\n</task-notification>"
open(f,"a").write(json.dumps({"type":"queue-operation","operation":"enqueue","timestamp":at,"sessionId":"x","content":content})+"\n")' "$1" "$2" "$3" "$4" "$5"
}
denied() { grep -q '"permissionDecision": "deny"'; }
silent() { [ -z "$(cat)" ]; }
mentions() { grep -q -- "$1"; }
base_value() { python3 -c 'import json,sys; print(list(json.load(open(sys.argv[1])).values())[0])' "${STATE}/baselines.json"; }
running_count() { find "${STATE}/running" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
reset() { rm -rf "${STATE}"; }
CLOSING=("git commit -m x" "git -C ${REPO} commit -m x" "gh pr create --title t" "gh pr merge 5 --squash" "bash .tooling/work/pr-land.sh 5"
    "tabs report done f.md" "tabs ticket close t-1" "tabs ticket pass t-1 other" "tabs rollover continue" "cd sub && git commit -m x")
OPEN=("git status" "git diff" "cat README.md" "git log -1" "tabs ticket show t-1" "gh pr view 5" "pytest -q tests")

# --- 試験の命令の見分け -------------------------------------------------------------------------------
for command in "pytest -q" "python -m pytest" "uv run pytest tests" "task test" "task test:unit" "task ci" "npm test" "pnpm test" \
    "yarn test" "vitest run" "npx vitest" "bats tests" "go test ./..." "cargo test" "cd sub && pytest" "task -d sub test" \
    "FOO=1 pytest -q | tail -5" "git -C ${REPO} status; pytest"; do
    reset
    hook PreToolUse sA id1 "${command}" 1000 > /dev/null
    check "試験として始まりを記録する: ${command}" [ "$(running_count)" = 1 ]
done
for command in "pip install pytest" "echo pytest" "npm run build" "grep -n 'go test' Makefile" "task lint" "ls" "git commit -m 'pytest fix'"; do
    reset
    hook PreToolUse sA id1 "${command}" 1000 > /dev/null
    check "試験でない命令は記録しない: ${command}" [ "$(running_count)" = 0 ]
done
reset
hook PreToolUse sA id1 "pytest" 1000 0 "" "${T}/plain" > /dev/null
check "git の外は記録しない" [ "$(running_count)" = 0 ]

# --- 命令の読み方: 引用・heredoc・注釈の中は命令でなく、 包みの命令 (= direnv exec・env など) の中は命令 ----------------
NOT_A_TEST=('gh issue comment 1 --body "checks pass; task ci runs in Actions.; done"'
    $'echo "checks pass\npytest -q\ndone"'
    $'cat > note.md <<\'X\'\nit\'s a note\npytest -q\ngit commit -m x\nX'
    'ls # then; pytest -q')
for command in "${NOT_A_TEST[@]}"; do
    reset
    hook PreToolUse sA id1 "${command}" 1000 > /dev/null
    check "文の中の試験の名前は記録しない: ${command}" [ "$(running_count)" = 0 ]
done
for command in "direnv exec ${REPO} pytest -q" "env -u PWA_SID pytest -q" "timeout 60 pytest -q" "pytest -q 2>&1 | tail -1"; do
    reset
    hook PreToolUse sA id1 "${command}" 1000 > /dev/null
    check "包みの中の試験は記録する: ${command}" [ "$(running_count)" = 1 ]
done
REAL_CLOSING=('git commit -m "a; b" -- f'
    $'git commit -q -m "subject\n\nbody; with | marks\n\nCo-Authored-By: x" -- f'
    $'git diff --stat && git commit -q -m "subject\n\nbody" -- f'
    'direnv exec /tools gh pr create --title t'
    $'direnv exec /tools gh pr create --title t --body "$(cat <<\'X\'\nit is a body; with marks\nX\n)" 2>&1 | tail -1'
    'direnv exec /tools /agent/.tooling/work/pr-land.sh 5 --squash > land.log 2>&1'
    'env -u GH_TOKEN gh pr merge 5 --squash')
REAL_CLOSING+=($'gh pr create --body "$(cat <<\'X\'\nit\'s a "body; with an odd quote\nX\n)"')
NOT_CLOSING=($'echo "steps\ngit commit -m x\ndone"'
    $'cat > note.md <<\'X\'\ngit commit -m x\ntabs report done f.md\nX'
    'ls # then; git commit -m x')
reset
ran sA r1 "pytest -q" 1000 1002 > /dev/null
ran sA r2 "pytest -q" 2000 2030 > /dev/null
for command in "${REAL_CLOSING[@]}"; do
    out="$(hook PreToolUse sA c1 "${command}" 2100)"
    check "実際の形の閉じる手を止める: ${command}" denied <<< "${out}"
done
for command in "${NOT_CLOSING[@]}"; do
    out="$(hook PreToolUse sA c2 "${command}" 2100)"
    check "文の中の閉じる手は止めない: ${command}" silent <<< "${out}"
done

# --- folder を変数で渡す形 (= `W=<worktree>; cd "$W" && pytest`) も、 その folder の試験として数える ---------------------
for command in "W=${REPO}/sub; cd \"\$W\" && pytest -q" "export W=${REPO}"$'\n'"cd \"\${W}/sub\" && pytest -q" "R=${REPO}; W=\$R/sub; task -d \"\$W\" test"; do
    reset
    hook PreToolUse sA id1 "${command}" 1000 0 "" "${T}/plain" > /dev/null
    check "変数の folder の試験を記録する: ${command}" [ "$(running_count)" = 1 ]
done

# --- vitest の報告の遅い所も読む ---------------------------------------------------------------------------------
reset
ran sA v1 "npx vitest run" 1000 1002 > /dev/null
out="$(ran sA v2 "npx vitest run" 2000 2012 "$(printf ' Test Files  3 passed\n\nslowest 2 tests\n   1430 ms  src/a.test.js > waits\n     12 ms  src/b.test.js > quick\n')")"
check "vitest の遅い所の行を文に並べる" mentions "1430 ms  src/a.test.js > waits" <<< "${out}"

# --- 基準の鍵は試験の段の folder と命令だけ (= 前後の段・cd の書き方では割れない) ---------------------------------
reset
ran sA k1 "pytest -q" 1000 1002 > /dev/null
out="$(ran sA k2 "printf x > f.txt && pytest -q 2>&1 | tail -1" 2000 2012)"
check "前後の段が違っても同じ試験の基準で鳴る" mentions "いつもの 2.0秒" <<< "${out}"
reset
ran sA k1 "cd ${REPO}/sub && pytest -q" 1000 1002 > /dev/null
out="$(ran sA k2 "pytest -q" 2000 2012 "" )"
check "別の folder で流した同じ命令は別の基準 (= 初めてなので鳴らない)" silent <<< "${out}"
out="$(hook PreToolUse sA k3 "pytest -q | tail -1" 3000 0 "" "${REPO}/sub" > /dev/null; hook PostToolUse sA k3 "pytest -q | tail -1" 3012 0 "" "${REPO}/sub")"
check "cd で入っても cwd で居ても同じ folder なら同じ基準で鳴る" mentions "sub: pytest -q" <<< "${out}"

# --- 試験の外に軽い段 (= folder の移動と出力の絞り) 以外が在る命令は測らない (= 秒は命令の全体でしか測れない) -----------
no_base() { [ ! -e "${STATE}/baselines.json" ]; }
no_ring() { [ ! -e "${STATE}/ringing/sA.json" ]; }
HEAVY=("pytest -q && git merge topic" "pytest -q && git commit -m x -- f" "pytest -q; git push" "git fetch origin && pytest -q"
    "pytest -q && gh pr view 5" "pytest -q && bash .tooling/work/pr-land.sh 5" "sleep 30; pytest -q" "task build && pytest -q"
    "pytest -q && direnv exec /tools git push" "pytest -q && env FOO=1 make all" "out=\$(sleep 30); pytest -q")
for command in "${HEAVY[@]}"; do
    reset
    ran sA h1 "${command}" 1000 1100 > /dev/null
    check "ほかの重い段が在る命令は基準を書かない: ${command}" no_base
    reset
    ran sA h2 "pytest -q" 1000 1002 > /dev/null
    out="$(ran sA h3 "${command}" 2000 2100)"
    check "ほかの重い段が在る命令は鳴らない: ${command}" silent <<< "${out}"
    check "ほかの重い段が在る命令は鳴りを残さず、 基準も動かさない: ${command}" bash -c "[ ! -e '${STATE}/ringing/sA.json' ] && grep -q ': 2.0' '${STATE}/baselines.json'"
done
LIGHT=("pytest -q 2>&1 | tail -5" "pytest -q | head -3 | grep -c passed" "cd . && pytest -q" "pytest -q > a.log; echo \$?; cat a.log | wc -l"
    "export FOO=1; BAR=2; pytest -q | tee a.log" "date; printf x; true; :; pytest -q; test -f a.log; [ -f a.log ]"
    "pytest -q 2>&1 | sed -n 1p | awk '{print}' | sort" "/usr/bin/tail -1 a.log; pytest -q")
for command in "${LIGHT[@]}"; do
    reset
    ran sA l1 "pytest -q" 1000 1002 > /dev/null
    out="$(ran sA l2 "${command}" 2000 2100)"
    check "軽い段だけが前後に在る命令は今までどおり鳴る: ${command}" mentions "いつもの 2.0秒" <<< "${out}"
done
reset
ran sA l3 "cd sub && pytest -q | tail -5" 1000 1002 > /dev/null
check "cd と絞りの付いた命令は基準を書く" [ "$(base_value)" = "2.0" ]
# 測らない命令も試験は流れているので、 別の session の試験とはぶつかる
reset
hook PreToolUse sA h4 'pytest -q && git push' 1000 > /dev/null
out="$(hook PreToolUse sB h5 'pytest -q tests' 1100)"
check "測らない命令の試験も、 別の session の試験とぶつかる" denied <<< "${out}"
# background でも測らない
reset
: > "${T}/ts-h.jsonl"
hook PreToolUse sA h6 'pytest -q && git push' 1000 1 "" "${REPO}" "${T}/ts-h.jsonl" > /dev/null
enqueue "${T}/ts-h.jsonl" h6 1100 completed "${T}/no-output"
hook PreToolUse sA h7 'ls' 1200 0 "" "${REPO}" "${T}/ts-h.jsonl" > /dev/null
check "background の測らない命令は、 終わりの記録だけ消す" [ "$(running_count)" = 0 ]
check "background の測らない命令は基準を書かない" no_base
check "background の測らない命令は鳴りを残さない" no_ring

# --- 同じ時に終わった試験の基準が、 互いを消さない (= 全 session の hook が 1 つの file を読み書きする) -----------------
reset
for i in $(seq 1 20); do ran sA "p${i}" "pytest -q tests/t${i}.py" 1000 1002 > /dev/null & done
wait
check "同時に終わった 20 本の基準が全部残る" [ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "${STATE}/baselines.json")" = 20 ]

# --- 初めて・線の内・下がる -----------------------------------------------------------------------------
reset
check "初めての試験は鳴らない" bash -c "$(declare -f ran hook silent); HOOK='${HOOK}' REPO='${REPO}'; ran sA a1 'pytest -q' 1000 1010 | silent"
check "初めての試験の時間を基準に記録する" [ "$(base_value)" = "10.0" ]
check "線の内 (基準 10 → 12 秒) は黙る" bash -c "$(declare -f ran hook silent); HOOK='${HOOK}' REPO='${REPO}'; ran sA a2 'pytest -q' 2000 2012 | silent"
check "線の内なら基準は動かさない" [ "$(base_value)" = "10.0" ]
check "短くなったら基準を下げる" bash -c "$(declare -f ran hook silent); HOOK='${HOOK}' REPO='${REPO}'; ran sA a3 'pytest -q' 3000 3008 | silent"
check "基準が 8 秒に下がる" [ "$(base_value)" = "8.0" ]
check "線ちょうど (8 → 13 秒) は鳴らない" bash -c "$(declare -f ran hook silent); HOOK='${HOOK}' REPO='${REPO}'; ran sA a4 'pytest -q' 4000 4013 | silent"

# --- わざと鳴る見本 --------------------------------------------------------------------------------------
OUT="$(ran sA a5 'pytest -q' 5000 5020)"
check "線を越えたら鳴る (いつもの秒数と今回の秒数)" bash -c "echo '${OUT}' | grep -q '8.0秒' && echo '${OUT}' | grep -q '20.0秒'"
check "名前が出力に無ければ --durations=10 を勧める" mentions '--durations=10' <<< "${OUT}"
check "縮める道と受け入れの道の 2 つを書く" bash -c "echo '${OUT}' | grep -q '縮める' && echo '${OUT}' | grep -q 'test-time.py accept'"
check "鳴りの文は受け入れの命令を、 どの folder からでも打てる path で名指す" grep -qF "python3 ${ACCEPT} accept" <<< "${OUT}"
check "止める文も受け入れの命令を、 どの folder からでも打てる path で名指す" grep -qF "python3 ${ACCEPT} accept" <<< "$(hook PreToolUse sA x1 'git commit -m x' 5100)"
check "鳴った時は基準を動かさない" [ "$(base_value)" = "8.0" ]
for command in "${CLOSING[@]}"; do
    check "鳴っている間、 閉じる手を止める: ${command}" bash -c "$(declare -f hook denied); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sA x1 '${command}' 5100 | denied"
done
for command in "${OPEN[@]}"; do
    check "鳴っている間も読む・直す・流し直す手は通す: ${command}" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sA x2 '${command}' 5100 | silent"
done
check "別の session の閉じる手は止めない" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sB x3 'git commit -m x' 5100 | silent"

# --- 直した見本 (= 流し直して線の内) で鳴りが消える ----------------------------------------------------------
hook PostToolUse sA x2 'pytest -q tests' 5110 > /dev/null
check "流し直して線の内に収まれば黙り、 閉じる手が通る" bash -c "$(declare -f ran hook silent); HOOK='${HOOK}' REPO='${REPO}'; ran sA a6 'pytest -q' 6000 6009 | silent"
check "鳴りが消えた後の commit は通る" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sA x4 'git commit -m x' 6100 | silent"
check "同じ鍵でない試験の流し直しでは消えない" bash -c "$(declare -f ran hook silent); HOOK='${HOOK}' REPO='${REPO}'; ran sA a7 'pytest -q' 7000 7020 > /dev/null; ran sA a8 'pytest -q tests/other' 7100 7101 | silent; hook PreToolUse sA x5 'git commit -m x' 7200 | grep -q deny"

# --- 遅い所の名前は上から 10 本 ---------------------------------------------------------------------------
DURATIONS="$(printf '== slowest 10 durations ==\n'; for n in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '%d.50s call     tests/x.py::test_n%d\n' $((20 - n)) "${n}"; done)"
reset
ran sA b1 'pytest -q' 1000 1010 > /dev/null
OUT="$(ran sA b2 'pytest -q' 2000 2030 "${DURATIONS}")"
check "遅い所を上から 10 本並べる" bash -c "echo '${OUT}' | grep -q 'test_n10' && ! echo '${OUT}' | grep -q 'test_n11' && echo '${OUT}' | grep -q '19.50s call'"
check "名前がある時は --durations の勧めを出さない" bash -c "! echo '${OUT}' | grep -q -e '--durations=10'"

# --- 受け入れ -------------------------------------------------------------------------------------------
accept() { CLAUDE_CODE_SESSION_ID=sA TEST_TIME_NOW=3000 python3 "${ACCEPT}" accept "$@"; }
check "--tried が空なら断る" bash -c "$(declare -f accept); ACCEPT='${ACCEPT}'; ! accept --tried '' --before 10 --after 30 2>/dev/null"
check "--tried が空白だけでも断る" bash -c "$(declare -f accept); ACCEPT='${ACCEPT}'; ! accept --tried '  ' --before 10 --after 30 2>/dev/null"
check "--before が無ければ断る" bash -c "$(declare -f accept); ACCEPT='${ACCEPT}'; ! accept --tried 並列 --after 30 2>/dev/null"
check "--after が無ければ断る" bash -c "$(declare -f accept); ACCEPT='${ACCEPT}'; ! accept --tried 並列 --before 10 2>/dev/null"
check "断った後も閉じる手は止まったまま" bash -c "$(declare -f hook denied); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sA y1 'git commit -m x' 3000 | denied"
check "受け入れの命令を打てる" bash -c "$(declare -f accept); ACCEPT='${ACCEPT}'; accept --tried '並列を試したが 1 本の時計待ちが残る' --before 10 --after 30 > /dev/null"
check "受け入れた後は閉じる手が通る" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sA y2 'git commit -m x' 3000 | silent"
check "受け入れで基準を最後の elapsed に上げる" [ "$(base_value)" = "30.0" ]
check "受け入れを accepted.jsonl に 1 行書く" bash -c "[ \$(wc -l < '${STATE}/accepted.jsonl') = 1 ] && grep -q '時計待ち' '${STATE}/accepted.jsonl' && grep -q '\"before\": 10' '${STATE}/accepted.jsonl' && grep -q '\"session\": \"sA\"' '${STATE}/accepted.jsonl'"
check "鳴っていない時の受け入れは断る" bash -c "$(declare -f accept); ACCEPT='${ACCEPT}'; ! accept --tried x --before 1 --after 2 2>/dev/null"
check "上げた基準では 31 秒が線の内" bash -c "$(declare -f ran hook silent); HOOK='${HOOK}' REPO='${REPO}'; ran sA b3 'pytest -q' 4000 4031 | silent"

# --- 1 つの命令に試験が複数在れば、 秒は束の物 (= 1 本目の基準に付けない) -------------------------------------------
reset
ran sA m1 'pytest -q a.py' 1000 1012 > /dev/null
out="$(ran sA m2 'pytest -q a.py > a.log; echo a; pytest -q b.py' 2000 2050)"
check "束の秒で 1 本目の基準を鳴らさない" silent <<< "${out}"
check "束の秒は 1 本目の基準を動かさない" [ "$(base_value)" = "12.0" ]
out="$(ran sA m3 'pytest -q a.py; pytest -q b.py' 3000 3080)"
check "束は束の基準で鳴り、 全部の試験を名指す" mentions 'pytest -q a.py; pytest -q b.py' <<< "${out}"

# --- 受け入れの基準は、 測った秒と --after の短い方 (= 別の旗で流し直しても膨らまず、 書いた値では上がらない) ---------
refused() { ! "$@" > /dev/null 2>&1; }
rung() { reset; ran sA o1 'pytest -q' 1000 1012 > /dev/null; ran sA o2 'pytest -q' 2000 2050 > /dev/null; }
rung
check "鳴りの文は --after を試した後の秒として訊く" mentions '--after <縮める手を試した後の秒>' <<< "$(ran sA o4 'pytest -q' 2100 2150)"
ran sA o3 'pytest -q --durations=10' 2200 2219.5 > /dev/null
accept --tried '旗を足して流し直した' --before 50 --after 19.5 > /dev/null
check "--after が短ければ基準は --after" [ "$(base_value)" = "19.5" ]
rung
accept --tried x --before 12 --after 900 > /dev/null
check "--after が測った秒より長くても基準は測った秒" [ "$(base_value)" = "50.0" ]
for seconds in 0 -3 nan inf; do
    rung
    check "秒でない --after は断る: ${seconds}" refused accept --tried x --before 12 "--after=${seconds}"
    check "断った時は基準を動かさない: ${seconds}" [ "$(base_value)" = "12.0" ]
done

# --- background の命令は、 会話の記録に残る知らせの行で終わりにする -------------------------------------------------
# 知らせは UserPromptSubmit を通らず、 記録の `queue-operation` の行に残る。 次に呼ばれた hook (どの session でも) が行を見つけて終わりにする
TS_A="${T}/ts-a.jsonl"; TS_B="${T}/ts-b.jsonl"
: > "${TS_A}"; : > "${TS_B}"
printf 'noise {{{ not json\n{"type":"user"}\n' >> "${TS_A}"
reset
hook PreToolUse sA bg1 'pytest -q --bg' 1000 1 "" "${REPO}" "${TS_A}" > /dev/null
check "background の始まりを会話の記録の在処つきで記録する" bash -c "grep -q 'ts-a.jsonl' '${STATE}/running/bg1.json'"
hook PostToolUse sA bg1 'pytest -q --bg' 1001 1 "" "${REPO}" "${TS_A}" > /dev/null
check "PostToolUse (起動の直後) では終わりにしない" [ "$(running_count)" = 1 ]
check "知らせが無い間は終わりにしない" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sA q1 'ls' 1005 0 '' '${REPO}' '${TS_A}' | silent" && check "知らせが無い間の記録" [ "$(running_count)" = 1 ]
echo "all passed" > "${T}/bg1.out"
enqueue "${TS_A}" bg1 1010 completed "${T}/bg1.out"
check "持ち主の次の hook が終わりにして、 初めてなので黙る" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sA q2 'ls' 1100 0 '' '${REPO}' '${TS_A}' | silent"
check "記録が終わり、 基準が 10 秒 (= 知らせの行の時刻 - 始まり) になる" bash -c "[ \$(find '${STATE}/running' -name '*.json' | wc -l) = 0 ]" && check "background の基準" [ "$(base_value)" = "10.0" ]
# 線の内 (12 秒) は黙り、 基準は動かさない
hook PreToolUse sA bg2 'pytest -q --bg' 2000 1 "" "${REPO}" "${TS_A}" > /dev/null
enqueue "${TS_A}" bg2 2012 completed "${T}/bg1.out"
check "線の内の background は黙る" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PostToolUse sA q3 'ls' 2100 0 '' '${REPO}' '${TS_A}' | silent" && check "線の内なら基準は動かさない" [ "$(base_value)" = "10.0" ]
# 越えた (40 秒) 時は、 持ち主の hook の文脈に文を足す
hook PreToolUse sA bg3 'pytest -q --bg' 3000 1 "" "${REPO}" "${TS_A}" > /dev/null
printf '== slowest 10 durations ==\n9.99s call     tests/bg.py::test_slow\n' > "${T}/bg3.out"
enqueue "${TS_A}" bg3 3040 completed "${T}/bg3.out"
OUT="$(hook PostToolUse sA q4 'ls' 3100 0 '' "${REPO}" "${TS_A}")"
check "background の試験も線を越えたら、 持ち主の hook の文脈に鳴らす文を足す (遅い所は output-file から読む)" bash -c "echo '${OUT}' | grep -q 'additionalContext' && echo '${OUT}' | grep -q 'tests/bg.py::test_slow' && echo '${OUT}' | grep -q '40.0秒'"
check "background の鳴りも閉じる手を止める" bash -c "$(declare -f hook denied); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sA z1 'tabs report done f.md' 3200 | denied"
# ほかの session の hook が終わりにした時は、 鳴りを持ち主に残すだけ
reset
ran sA bg4a 'pytest -q --bg2' 4000 4010 > /dev/null
hook PreToolUse sA bg4 'pytest -q --bg2' 4100 1 "" "${REPO}" "${TS_A}" > /dev/null
enqueue "${TS_A}" bg4 4140 completed "${T}/bg3.out"
check "別の session の hook が終わりにした時は、 その hook の文脈に何も足さない" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PostToolUse sB q5 'ls' 4200 | silent"
check "終わりにした記録は消える" [ "$(running_count)" = 0 ]
check "鳴りは持ち主の session に残り、 閉じる手を止める" bash -c "$(declare -f hook denied); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sA z2 'git commit -m x' 4300 | denied"
check "ほかの session の閉じる手は止めない" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sB z3 'git commit -m x' 4300 | silent"
# 失敗で終わった background は基準にも鳴りにもしない
reset
ran sA bg5a 'pytest -q --bg3' 5000 5010 > /dev/null
hook PreToolUse sA bg5 'pytest -q --bg3' 5100 1 "" "${REPO}" "${TS_A}" > /dev/null
enqueue "${TS_A}" bg5 5900 failed "${T}/bg1.out"
check "失敗で終わった background は黙る" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sA q6 'ls' 6000 | silent"
check "失敗の記録は消え、 基準は動かず、 鳴りも無い" bash -c "[ \"\$(find '${STATE}/running' -name '*.json' | wc -l | tr -d ' ')\" = 0 ] && [ ! -e '${STATE}/ringing/sA.json' ] && grep -q '10.0' '${STATE}/baselines.json'"
# 知らせの行が無い間はぶつかり、 行が出たらぶつからない
reset
hook PreToolUse sA bg6 'pytest -q' 7000 1 "" "${REPO}" "${TS_B}" > /dev/null
check "知らせの行が無い間は、 別の session の試験とぶつかる" bash -c "$(declare -f hook denied); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sB q7 'pytest -q tests' 7100 0 '' '${REPO}' '${TS_B}' | denied"
enqueue "${TS_B}" bg6 7050 completed "${T}/bg1.out"
check "行が出た後は、 数える前に終わりにするのでぶつからない" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sB q8 'pytest -q tests' 7200 0 '' '${REPO}' '${TS_B}' | silent"
# 会話の記録が読めなくても通し、 30 分で捨てる
reset
hook PreToolUse sA bg7 'pytest -q' 8000 1 "" "${REPO}" "${T}/no-such-transcript.jsonl" > /dev/null
check "会話の記録が読めなくても hook は通す" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sB q9 'git status' 8100 | silent"
check "読めない間はぶつかる" bash -c "$(declare -f hook denied); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sB q10 'pytest -q' 8100 | denied"
check "読めなくても 30 分で捨てて通す" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sB q11 'pytest -q' 9900 | silent"

# --- 同じ repo で別の session の試験がぶつかった時だけ止める ---------------------------------------------------
reset
hook PreToolUse sA c1 'pytest -q' 1000 > /dev/null
check "別の session が流している間は、 後から流す側を止めて経過を出す" bash -c "$(declare -f hook denied); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sB c2 'pytest -q tests' 1200 | grep -q '3分20秒'"
check "止める文に repo の名前と別の session を書く" bash -c "$(declare -f hook); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sB c2 'pytest -q tests' 1200 | grep -q 'repo の試験が' && hook PreToolUse sB c2 'pytest -q tests' 1200 | grep -q '別の session'"
check "同じ session は自分とぶつからない" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sA c3 'pytest -q tests' 1200 | silent"
check "試験でない命令は止めない" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sB c4 'git status' 1200 | silent"
hook PostToolUse sA c1 'pytest -q' 1210 > /dev/null
hook PostToolUseFailure sA c3 'pytest -q tests' 1210 > /dev/null
check "終わった後は別の session も流せる" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sB c5 'pytest -q tests' 1300 | silent"
reset
hook PreToolUse sA d1 'pytest -q' 1000 > /dev/null
check "30 分を越えた記録は捨てて通す" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sB d2 'pytest -q' 2900 | silent"
check "捨てた記録は消えている" bash -c "[ ! -e '${STATE}/running/d1.json' ]"
reset
hook PreToolUse sA e1 'pytest -q' 1000 > /dev/null
hook PostToolUseFailure sA e1 'pytest -q' 1005 > /dev/null
check "失敗した試験の記録は捨てて、 基準にもしない" bash -c "[ \$(find '${STATE}' -name '*.json' | wc -l) = 0 ]"
check "失敗の後は別の session も流せる" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sB e2 'pytest -q' 1010 | silent"

# --- ほかの hook が断った呼び出しは終わりの hook が来ない。 会話の記録の結果の行で、 ぶつかりに数えない -------------------
# 道具の結果の行を足す: <記録> <tool-use-id> <誤りなら 1>
result_row() {
    python3 -c 'import json,sys
f,i,e=sys.argv[1:4]
open(f,"a").write(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":i,"is_error":e=="1","content":"x"}]}})+"\n")' "$1" "$2" "$3"
}
TS_D="${T}/ts-d.jsonl"
for background in 0 1; do
    reset
    : > "${TS_D}"
    hook PreToolUse sA h1 'pytest -q' 1000 "${background}" "" "${REPO}" "${TS_D}" > /dev/null
    result_row "${TS_D}" other 1
    out="$(hook PreToolUse sB h2 'pytest -q tests' 1100)"
    check "別の呼び出しの結果では、 ぶつかりを解かない (background=${background})" denied <<< "${out}"
    result_row "${TS_D}" h1 1
    out="$(hook PreToolUse sB h3 'pytest -q tests' 1200)"
    check "断られた呼び出しの記録とはぶつからない (background=${background})" silent <<< "${out}"
    check "断られた呼び出しの記録は消える (background=${background})" [ ! -e "${STATE}/running/h1.json" ]
done
reset
: > "${TS_D}"
hook PreToolUse sA h4 'pytest -q' 1000 1 "" "${REPO}" "${TS_D}" > /dev/null
result_row "${TS_D}" h4 0
out="$(hook PreToolUse sB h5 'pytest -q tests' 1100)"
check "background の起動の返りは終わりに数えない" denied <<< "${out}"

# --- 壊れた状態・入力は通す (= fail-open) --------------------------------------------------------------------
reset
mkdir -p "${STATE}/ringing" "${STATE}/running"
echo '{{{' > "${STATE}/baselines.json"
echo 'not json' > "${STATE}/ringing/sA.json"
echo '[1, "x"' > "${STATE}/running/broken.json"
check "壊れた状態でも閉じる手を通す" bash -c "$(declare -f hook silent); HOOK='${HOOK}' REPO='${REPO}'; hook PreToolUse sA f1 'git commit -m x' 1000 | silent"
check "壊れた状態でも試験は黙って記録する" bash -c "$(declare -f ran hook silent); HOOK='${HOOK}' REPO='${REPO}'; ran sA f2 'pytest -q' 1000 1010 | silent"
check "壊れた入力は黙って通す" bash -c "echo 'not json' | python3 '${HOOK}' | grep -c . | grep -q '^0$'"
check "壊れた入力でも exit 0" bash -c "echo 'not json' | python3 '${HOOK}'"
check "Bash 以外の道具は通す" bash -c "echo '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"command\":\"git commit\"}}' | python3 '${HOOK}' | grep -c . | grep -q '^0$'"

# --- AGENT_PLATFORM_ROOT が無い時の置き場 ----------------------------------------------------------------------
check "AGENT_PLATFORM_ROOT が無ければ ~/.local/state/agent-test-times/ に書く" bash -c "
    unset AGENT_PLATFORM_ROOT; $(declare -f ran hook); HOOK='${HOOK}' REPO='${REPO}' HOME='${HOME}'
    ran sA g1 'pytest -q' 1000 1010 > /dev/null; [ -f '${HOME}/.local/state/agent-test-times/baselines.json' ]"

echo "test-test-time-gate: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
