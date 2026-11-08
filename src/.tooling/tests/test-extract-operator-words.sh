#!/bin/bash
# .tooling/session-end/extract-operator-words.py の test。 作り物の会話の記録で、 操作者が打った発話だけが拾われ、
# 連絡・封筒・通知・道具の返りが除かれ、 直前の作った物の path が添い、 2 度流しても増えず、
# 書き出し先 (= journal の session の番号つきの file / 渡した file) と過去の分を拾う口が決まりどおりに働くことを確かめる。
#
#   bash .tooling/tests/test-extract-operator-words.sh
set -uo pipefail

TOOLING="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

check() { # <説明> <コマンド...>
    local what="$1"
    shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}

# 作り物のエージェントの repo (= script と、 それが読む部品だけを写す)
AGENT="${T}/agent"
mkdir -p "${AGENT}/.tooling/session-end" "${AGENT}/.tooling/lib" "${T}/home/.claude/projects/-p" "${T}/home/.claude-work/projects/-w"
cp "${TOOLING}/session-end/extract-operator-words.py" "${AGENT}/.tooling/session-end/"
cp "${TOOLING}/lib/client_openings.py" "${TOOLING}/lib/operator_words.py" "${TOOLING}/lib/session_transcript.py" "${TOOLING}/lib/session_scope.py" "${TOOLING}/lib/tier_paths.py" "${AGENT}/.tooling/lib/"
today="$(date '+%Y-%m-%d')"
# 番人の口の作り物 (= client が打つ発話の 1 行目の表。 真値は番人)
cat > "${T}/order.py" <<'PY'
print(">Message from another session, relayed by the client")
print(">>Message from a session on another machine, relayed by the client")
print(">Automatic session rollover, sent by the client")
print(">Tab opened by the client for its tier")
print(">Sent by the client (the operator did not type this):")
PY
export GUARD_ORDER_PY="${T}/order.py"

# 作り物の会話の記録 (= 1 行 1 JSON)。 操作者の発話は 2 件 (user の行 1 件と、 作業中に積まれた発話 1 件)、 残りは除かれる行
RECORD="${T}/home/.claude/projects/-p/sess-a.jsonl"
python3 - "${RECORD}" "${AGENT}" <<'PY'
import json, sys
rows = []
cwd = sys.argv[2]
def user(ts, content, **extra):
    rows.append({"type": "user", "timestamp": ts, "cwd": cwd, "message": {"role": "user", "content": content}, **extra})
def queued(ts, prompt, mode="prompt"):
    rows.append({"type": "attachment", "timestamp": ts, "cwd": cwd, "attachment": {"type": "queued_command", "prompt": prompt, "commandMode": mode}})
def assistant(ts, blocks):
    rows.append({"type": "assistant", "timestamp": ts, "cwd": cwd, "message": {"role": "assistant", "content": blocks}})
user("2026-11-05T01:00:00Z", "この図は白い箱でいい")
assistant("2026-11-05T01:01:00Z", [
    {"type": "text", "text": "作りました `~/agent/pages/ses_1/flow.html` を開いてください。 参考 https://example.org/ref/doc.html と pages/ses_1/notes.md"},
    {"type": "tool_use", "name": "Write", "input": {"file_path": "/agent/pages/ses_1/deck/slide-3.pptx", "content": "x"}},
    {"type": "tool_use", "name": "Bash", "input": {"command": "cp /agent/out/chart.png /agent/pages/ses_1/chart.png; ls /agent/pages/*.html /agent/pages/$f.html"}},
])
user("2026-11-05T01:02:00Z", [{"type": "tool_result", "tool_use_id": "t1", "content": "/agent/pages/ses_1/tool-result-only.html"}])
user("2026-11-05T01:03:00Z", "Message from another session, relayed by the client (the operator did not type this):\n<agent-message>x</agent-message>")
user("2026-11-05T01:03:30Z", [{"type": "text", "text": "<pasted_content id=\"4e23\">\nMessage from another session, relayed by the client\n</pasted_content>"}])
user("2026-11-05T01:04:00Z", "Automatic session rollover, sent by the client (the operator did not type this): <session-rollover phase=\"close\">")
user("2026-11-05T01:05:00Z", "<task-notification><task-id>b1</task-id></task-notification>")
user("2026-11-05T01:06:00Z", "<child-start>\ntier=normal\n</child-start>\n\nあなたは sub-agent です")
user("2026-11-05T01:07:00Z", "Tab opened by the client for its tier (the operator did not type this):")
user("2026-11-05T01:08:00Z", "<command-name>/clear</command-name>")
user("2026-11-05T01:09:00Z", [{"type": "text", "text": "[Request interrupted by user]"}])
user("2026-11-05T01:10:00Z", "Base directory for this skill: /x/skill", isMeta=True)
user("2026-11-05T01:10:30Z", "Sent by the client (the operator did not type this):\n<child-stopped child=\"ses_c\" reason=\"idle\">\nThe child stopped.\n</child-stopped>")
queued("2026-11-05T01:11:00Z", "表に名前が無いとわからない")
queued("2026-11-05T01:11:30Z", "Sent by the client (the operator did not type this):\n<limit-resume account=\"personal\">\ngo on")
queued("2026-11-05T01:12:00Z", "<task-notification>done</task-notification>", mode="task-notification")
queued("2026-11-05T01:13:00Z", "<pasted_content id=\"9\">\nMessage from a session on another machine, relayed by the client\n</pasted_content>")
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.writelines(json.dumps(row, ensure_ascii=False) + "\n" for row in rows)
PY

