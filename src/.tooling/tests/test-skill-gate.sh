#!/bin/bash
# test-skill-gate.sh - skill_gate.py は、 表の操作に当たって会話の記録に読んだ跡の無い skill がある時だけ 1 回言い、
# 読んだ後・当たらない操作・表が無い時は黙る。 読んだ後に SKILL.md が書き換わった skill は、 もう 1 回言う。 作り物の会話の記録と表で、 止める所と黙る所を 1 つずつ確かめる。
# 表の `file` (= plugin の skill の SKILL.md の在処) を持つ skill は、 その file で案内し、 その file で読んだ跡を見る。
#   bash .tooling/tests/test-skill-gate.sh
set -u
HOOKS="$(cd "$(dirname "$0")/.." && pwd)/hooks"
ROOT="$(cd "${HOOKS}/../.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "${W}"' EXIT
export SKILL_GATE_TEMPORARY_ROOTS="/scratch-root"  # 作業場は /var/folders の下なので、 一時の置き場を別にする
export SKILL_GATE_TABLE="${W}/table.toml"
export SKILL_GATE_BASE_TABLE="${W}/no-base.toml"  # 型の表は、 下の型の表の試験の所でだけ置く
export AGENT_ROOT="${ROOT}"  # 起動役が渡す、 この session のエージェントの根
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
name = "writer-body"
[[skill.when]]
tools = ["Agent"]
subagent = '^(?!(Explore|claude-code-guide)$)'

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
# 道具は止めずに通し、 読む案内を足す (= 止めるとエージェントが同じ命令をもう一度書く)
denies() { grep -q 'ran as written. Before the next step' <<< "$1" && ! grep -q permissionDecision <<< "$1"; }
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
T="${W}/through.jsonl"; record "${T}" "${SPOKE}" "$(loaded_from /x/tools/code-writing/skills/tabs)"
check "別の skill の folder の path の途中に名前があるだけでは読んだ跡に数えない" denies "$(hook "${T}" "$(tool Write "${CODE}")")"

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
check "別のタブの連絡の本文の語では鳴らさない" silent "$(hook "${NONE}" '"hook_event_name":"UserPromptSubmit","prompt":"Message from another session, relayed by the client (the operator did not type this):\n<agent-message from=\"x\" session=\"ses_x\">\n今日はもう締めよう\n</agent-message>"')"
check "体の完了の知らせの本文の語では鳴らさない" silent "$(hook "${NONE}" '"hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\n<result>寝る前に決めておく</result>\n</task-notification>"')"
check "client の知らせの本文の語では鳴らさない" silent "$(hook "${NONE}" '"hook_event_name":"UserPromptSubmit","prompt":"Sent by the client (the operator did not type this):\n今日はここまで"')"
check "包まれて届いた別のタブの連絡の本文の語では鳴らさない" silent "$(hook "${NONE}" '"hook_event_name":"UserPromptSubmit","prompt":"\n\n<pasted_content id=\"ab12\">\nMessage from another session, relayed by the client (the operator did not type this):\n<agent-message from=\"x\" session=\"ses_x\">\n今日はもう締めよう\n</agent-message>\n</pasted_content id=\"ab12\">"')"
check "包まれた操作者の貼り付けの後の語では鳴らす" names "$(hook "${NONE}" '"hook_event_name":"UserPromptSubmit","prompt":"<pasted_content id=\"ab12\">\nlog の行\n</pasted_content id=\"ab12\">\n今日はもう締めよう"')" session-end
check "入れ替えの封筒の引き金では鳴らす" names "$(hook "${NONE}" '"hook_event_name":"UserPromptSubmit","prompt":"Automatic session rollover, sent by the client:\n<session-rollover phase=\"close\">\n</session-rollover>"')" session-end
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

