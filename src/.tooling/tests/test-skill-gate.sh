#!/bin/bash
# test-skill-gate.sh - skill_gate.py は、 表の操作に当たって会話の記録に読んだ跡の無い skill がある時だけ 1 回言い、
# 読んだ後・当たらない操作・表が無い時は黙る。 作り物の会話の記録と表で、 止める所と黙る所を 1 つずつ確かめる。
# 表の `file` (= plugin の skill の SKILL.md の在処) を持つ skill は、 その file で案内し、 その file で読んだ跡を見る。
#   bash .tooling/tests/test-skill-gate.sh
set -u
HOOKS="$(cd "$(dirname "$0")/.." && pwd)/hooks"
ROOT="$(cd "${HOOKS}/../.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "${W}"' EXIT
export SKILL_GATE_TEMPORARY_ROOTS="/scratch-root"  # 作業場は /var/folders の下なので、 一時の置き場を別にする
export SKILL_GATE_TABLE="${W}/table.toml"
pass=0
fail=0

check() { # <説明> <コマンド...>
    local what="$1"
    shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}

cat > "${SKILL_GATE_TABLE}" <<'TOML'
[[skill]]
name = "code-writing"
[[skill.when]]
tools = ["Write", "Edit"]
code = true

[[skill]]
name = "explainer-pages"
[[skill.when]]
tools = ["Bash"]
command = '\btabs\s+send\b'

[[skill]]
name = "messages"
[[skill.when]]
tools = ["Bash"]
command = '\btabs\s+(send|list)\b'

[[skill]]
name = "rule-registry"
[[skill.when]]
tools = ["Write"]
path = '{root}/(.*/)?rules/'

[[skill]]
name = "browser-use"
[[skill.when]]
tools = ["mcp__claude-in-chrome__*"]

[[skill]]
name = "session-end"
[[skill.when]]
event = "UserPromptSubmit"
prompt = '<session-rollover phase="close">|締めよう'

[[skill]]
name = "child-start"
[[skill.when]]
event = "SessionStart"
env = ["AGENT_CHILD=1"]

[[skill]]
name = "pwa-client:tabs"
file = "{platform}/tools/client/skills/tabs/SKILL.md"
[[skill.when]]
tools = ["Bash"]
command = '\btabs\s+report\b'

[[skill]]
name = "pwa-client:ops"
file = "{platform}/tools/client/skills/ops/SKILL.md"
[[skill.when]]
tools = ["Read", "Edit"]
path = '/platform/tools/client/'
TOML

SPOKE='{"type":"user","message":{"content":"fix it"}}'
loaded() { printf '{"type":"user","message":{"content":[{"type":"text","text":"Base directory for this skill: /x/.claude/skills/%s\\n\\n# rules"}]}}' "$1"; }
read_by_tool() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/.claude/skills/%s/SKILL.md"}}]}}' "$1"; }
loaded_from() { printf '{"type":"user","message":{"content":[{"type":"text","text":"Base directory for this skill: %s\\n\\n# tabs"}]}}' "$1"; }
read_file() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"%s"}}]}}' "$1"; }
record() { local file="$1"; shift; printf '%s\n' "$@" > "${file}"; }

# hook <transcript> <payload の残りの JSON>
hook() { printf '{"transcript_path":"%s",%s}' "$1" "$2" | AGENT_PLATFORM_ROOT="${W}/platform" python3 "${HOOKS}/skill_gate.py"; }
tool() { printf '"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s' "$1" "$2"; }
denies() { grep -q '"permissionDecision": "deny"' <<< "$1"; }
names() { grep -q "\`$2\`" <<< "$1"; }
silent() { [ -z "$1" ]; }

NONE="${W}/none.jsonl"; record "${NONE}" "${SPOKE}" "$(loaded transcripts)"
CODE="{\"file_path\":\"${W}/repo/tool.py\",\"content\":\"x\"}"

out="$(hook "${NONE}" "$(tool Write "${CODE}")")"
check "読んでいない時は code の file を書く道具を止める" denies "${out}"
check "止める時は読む skill を名指す" names "${out}" code-writing