# 1 発話だけの session の記録 (= 作業 folder の列を渡す)
session_file() { # <記録の file> <発話> <ts> <作業 folder...>
    local file="$1" text="$2" ts="$3"
    shift 3
    mkdir -p "$(dirname "${file}")"
    python3 - "${file}" "${text}" "${ts}" "$@" <<'PY'
import json, sys
file, text, ts, *folders = sys.argv[1:]
rows = [{"type": "user", "timestamp": ts, "cwd": folder, "message": {"role": "user", "content": text if index == 0 else "(続き)"}}
        for index, folder in enumerate(folders)]
rows = [rows[0]] + [dict(row, type="assistant", message={"role": "assistant", "content": [{"type": "text", "text": "x"}]}) for row in rows[1:]]
open(file, "w").write("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows))
PY
}
HOMEP="${T}/home/.claude/projects"
# 同じ時刻 ts の発話が別の session にも在る (= 重なりを見るのは session と ts の組)
session_file "${HOMEP}/-p/sess-b.jsonl" "別の session の同じ時刻の発話" "2026-11-05T01:00:00Z" "${AGENT}"
# 別の口座 (`~/.claude-work`) の記録
session_file "${T}/home/.claude-work/projects/-w/sess-w.jsonl" "別の口座の発話" "2026-11-05T02:00:00Z" "${AGENT}"
# 階層のタブの session (= 途中でその階層の folder に入る)
session_file "${HOMEP}/-p/sess-project.jsonl" "プロジェクトの発話" "2026-11-05T03:00:00Z" "${AGENT}" "${AGENT}/projects/P"
session_file "${HOMEP}/-p/sess-sub.jsonl" "サブの発話" "2026-11-05T03:10:00Z" "${AGENT}" "${AGENT}/projects/P/subprojects/S/_wt/x"
session_file "${HOMEP}/-p/sess-mixed.jsonl" "二つの階層を通った発話" "2026-11-05T03:20:00Z" "${AGENT}/projects/P" "${AGENT}/projects/Q"
session_file "${HOMEP}/-p/sess-away.jsonl" "エージェントの外の発話" "2026-11-05T03:30:00Z" "/somewhere/else"

run() { # <引数...> (= 作り物の repo と作り物の HOME で、 session sess-a として走らせる)
    (cd "${AGENT}" && HOME="${T}/home" CLAUDE_CODE_SESSION_ID="${SID:-sess-a}" CLAUDE_CONFIG_DIR="${CONFIG:-}" \
        python3 .tooling/session-end/extract-operator-words.py "$@")
}
rows_of() { python3 -c 'import json,sys; print(len([l for l in open(sys.argv[1]) if l.strip()]))' "$1"; }
field() { # <file> <行番号> <式 (= r が行)>
    python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).read().splitlines()[int(sys.argv[2])]); print(eval(sys.argv[3]))' "$1" "$2" "$3"
}

# --- 1 session の記録から、 渡した番号の file へ ---
mkdir -p "${AGENT}/journal/${today}"
: > "${AGENT}/journal/${today}/session-01.md"
OUT="${AGENT}/journal/${today}/session-05-operator-words.jsonl"
run journal --nn 5 >/dev/null 2>&1
check "the number given names the file beside the journal" [ -f "${OUT}" ]
check "only the two utterances the operator typed are kept (reply rows, relays, envelopes, notifications and tool results are not)" [ "$(rows_of "${OUT}")" = 2 ]
check "the first utterance keeps its words" [ "$(field "${OUT}" 0 'r["text"]')" = "この図は白い箱でいい" ]
check "a queued utterance (typed mid-turn) is kept" [ "$(field "${OUT}" 1 'r["text"]')" = "表に名前が無いとわからない" ]
check "the first utterance has no artifact before it" [ "$(field "${OUT}" 0 'r["artifacts"]')" = "[]" ]
check "the artifacts between the two utterances are the paths in the reply text and the tool inputs, in order" \
    [ "$(field "${OUT}" 1 'r["artifacts"]')" = "['~/agent/pages/ses_1/flow.html', '/agent/pages/ses_1/deck/slide-3.pptx', '/agent/out/chart.png', '/agent/pages/ses_1/chart.png']" ]