# 読んだ後に SKILL.md が書き換わったら、 次の当たりでもう 1 回読ませる (= 読んだ行の時刻と file の更新時刻を比べる)
mkdir -p "${PLUGIN_DIR}"; printf '# tabs\n' > "${PLUGIN_DIR}/SKILL.md"
touch -d 2026-11-20T10:00:00Z "${PLUGIN_DIR}/SKILL.md"
loaded_at() { printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"text","text":"Base directory for this skill: %s\\n\\n# tabs"}]}}' "$2" "$1"; }
read_at() { printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"%s"}}]}}' "$2" "$1"; }
edit_at() { printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"%s","name":"Edit","input":{"file_path":"%s"}}]}}' "$3" "$2" "$1"; }
result_at() { printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"%s","is_error":%s,"content":"done"}]}}' "$2" "$1" "${3:-false}"; }
T="${W}/stale.jsonl"; record "${T}" "${SPOKE}" "$(loaded_at "${PLUGIN_DIR}" 2026-11-20T09:00:00Z)"
out="$(hook "${T}" "${REPORT}")"
check "読んだ後に SKILL.md が書き換わっていたら、 もう 1 回止める" denies "${out}"
check "書き換わった skill はそうと言う" grep -q 'changed since this session read it' <<< "${out}"
check "初めての案内は書き換わったとは言わない" bash -c '! grep -q "changed since" <<< "$1"' _ "$(hook "${NONE}" "${REPORT}")"
AFTER_CHANGE=2099-01-01T00:00:00Z   # date の相対指定は BSD と GNU で書き方が違うので、 書き換えより必ず後の固定の時刻
# 読んだ時の版が git に在れば、 全文の代わりに差分を見せ、 見せた差し込みを読んだ印に数える
GIT_PLUGIN="${W}/platform/tools/client"
tgit() { HOME="${W}" git -c user.name=t -c user.email=t@example.invalid "$@"; }
tgit -C "${GIT_PLUGIN}" init -q
tgit -C "${GIT_PLUGIN}" add -A && GIT_COMMITTER_DATE=2026-11-20T08:00:00Z tgit -C "${GIT_PLUGIN}" commit -q --date=2026-11-20T08:00:00Z -m first
printf '# tabs\nname the child by its work\n' > "${PLUGIN_DIR}/SKILL.md"
T="${W}/diffed.jsonl"; record "${T}" "${SPOKE}" "$(loaded_at "${PLUGIN_DIR}" 2026-11-20T09:00:00Z)"
out="$(hook "${T}" "${REPORT}")"
check "読んだ時の版が git に在れば、 差分を見せる" grep -q '+name the child by its work' <<< "${out}"
check "差分を見せた時は、 全文を読めとは言わない" bash -c '! grep -q "read the skill" <<< "$1"' _ "${out}"
shown() { printf '{"type":"attachment","timestamp":"%s","attachment":{"type":"hook_additional_context","content":[%s]}}' "$1" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")"; }
note="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["hookSpecificOutput"]["additionalContext"])' "${out}")"
T="${W}/diff-shown.jsonl"; record "${T}" "${SPOKE}" "$(loaded_at "${PLUGIN_DIR}" 2026-11-20T09:00:00Z)" "$(shown "${AFTER_CHANGE}" "${note}")"
check "差分を見せた差し込みの後は黙る (= その版を読んだに数える)" silent "$(hook "${T}" "${REPORT}")"
rm -rf "${GIT_PLUGIN}/.git"; printf '# tabs\n' > "${PLUGIN_DIR}/SKILL.md"; touch -d 2026-11-20T10:00:00Z "${PLUGIN_DIR}/SKILL.md"

