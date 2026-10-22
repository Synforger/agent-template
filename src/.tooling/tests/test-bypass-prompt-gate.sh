#!/bin/bash
# test-bypass-prompt-gate.sh - bypass_prompt_gate.py refuses a Bash prompt only in a session that skips prompts.
# Feeds made-up PermissionRequest payloads and checks where the hook denies and where it stays silent. One FAIL line per miss.
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/bypass_prompt_gate.py"
fails=0

# run <mode> <tool> <tool_input json>
run() {
    printf '{"hook_event_name":"PermissionRequest","permission_mode":"%s","tool_name":"%s","tool_input":%s}' "$1" "$2" "$3" | python3 "${HOOK}"
}

# expect <case> <deny|pass> <output>
expect() {
    local said="pass"
    printf '%s' "$3" | grep -q '"behavior": "deny"' && said="deny"
    [ "${said}" = "$2" ] || { echo "FAIL $1: want=$2 got=${said} out=$3"; fails=$((fails + 1)); }
}

expect "a glob under a variable is refused" deny "$(run bypassPermissions Bash '{"command":"rm -f \"$D\"/*"}')"
expect "a relative glob after cd is refused" deny "$(run bypassPermissions Bash '{"command":"cd sub && rm -rf a/*"}')"
expect "any other bash prompt is refused" deny "$(run bypassPermissions Bash '{"command":"cd /x && git status"}')"
expect "manual mode keeps the prompt" pass "$(run default Bash '{"command":"rm -f \"$D\"/*"}')"
expect "auto mode keeps the prompt" pass "$(run auto Bash '{"command":"rm -f \"$D\"/*"}')"
expect "a question to the operator keeps its prompt" pass "$(run bypassPermissions AskUserQuestion '{"questions":[]}')"
expect "an MCP tool keeps its prompt" pass "$(run bypassPermissions mcp__x__send '{}')"
expect "a broken payload passes" pass "$(printf 'not json' | python3 "${HOOK}")"

removal="$(run bypassPermissions Bash '{"command":"cd sub && rm -rf a/*"}')"
printf '%s' "${removal}" | grep -q 'DIR:?' || { echo "FAIL an rm refusal names the guard: ${removal}"; fails=$((fails + 1)); }
other="$(run bypassPermissions Bash '{"command":"cd /x && git status"}')"
printf '%s' "${other}" | grep -q 'absolute paths' || { echo "FAIL another refusal names the fix: ${other}"; fails=$((fails + 1)); }
printf '%s' "${other}" | grep -q 'DIR:?' && { echo "FAIL a refusal without rm leaves out the rm fix: ${other}"; fails=$((fails + 1)); }
glued="$(run bypassPermissions Bash '{"command":"echo farm rmx"}')"
printf '%s' "${glued}" | grep -q 'DIR:?' && { echo "FAIL rm inside a word is not a removal: ${glued}"; fails=$((fails + 1)); }

[ "${fails}" -eq 0 ] && echo "test-bypass-prompt-gate: all passed"
exit "${fails}"
