#!/bin/bash
# test-code-writing-gate.sh - code_writing_gate.py stops the first code write of a session until the code-writing skill is read.
# Builds made-up transcripts and checks each case where the hook denies and where it stays silent. One FAIL line per miss.
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/code_writing_gate.py"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
# The work folder sits under /var/folders; narrow the temporary roots so it is not skipped as temporary.
export CODE_WRITING_GATE_TEMPORARY_ROOTS="/scratch-root"
fails=0

SPOKE='{"type":"user","message":{"content":"fix it"}}'
LOADED='{"type":"user","message":{"content":[{"type":"text","text":"Base directory for this skill: /x/.claude/skills/code-writing\n\n# rules"}]}}'
READ='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/.claude/skills/code-writing/SKILL.md"}}]}}'
OTHER_SKILL='{"type":"user","message":{"content":[{"type":"text","text":"Base directory for this skill: /x/.claude/skills/tab-messages"}]}}'
WROTE_SKILL='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/x/.claude/skills/code-writing/SKILL.md"}}]}}'

# record <file> <row>... (one jsonl row per argument)
record() {
    local file="$1"; shift
    printf '%s\n' "$@" > "${file}"
}

# run <tool> <path written> <transcript> [<content>] [<agent_id>]
run() {
    printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s","content":"%s"},"transcript_path":"%s"%s}' \
        "$1" "$2" "${4:-}" "$3" "${5:+,\"agent_id\":\"$5\"}" | python3 "${HOOK}"
}

# expect <case> <deny|pass> <output>
expect() {
    local said="pass"
    printf '%s' "$3" | grep -q '"permissionDecision": "deny"' && said="deny"
    [ "${said}" = "$2" ] || { echo "FAIL $1: want=$2 got=${said} out=$3"; fails=$((fails + 1)); }
}

CODE="${WORK}/repo/tool.py"
NOT_READ="${WORK}/not-read.jsonl"; record "${NOT_READ}" "${SPOKE}" "${OTHER_SKILL}" "${WROTE_SKILL}"
LOADED_T="${WORK}/loaded.jsonl"; record "${LOADED_T}" "${SPOKE}" "${LOADED}"
READ_T="${WORK}/read.jsonl"; record "${READ_T}" "${SPOKE}" "${READ}"

# Deny: a code file in a session that has not read the skill (another skill read, or the skill file only written, does not count)
expect "Write before the read" deny "$(run Write "${CODE}" "${NOT_READ}")"
expect "Edit before the read" deny "$(run Edit "${WORK}/repo/app.tsx" "${NOT_READ}")"
expect "script without a suffix" deny "$(run Write "${WORK}/repo/bin/tool" "${NOT_READ}" '#!/bin/bash')"
mkdir -p "${WORK}/repo/bin"; printf '#!/usr/bin/env python3\n' > "${WORK}/repo/bin/existing"
expect "Edit of a file whose first line is #!" deny "$(run Edit "${WORK}/repo/bin/existing" "${NOT_READ}")"

# Pass: the transcript shows the read (the loaded skill body, or a Read of SKILL.md)
expect "after the skill was loaded" pass "$(run Write "${CODE}" "${LOADED_T}")"
expect "after SKILL.md was Read" pass "$(run Edit "${CODE}" "${READ_T}")"

# Pass: not code, temporary, or a tool that does not write
expect "markdown file" pass "$(run Write "${WORK}/repo/README.md" "${NOT_READ}")"
expect "document without a suffix" pass "$(run Write "${WORK}/repo/NOTES" "${NOT_READ}" 'notes')"
expect "temporary root" pass "$(run Write "/scratch-root/tool.py" "${NOT_READ}")"
expect "Read tool" pass "$(run Read "${CODE}" "${NOT_READ}")"

# Subagent: its own transcript decides (a parent's read does not cover it, and its own read is enough)
mkdir -p "${WORK}/loaded/subagents"
record "${WORK}/loaded/subagents/agent-a1.jsonl" "${SPOKE}"
expect "subagent that has not read" deny "$(run Write "${CODE}" "${LOADED_T}" '' a1)"
mkdir -p "${WORK}/not-read/subagents"
record "${WORK}/not-read/subagents/agent-a2.jsonl" "${SPOKE}" "${LOADED}"
expect "subagent that has read (parent has not)" pass "$(run Write "${CODE}" "${NOT_READ}" '' a2)"

# Silent: unreadable payload, missing transcript (fail-open)
out="$(printf 'not json' | python3 "${HOOK}" 2>&1)"; code=$?
{ [ -z "${out}" ] && [ "${code}" -eq 0 ]; } || { echo "FAIL not JSON: out=${out} code=${code}"; fails=$((fails + 1)); }
out="$(run Write "${CODE}" "${WORK}/missing.jsonl" 2>&1)"; code=$?
{ [ -z "${out}" ] && [ "${code}" -eq 0 ]; } || { echo "FAIL missing transcript: out=${out} code=${code}"; fails=$((fails + 1)); }

[ "${fails}" -eq 0 ] && echo "test-code-writing-gate: ok" || exit 1
