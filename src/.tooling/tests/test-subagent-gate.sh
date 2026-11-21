#!/bin/bash
# test-subagent-gate.sh - subagent_gate.py refuses every subagent and workflow, and names the child tab instead.
# Feeds made-up tool calls and checks where the hook denies and where it stays silent. One FAIL line per miss.
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/subagent_gate.py"
fails=0

# run <tool> <tool_input json>
run() {
    printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' "$1" "$2" | python3 "${HOOK}"
}

# expect <case> <deny|pass> <output>
expect() {
    local said="pass"
    printf '%s' "$3" | grep -q '"permissionDecision": "deny"' && said="deny"
    [ "${said}" = "$2" ] || { echo "FAIL $1: want=$2 got=${said} out=$3"; fails=$((fails + 1)); }
}

expect "a sonnet subagent is refused" deny "$(run Agent '{"prompt":"x","model":"sonnet"}')"
expect "a reading subagent is refused" deny "$(run Agent '{"prompt":"x","model":"haiku","subagent_type":"Explore"}')"
expect "a fork is refused" deny "$(run Agent '{"prompt":"x","subagent_type":"fork"}')"
expect "the old tool name is refused" deny "$(run Task '{"prompt":"x"}')"
expect "a workflow is refused" deny "$(run Workflow '{"script":"export const meta = {}"}')"
expect "other tools pass" pass "$(run Bash '{"command":"tabs new x y"}')"
expect "a broken payload passes" pass "$(printf 'not json' | python3 "${HOOK}")"
reason="$(run Agent '{"prompt":"x"}')"
printf '%s' "${reason}" | grep -q 'tabs new' || { echo "FAIL the reason names the child tab: ${reason}"; fails=$((fails + 1)); }

[ "${fails}" -eq 0 ] && echo "test-subagent-gate: all passed"
exit "${fails}"
