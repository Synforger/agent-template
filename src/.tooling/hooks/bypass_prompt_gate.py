#!/usr/bin/env python3
"""Refuse a Bash prompt that would wait for the operator in a session that skips prompts (a PermissionRequest hook).

With every check off (`bypassPermissions`), Claude Code still stops to ask about a few commands, such as an
`rm` whose target it cannot resolve before the run (a glob under a variable, a relative glob after `cd`, a
target ending in `/*/`). Nobody watches those prompts, so the tab sits until the operator answers. This hook
answers them at once with a refusal whose message says how to rewrite the command, so Claude rewrites it and
goes on. Which commands prompt stays Claude Code's own judgement: the hook runs only when it was about to ask.

Other modes, where a prompt is the operator's to answer, and other tools pass silently. An unreadable payload
passes silently too (fail-open: the prompt then shows as before).
Called from the agent's Claude Code settings (PermissionRequest, matcher Bash). Test: .tooling/tests/test-bypass-prompt-gate.sh
"""
import json
import re
import sys

BYPASS_MODE = "bypassPermissions"
GATED_TOOLS = {"Bash"}
REMOVAL = re.compile(r"(^|[\s;&|(`])(rm|rmdir)\s")

PREFIX = ("bypass-prompt-gate: this session skips permission prompts, yet Claude Code stopped to ask about "
          "this command, so it would wait for the operator. It was refused instead: rewrite it and run it again. ")
REMOVAL_FIX = ("Claude Code asks when it cannot tell before the run what an rm or rmdir reaches. Name every target "
               "as a literal absolute path; guard a variable as \"${DIR:?}\"/* instead of $DIR/*; write the absolute "
               "path instead of cd before a relative glob; leave out a trailing /*/; run a $(...) substitution on "
               "its own first and remove the literal paths it prints.")
OTHER_FIX = ("Split it into single commands, write absolute paths instead of cd, and run each part on its own.")


def refusal(command: str) -> str:
    """The message that tells Claude how to rewrite the refused command."""
    return PREFIX + (REMOVAL_FIX if REMOVAL.search(command) else OTHER_FIX)


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return 0
    if event.get("permission_mode") != BYPASS_MODE or event.get("tool_name") not in GATED_TOOLS:
        return 0
    command = (event.get("tool_input") or {}).get("command") or ""
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PermissionRequest",
        "decision": {"behavior": "deny", "message": refusal(command)}}}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