T="${W}/loaded.jsonl"; record "${T}" "${SPOKE}" "$(loaded code-writing)"
check "skill を呼んだ後は黙る" silent "$(hook "${T}" "$(tool Write "${CODE}")")"
T="${W}/read.jsonl"; record "${T}" "${SPOKE}" "$(read_by_tool code-writing)"
check "SKILL.md を読んだ後も黙る" silent "$(hook "${T}" "$(tool Write "${CODE}")")"
T="${W}/named.jsonl"; record "${T}" "${SPOKE}" '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"sed -i s/a/b/ /x/.claude/skills/code-writing/SKILL.md"}}]}}'
check "Bash の命令で path を名指しただけでは読んだ跡に数えない" denies "$(hook "${T}" "$(tool Write "${CODE}")")"
T="${W}/prefix.jsonl"; record "${T}" "${SPOKE}" "$(loaded code-writing-old)"
check "名前が前方で同じ別の skill は読んだ跡に数えない" denies "$(hook "${T}" "$(tool Write "${CODE}")")"

check "code でない file は通る" silent "$(hook "${NONE}" "$(tool Write "{\"file_path\":\"${W}/notes.md\",\"content\":\"x\"}")")"
check "一時の置き場は通る" silent "$(hook "${NONE}" "$(tool Write '{"file_path":"/scratch-root/a.py","content":"x"}')")"
check "拡張子の無い script は #! で code と見る" denies "$(hook "${NONE}" "$(tool Write "{\"file_path\":\"${W}/run\",\"content\":\"#!/bin/sh\"}")")"

out="$(hook "${NONE}" "$(tool Bash '{"command":"tabs send ses_x msg.md"}')")"
check "2 本当たったら 1 回で止める" denies "${out}"
check "1 回目に 2 本とも名指す" bash -c 'grep -q "\`explainer-pages\`" <<< "$1" && grep -q "\`messages\`" <<< "$1"' _ "${out}"
T="${W}/one.jsonl"; record "${T}" "${SPOKE}" "$(loaded explainer-pages)"
out="$(hook "${T}" "$(tool Bash '{"command":"tabs send ses_x msg.md"}')")"
check "読んだ 1 本は外し、残りだけ名指す" bash -c '! grep -q "\`explainer-pages\`" <<< "$1" && grep -q "\`messages\`" <<< "$1"' _ "${out}"
check "当たらない命令は通る" silent "$(hook "${NONE}" "$(tool Bash '{"command":"git status"}')")"

check "{root} はこの agent の folder" denies "$(hook "${NONE}" "$(tool Write "{\"file_path\":\"${ROOT}/projects/p/rules/always.md\",\"content\":\"x\"}")")"
check "{root} の外の rules/ は通る" silent "$(hook "${NONE}" "$(tool Write "{\"file_path\":\"${W}/other/rules/a.md\",\"content\":\"x\"}")")"
check "道具の名前は * で前方一致" denies "$(hook "${NONE}" "$(tool mcp__claude-in-chrome__navigate '{}')")"

SUB="${W}/main.jsonl"; record "${SUB}" "${SPOKE}" "$(loaded code-writing)"
mkdir -p "${W}/main/subagents"; record "${W}/main/subagents/agent-a1.jsonl" "${SPOKE}"
check "体は自分の会話の記録で判定する" denies "$(hook "${SUB}" "$(tool Write "${CODE}"),\"agent_id\":\"a1\"")"

