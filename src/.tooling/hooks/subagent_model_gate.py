#!/usr/bin/env python3
"""Stop a subagent started on any model but Sonnet (a PreToolUse hook on the Agent tool).

The Agent tool hands a subagent the parent's model when `model` is left out, so a subagent started
without one runs on the parent's (Opus). A call is denied unless `model` is `sonnet`; a fork is denied
too, since a fork always runs on the parent's model whatever `model` says. The reason names the fix.

The Workflow tool sets a model per agent() call inside its script, which this hook does not read: the
rule for it is in the sub-agent skill. An unreadable payload passes silently (fail-open).
Called from the agent's Claude Code settings (PreToolUse). Test: .tooling/tests/test-subagent-model-gate.sh
"""
import json
import sys

SUBAGENT_TOOLS = {"Agent", "Task"}
ALLOWED_MODEL = "sonnet"
FORK = "fork"


def refusal(tool_input: dict) -> str | None:
    """Why the call is refused, or None when it starts a subagent on the allowed model."""
    if tool_input.get("subagent_type") == FORK:
        return (f"subagent-model-gate: a fork always runs on the parent's model. Start a fresh subagent "
                f"with model: \"{ALLOWED_MODEL}\" instead (skill sub-agent)")
    model = tool_input.get("model")
    if model != ALLOWED_MODEL:
        given = f"model: \"{model}\"" if model else "no model, which hands it the parent's"
        return (f"subagent-model-gate: a subagent runs on {ALLOWED_MODEL} (this call gives {given}). "
                f"Write model: \"{ALLOWED_MODEL}\" (skill sub-agent)")
    return None


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return 0
    if event.get("tool_name") not in SUBAGENT_TOOLS:
        return 0
    reason = refusal(event.get("tool_input") or {})
    if reason:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "permissionDecision": "deny",
            "permissionDecisionReason": reason}}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
