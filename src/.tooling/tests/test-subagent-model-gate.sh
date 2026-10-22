#!/bin/bash
# test-subagent-model-gate.sh - subagent_model_gate.py lets a subagent start only on Sonnet.
# Feeds made-up Agent tool calls and checks where the hook denies and where it stays silent. One FAIL line per miss.
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/subagent_model_gate.py"
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

expect "sonnet passes" pass "$(run Agent '{"prompt":"x","model":"sonnet"}')"
expect "sonnet with a type passes" pass "$(run Agent '{"prompt":"x","model":"sonnet","subagent_type":"Explore"}')"
expect "no model is the parent's" deny "$(run Agent '{"prompt":"x"}')"
expect "opus is refused" deny "$(run Agent '{"prompt":"x","model":"opus"}')"
expect "a type's own model is not written: refused" deny "$(run Agent '{"prompt":"x","subagent_type":"Plan"}')"
expect "a fork runs on the parent's model" deny "$(run Agent '{"prompt":"x","subagent_type":"fork","model":"sonnet"}')"
expect "the old tool name is held the same" deny "$(run Task '{"prompt":"x","model":"opus"}')"
expect "other tools pass" pass "$(run Bash '{"command":"ls"}')"
expect "a broken payload passes" pass "$(printf 'not json' | python3 "${HOOK}")"
reason="$(run Agent '{"prompt":"x"}')"
printf '%s' "${reason}" | grep -q 'model: \\"sonnet\\"' || { echo "FAIL the reason names the fix: ${reason}"; fails=$((fails + 1)); }

[ "${fails}" -eq 0 ] && echo "test-subagent-model-gate: all passed"
exit "${fails}"