check "a tool result's path, a URL, a non-artifact path and a shell wildcard or variable are not artifacts" \
    bash -c '! grep -q "tool-result-only\|example.org\|notes.md\|\*\.html\|\$f" "$1"' _ "${OUT}"
check "each row names its session, tier and time" \
    [ "$(field "${OUT}" 1 'r["session"] + "|" + r["tier"] + "|" + r["ts"]')" = "sess-a|normal|2026-11-05T01:11:00Z" ]

run journal --nn 5 >/dev/null 2>&1
check "running again adds nothing" [ "$(rows_of "${OUT}")" = 2 ]
# 番人が 1 行目を返さない時は、 黙って数えずに 1 行で知らせる
warned="$(GUARD_ORDER_PY="${T}/missing.py" run journal --nn 9 2>&1 >/dev/null)"
check "without the guard's opening lines, it says so on stderr" grep -q "gave no opening lines" <<< "${warned}"

# --- 番号を渡さない時と、 誤った番号 ---
run journal >/dev/null 2>&1
check "without a number, the next one after the day's journals" [ -f "${AGENT}/journal/${today}/session-02-operator-words.jsonl" ]
for bad in 0 100 x; do
    out="$(run journal --nn "${bad}" 2>&1)"
    code=$?
    check "--nn '${bad}' stops with a usage error" [ "${code}" -eq 2 ]
    check "--nn '${bad}' says what --nn takes" grep -q -- "--nn takes" <<<"${out}"
done

# --- 階層の名前は journal の場所で決まる ---
mkdir -p "${AGENT}/projects/P/subprojects/S/journal"
run projects/P/subprojects/S/journal --nn 1 >/dev/null 2>&1
check "a subproject's journal gets its own file" [ -f "${AGENT}/projects/P/subprojects/S/journal/${today}/session-01-operator-words.jsonl" ]
check "the tier of a subproject's rows is its path" \
    [ "$(field "${AGENT}/projects/P/subprojects/S/journal/${today}/session-01-operator-words.jsonl" 0 'r["tier"]')" = "projects/P/subprojects/S" ]
out="$(run notjournal 2>&1)"
code=$?
check "a folder that is not a journal stops with a usage error" [ "${code}" -eq 2 ]
check "a folder that is not a journal says so" grep -q "journal" <<<"${out}"

# --- 読むのは自分の session の記録だけ ---
cp "${RECORD}" "${HOMEP}/-p/sid-123.jsonl"
SID=sid-123 run journal --nn 6 >/dev/null 2>&1
check "the session id names the transcript" [ "$(rows_of "${AGENT}/journal/${today}/session-06-operator-words.jsonl")" = 2 ]
check "the rows carry the session id" [ "$(field "${AGENT}/journal/${today}/session-06-operator-words.jsonl" 0 'r["session"]')" = "sid-123" ]
check "no other session's words come with it" bash -c '! grep -q "別の session\|プロジェクトの発話\|別の口座" "$1"' _ "${AGENT}/journal/${today}/session-06-operator-words.jsonl"
out="$(SID=no-such-session run journal --nn 7 2>&1)"
check "a session whose record is not found says so and writes nothing" bash -c '[ ! -e "$1" ]' _ "${AGENT}/journal/${today}/session-07-operator-words.jsonl"
check "a missing record is reported" grep -q "no transcript found" <<<"${out}"
out="$(run journal --transcript "${RECORD}" 2>&1)"
code=$?
check "there is no way to name another record (--transcript is refused)" [ "${code}" -eq 2 ]

# --- 過去の分を拾う口: 走らせた口座の記録のうち、 その階層の持ち物の session だけを、 渡した file へ ---
ALL="${T}/all.jsonl"
out="$(run journal --all-sessions 2>&1)"
code=$?
check "--all-sessions without --out stops with a usage error" [ "${code}" -eq 2 ]
run journal --all-sessions --out "${ALL}" >/dev/null 2>&1
check "normal reads the sessions that stayed in the agent folder (sess-a 2, sess-b 1, sid-123 2)" [ "$(rows_of "${ALL}")" = 5 ]
check "normal does not read the other account" bash -c '! grep -q "別の口座" "$1"' _ "${ALL}"
check "normal does not read a session that entered a tier" bash -c '! grep -q "プロジェクトの発話\|サブの発話\|二つの階層" "$1"' _ "${ALL}"
check "normal does not read a session outside the agent folder" bash -c '! grep -q "エージェントの外" "$1"' _ "${ALL}"
check "two sessions' rows with the same time are both kept" grep -q "別の session の同じ時刻の発話" "${ALL}"
run journal --all-sessions --out "${ALL}" >/dev/null 2>&1
check "--all-sessions run again adds nothing" [ "$(rows_of "${ALL}")" = 5 ]