T="${W}/fresh.jsonl"; record "${T}" "${SPOKE}" "$(loaded_at "${PLUGIN_DIR}" 2026-11-20T11:00:00Z)"
check "書き換わりより後に読んでいれば黙る" silent "$(hook "${T}" "${REPORT}")"
T="${W}/reread.jsonl"; record "${T}" "${SPOKE}" "$(loaded_at "${PLUGIN_DIR}" 2026-11-20T09:00:00Z)" "$(read_at "${PLUGIN_DIR}/SKILL.md" 2026-11-20T10:30:00Z)"
check "読み直した後は黙る (= 最後の読みで比べる)" silent "$(hook "${T}" "${REPORT}")"
T="${W}/own-edit.jsonl"; record "${T}" "${SPOKE}" "$(loaded_at "${PLUGIN_DIR}" 2026-11-20T09:00:00Z)" \
    "$(edit_at "${PLUGIN_DIR}/SKILL.md" toolu_e1 2026-11-20T09:59:59Z)" "$(result_at toolu_e1 2026-11-20T10:00:01Z)"
check "読んだ後に自分で Edit した書き換えでは止めない" silent "$(hook "${T}" "${REPORT}")"
T="${W}/edit-failed.jsonl"; record "${T}" "${SPOKE}" "$(loaded_at "${PLUGIN_DIR}" 2026-11-20T09:00:00Z)" \
    "$(edit_at "${PLUGIN_DIR}/SKILL.md" toolu_e2 2026-11-20T09:59:59Z)" "$(result_at toolu_e2 2026-11-20T10:00:01Z true)"
check "失敗した Edit は読みに数えない" denies "$(hook "${T}" "${REPORT}")"
T="${W}/edit-only.jsonl"; record "${T}" "${SPOKE}" "$(edit_at "${PLUGIN_DIR}/SKILL.md" toolu_e3 2026-11-20T10:30:00Z)" "$(result_at toolu_e3 2026-11-20T10:30:01Z)"
check "読まずに Edit しただけでは最初の読みに数えない" denies "$(hook "${T}" "${REPORT}")"
T="${W}/no-time.jsonl"; record "${T}" "${SPOKE}" "$(loaded_from "${PLUGIN_DIR}")"
check "時刻の無い読みの行は今の版を読んだと見る" silent "$(hook "${T}" "${REPORT}")"

# その skill 自身の SKILL.md を読む Read は止めない (= 案内が求める読みそのもの)
OPS_FILE="${W}/platform/tools/client/skills/ops/SKILL.md"
check "plugin の skill 自身の SKILL.md を Read する時は止めない" silent "$(hook "${NONE}" "$(tool Read "{\"file_path\":\"${OPS_FILE}\"}")")"
out="$(hook "${NONE}" "$(tool Read "{\"file_path\":\"${W}/platform/tools/client/README.md\"}")")"
check "同じ木の別の file を Read する時は止める" denies "${out}"
check "止める時は読む skill の file を名指す" grep -qF "(${OPS_FILE})" <<< "${out}"
check "その skill の SKILL.md を Edit する時は止める" denies "$(hook "${NONE}" "$(tool Edit "{\"file_path\":\"${OPS_FILE}\"}")")"

# 体の種類 (= subagent_type) で当てる。 省いた呼び出しは general-purpose と見る
check "書ける体は止める" denies "$(hook "${NONE}" "$(tool Agent '{"subagent_type":"general-purpose","prompt":"x"}')")"
check "体の種類を省いた呼び出しも止める" denies "$(hook "${NONE}" "$(tool Agent '{"prompt":"x"}')")"
check "読むだけの体は通る" silent "$(hook "${NONE}" "$(tool Agent '{"subagent_type":"claude-code-guide","prompt":"x"}')")"

check "表が無ければ黙る" silent "$(SKILL_GATE_TABLE="${W}/missing.toml" hook "${NONE}" "$(tool Write "${CODE}")")"
check "読めない入力は黙る" silent "$(printf 'not json' | python3 "${HOOKS}/skill_gate.py")"