out="$(hook "${NONE}" '"hook_event_name":"UserPromptSubmit","prompt":"今日はもう締めよう"')"
check "発話で当たったら 1 行の注意を足す" grep -q '"additionalContext": "\[skill-gate\]' <<< "${out}"
check "発話の注意は止めない" bash -c '! grep -q permissionDecision <<< "$1"' _ "${out}"
T="${W}/ended.jsonl"; record "${T}" "${SPOKE}" "$(loaded session-end)"
check "読んだ後の発話は黙る" silent "$(hook "${T}" '"hook_event_name":"UserPromptSubmit","prompt":"締めよう"')"
out="$(AGENT_CHILD=1 hook "${W}/no-such.jsonl" '"hook_event_name":"SessionStart","source":"startup"')"
check "子のタブの起動では子の手順を名指す" names "${out}" child-start
check "子でない起動は黙る" silent "$(env -u AGENT_CHILD bash -c "printf '{\"hook_event_name\":\"SessionStart\"}' | python3 '${HOOKS}/skill_gate.py'")"

# plugin の skill (= 表の `file` を持つ。 名前に `:`)
PLUGIN_DIR="${W}/platform/tools/client/skills/tabs"
REPORT="$(tool Bash '{"command":"tabs report done r.md"}')"
out="$(hook "${NONE}" "${REPORT}")"
check "plugin の skill は読んでいない時に 1 回止める" denies "${out}"
check "止める時は表の file を名指す" names "${out}" pwa-client:tabs
check "止める時は表の file の path を名指す" grep -qF "(${PLUGIN_DIR}/SKILL.md)" <<< "${out}"
check "file のある skill をこの agent の skills の下とは案内しない" bash -c '! grep -qF ".claude/skills/pwa-client:tabs" <<< "$1"' _ "${out}"
T="${W}/plugin-read.jsonl"; record "${T}" "${SPOKE}" "$(read_file "${PLUGIN_DIR}/SKILL.md")"
check "plugin の SKILL.md を Read で読んだ後は黙る" silent "$(hook "${T}" "${REPORT}")"
T="${W}/plugin-loaded.jsonl"; record "${T}" "${SPOKE}" "$(loaded_from "${PLUGIN_DIR}")"
check "plugin の skill を呼んだ印 (= folder の path) の後は黙る" silent "$(hook "${T}" "${REPORT}")"
T="${W}/plugin-other.jsonl"; record "${T}" "${SPOKE}" "$(read_file "${W}/elsewhere/skills/tabs/SKILL.md")" "$(loaded_from "${PLUGIN_DIR}-old")"
check "別の場所の同じ名前の SKILL.md と、 前方が同じ別の folder は読んだ跡に数えない" denies "$(hook "${T}" "${REPORT}")"

# その skill 自身の SKILL.md を読む Read は止めない (= 案内が求める読みそのもの)
OPS_FILE="${W}/platform/tools/client/skills/ops/SKILL.md"
check "plugin の skill 自身の SKILL.md を Read する時は止めない" silent "$(hook "${NONE}" "$(tool Read "{\"file_path\":\"${OPS_FILE}\"}")")"
out="$(hook "${NONE}" "$(tool Read "{\"file_path\":\"${W}/platform/tools/client/README.md\"}")")"
check "同じ木の別の file を Read する時は止める" denies "${out}"
check "止める時は読む skill の file を名指す" grep -qF "(${OPS_FILE})" <<< "${out}"
check "その skill の SKILL.md を Edit する時は止める" denies "$(hook "${NONE}" "$(tool Edit "{\"file_path\":\"${OPS_FILE}\"}")")"

check "表が無ければ黙る" silent "$(SKILL_GATE_TABLE="${W}/missing.toml" hook "${NONE}" "$(tool Write "${CODE}")")"
check "読めない入力は黙る" silent "$(printf 'not json' | python3 "${HOOKS}/skill_gate.py")"

# 本物の表は、 書いた skill の SKILL.md が全部在る (= file の無い行はこの agent の skills の下、 在る行はその file)
real_missing="$(python3 - "${HOOKS}" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from skill_gate import PLATFORM, ROOT
from skill_reads import load_table
from skill_triggers import skill_file
rows = load_table(Path(sys.argv[1]) / "skill-triggers.toml")
print(" ".join(r["name"] for r in rows if not skill_file(r, ROOT, PLATFORM).is_file()))
PY
)"
check "本物の表の skill が全部在る (無い: ${real_missing})" [ -z "${real_missing}" ]

echo "test-skill-gate: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