mkdir -p "${AGENT}/projects/P/journal" "${AGENT}/projects/P/subprojects/S/journal"
ALL_PROJECT="${T}/all-project.jsonl"
run projects/P/journal --all-sessions --out "${ALL_PROJECT}" >/dev/null 2>&1
check "a project reads only the sessions that entered it and stayed at or above it" [ "$(rows_of "${ALL_PROJECT}")" = 1 ]
check "the project's row is its own session" grep -q "プロジェクトの発話" "${ALL_PROJECT}"
check "the project's rows carry its tier" [ "$(field "${ALL_PROJECT}" 0 'r["tier"]')" = "projects/P" ]
ALL_SUB="${T}/all-sub.jsonl"
run projects/P/subprojects/S/journal --all-sessions --out "${ALL_SUB}" >/dev/null 2>&1
check "a subproject reads only the sessions that entered it" [ "$(rows_of "${ALL_SUB}")" = 1 ]
check "the subproject's row is its own session" grep -q "サブの発話" "${ALL_SUB}"
check "a session that went through two tiers is read by neither" bash -c '! grep -q "二つの階層" "$1" "$2" "$3"' _ "${ALL}" "${ALL_PROJECT}" "${ALL_SUB}"

# 別の口座で走らせた時は、 その口座の記録だけを読む
ALL_WORK="${T}/all-work.jsonl"
CONFIG="${T}/home/.claude-work" run journal --all-sessions --out "${ALL_WORK}" >/dev/null 2>&1
check "the running account's records are the ones read" [ "$(rows_of "${ALL_WORK}")" = 1 ]
check "the other account is not read" grep -q "別の口座の発話" "${ALL_WORK}"

# --- PowerPoint の直しの取り込みの記録 (資料の folder の .pptx-agent-maker/reviews.jsonl) ---
DECK="${AGENT}/decks/w1"
mkdir -p "${DECK}/.pptx-agent-maker"
python3 - "${HOMEP}/-p/sess-r.jsonl" "${AGENT}" "${DECK}" <<'PY'
import json, sys
file, cwd, deck = sys.argv[1:]
rows = [
    {"type": "user", "timestamp": "2026-11-05T09:00:00Z", "cwd": cwd, "message": {"role": "user", "content": "資料を作って"}},
    {"type": "assistant", "timestamp": "2026-11-05T09:01:00Z", "cwd": cwd, "message": {"role": "assistant", "content": [
        {"type": "text", "text": f"焼きました {deck}/w1.pptx"}]}},
    {"type": "user", "timestamp": "2026-11-05T09:30:00Z", "cwd": cwd, "message": {"role": "user", "content": "PowerPoint で直したので取り込んで"}},
]
open(file, "w").write("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows))
PY
python3 - "${DECK}/.pptx-agent-maker/reviews.jsonl" <<'PY'
import json, sys
rows = [
    {"at": "2026-11-05T17:00:00+09:00", "deck": "w1.pptx", "how": "words", "page": 1, "printed": 1, "words": [["前の日の直し", "x"]]},
    {"at": "2026-11-05T18:10:00+09:00", "deck": "w1.pptx", "how": "words", "page": 2, "printed": 2,
     "words": [["手法 A の結果", "手法 A の結果 (改)"]], "before": "_edits/w1-built.pptx", "after": "_edits/w1.pptx"},
]
open(sys.argv[1], "w").write("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows))
PY
REVIEW_OUT="${AGENT}/journal/${today}/session-07-operator-words.jsonl"
SID=sess-r run journal --nn 07 >/dev/null 2>&1
check "the review log of a deck this session made adds its rows after the utterances" [ "$(rows_of "${REVIEW_OUT}")" = 3 ]
check "a review taken in before this session started is not read" bash -c '! grep -q "前の日の直し" "$1"' _ "${REVIEW_OUT}"
check "the review row names how, the deck, the printed page and each change" \
    [ "$(field "${REVIEW_OUT}" 2 'r["text"]')" = "PowerPoint で直した (words) w1.pptx の 2 頁: 「手法 A の結果」→「手法 A の結果 (改)」" ]
check "the review row carries the versions before and after, and its source" \
    [ "$(field "${REVIEW_OUT}" 2 'r["artifacts"], r["source"]')" = "(['_edits/w1-built.pptx', '_edits/w1.pptx'], 'review')" ]
SID=sess-r run journal --nn 07 >/dev/null 2>&1
check "running again adds no review row" [ "$(rows_of "${REVIEW_OUT}")" = 3 ]

echo "test-extract-operator-words: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