# 本物の表は、 書いた skill の SKILL.md が全部在る (= file の無い行はこの agent の skills の下、 在る行はその file)
real_missing="$(python3 - "${HOOKS}" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from skill_gate import PLATFORM, ROOT
from skill_reads import load_rows
from skill_triggers import skill_file
rows = load_rows(Path(sys.argv[1]) / "skill-triggers.base.toml", Path(sys.argv[1]) / "skill-triggers.toml", ROOT, PLATFORM)
print(" ".join(r["name"] for r in rows if not skill_file(r, ROOT, PLATFORM).is_file()))
PY
)"
check "本物の表の skill が全部在る (無い: ${real_missing})" [ -z "${real_missing}" ]

# 機械全体の設定がこの hook を呼ぶので、 別のエージェントの session (= 起動役が別の根を渡す) も来る
OTHER="${W}/other-agent"
mkdir -p "${OTHER}/.tooling/hooks"
other_hook() { printf '{"transcript_path":"%s",%s}' "$1" "$2" | env -u SKILL_GATE_TABLE -u SKILL_GATE_BASE_TABLE AGENT_ROOT="${OTHER}" AGENT_PLATFORM_ROOT="${W}/platform" python3 "${HOOKS}/skill_gate.py"; }
check "表の無い別のエージェントの session では、 この agent の skill を名指さない" silent "$(other_hook "${NONE}" "$(tool Bash '{"command":"tabs send x body.md"}')")"
printf '[[skill]]\nname = "own-skill"\n[[skill.when]]\ntools = ["Bash"]\ncommand = %s\n' "'\\btabs\\s+send\\b'" > "${OTHER}/.tooling/hooks/skill-triggers.toml"
out="$(other_hook "${NONE}" "$(tool Bash '{"command":"tabs send x body.md"}')")"
check "別のエージェントの session は、 そのエージェントの表で止める" names "${out}" own-skill
check "別のエージェントの skill は、 そのエージェントの folder で案内する" bash -c 'grep -q "$2/.claude/skills/own-skill/SKILL.md" <<< "$1"' _ "${out}" "${OTHER}"
check "別のエージェントの session に、 この agent の表の skill を名指さない" bash -c '! grep -q "\`messages\`" <<< "$1"' _ "${out}"

# 型の表 (= skill-triggers.base.toml) の上に派生の表を重ねる
BASE="${W}/base.toml"; OWN="${W}/own.toml"
cat > "${BASE}" <<'TOML'
[[skill]]
name = "code-writing"
[[skill.when]]
tools = ["Bash"]
command = '\bmkdir\b'

[[skill]]
name = "no-such-skill"
[[skill.when]]
tools = ["Bash"]
command = '\bmkdir\b'

[[skill]]
name = "rule-registry"
[[skill.when]]
tools = ["Bash"]
command = '\brmdir\b'
TOML
cat > "${OWN}" <<'TOML'
[[skill]]
name = "code-writing"
[[skill.when]]
tools = ["Bash"]
command = '\btouch\b'

[[skill]]
name = "rule-registry"
off = true
TOML
both() { SKILL_GATE_BASE_TABLE="${BASE}" SKILL_GATE_TABLE="$1" hook "${NONE}" "$2"; }
MKDIR="$(tool Bash '{"command":"mkdir x"}')"
check "型の表の行は、 派生の表が無くても効く" names "$(both "${W}/missing.toml" "${MKDIR}")" code-writing
check "派生に SKILL.md の無い型の行は黙る" bash -c '! grep -q no-such-skill <<< "$1"' _ "$(both "${W}/missing.toml" "${MKDIR}")"
check "派生の表の同じ name の行は、 型の行に条件を足す" names "$(both "${OWN}" "$(tool Bash '{"command":"touch x"}')")" code-writing
check "足した後も型の行の条件は効く" names "$(both "${OWN}" "${MKDIR}")" code-writing
check "派生の off = true は型の行を外す" silent "$(both "${OWN}" "$(tool Bash '{"command":"rmdir x"}')")"
check "off の無い型の行はそのまま効く" names "$(both "${W}/missing.toml" "$(tool Bash '{"command":"rmdir x"}')")" rule-registry

