#!/usr/bin/env python3
"""Refuse every subagent: the Agent tool (and its old name Task) and the Workflow tool (a PreToolUse hook).

Another body for a piece of work is a child tab (`tabs new`, skill sub-agent): the operator sees it in the list and can
speak to it, it rolls over with its own conversation, it outlives the parent's conversation, and `tabs capacity` tells
how many more the machine holds. A subagent has none of that and runs out of sight, so the call is denied and the reason
names the child tab. Work small enough for a subagent is read by the agent itself.

An unreadable payload passes silently (fail-open).
Called from the agent's Claude Code settings (PreToolUse). Test: .tooling/tests/test-subagent-gate.sh
"""
import json
import sys

SUBAGENT_TOOLS = {"Agent", "Task", "Workflow"}
REASON = ("subagent-gate: subagents and workflows are not used. Read it yourself, or hand the work to a child tab "
          "(`tabs capacity`, then `tabs new <title> <task file>`; skill sub-agent)")


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return 0
    if event.get("tool_name") not in SUBAGENT_TOOLS:
        return 0
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": REASON}}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