# heredoc の中身 (= 命令が書き込む連絡の本文) の語では当てない
check "heredoc の中身の語では当てない" silent "$(both "${W}/missing.toml" "$(tool Bash '{"command":"cat > m.md <<EOF\nmkdir x\nEOF"}')")"
check "引用符の付いた終わりの印の heredoc も中身を見ない" silent "$(both "${W}/missing.toml" "$(tool Bash '{"command":"cat > m.md <<'"'"'EOF'"'"'\nmkdir x\nEOF\necho done"}')")"
check "heredoc の後に続く命令では当てる" names "$(both "${W}/missing.toml" "$(tool Bash '{"command":"cat > m.md <<EOF\nhello\nEOF\nmkdir x"}')")" code-writing
check "heredoc を開く行の命令では当てる" names "$(both "${W}/missing.toml" "$(tool Bash '{"command":"mkdir x && cat > m.md <<EOF\nhello\nEOF"}')")" code-writing

# 配る型の表そのもので、 派生の表に行が無くても、 子のタブは起動と入れ替えの引き金で子の手順を名指される
CHILD="${W}/child-agent"; CHILD_PLATFORM="${W}/child-platform"
mkdir -p "${CHILD}/.claude/skills/sub-agent" "${CHILD}/.claude/skills/session-end" "${CHILD_PLATFORM}/tools/claude-pwa-client/skills/tabs"
touch "${CHILD}/.claude/skills/sub-agent/SKILL.md" "${CHILD}/.claude/skills/session-end/SKILL.md" "${CHILD_PLATFORM}/tools/claude-pwa-client/skills/tabs/SKILL.md"
shipped() { # <payload の JSON> [env の引数...]
    local payload="$1"; shift
    printf '{%s}' "${payload}" | env "$@" SKILL_GATE_BASE_TABLE="${HOOKS}/skill-triggers.base.toml" SKILL_GATE_TABLE="${W}/missing.toml" \
        AGENT_ROOT="${CHILD}" AGENT_PLATFORM_ROOT="${CHILD_PLATFORM}" python3 "${HOOKS}/skill_gate.py"
}
START='"hook_event_name":"SessionStart","source":"startup"'
CLOSE='"hook_event_name":"UserPromptSubmit","prompt":"Automatic session rollover, sent by the client:\n<session-rollover phase=\"close\">\n</session-rollover>"'
out="$(shipped "${START}" AGENT_CHILD=1)"
check "型の表だけで、 子の起動は子の決まりの skill を名指す" names "${out}" sub-agent
check "型の表だけで、 子の起動は client の tabs の skill を名指す" names "${out}" pwa-client:tabs
check "型の表だけで、 子でない起動は黙る" silent "$(shipped "${START}" -u AGENT_CHILD)"
check "型の表だけで、 子への入れ替えの引き金は子の決まりの skill を名指す" names "$(shipped "${CLOSE}" AGENT_CHILD=1)" sub-agent
check "子でないタブへの入れ替えの引き金は子の決まりを名指さない" bash -c '! grep -q "\`sub-agent\`" <<< "$1"' _ "$(shipped "${CLOSE}" -u AGENT_CHILD)"
for command in 'claude -p q' 'tabs ask ses_x q.txt' 'run --key secrets/bot/anthropic-api-key' 'ANTHROPIC_API_KEY=x run' 'curl https://api.anthropic.com/v1/messages'; do
    check "型の表だけで、 model を呼ぶ命令は API とサブスクの使い分けの skill を名指す: ${command}" names "$(shipped "$(tool Bash "{\"command\":\"${command}\"}")" -u AGENT_CHILD)" sub-agent
done
check "型の表だけで、 model を呼ばない命令は黙る" silent "$(shipped "$(tool Bash '{"command":"claude --version && tabs list"}')" -u AGENT_CHILD)"

echo "test-skill-gate: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
