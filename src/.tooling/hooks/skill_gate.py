#!/usr/bin/env python3
"""Have the agent read a skill the first time its session does what the skill is for (a hook entry).

The trigger table `skill-triggers.toml` says which operation calls for which skill. When an operation matches
skills the session's transcript does not show as read, the hook says so once:
- PreToolUse: the tool is denied with the list of skills to read; the agent reads them and runs the tool again
- UserPromptSubmit / SessionStart: one line of context names the skills to read
A skill already read stays silent for the rest of the session. Only the instruction to read is given, never the
body, so a skill is never loaded twice by this hook.

An unreadable payload, table or transcript passes silently (fail-open).
Called from the agent's Claude Code settings (PreToolUse, UserPromptSubmit, SessionStart).
Test: .tooling/tests/test-skill-gate.sh
"""
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from skill_reads import first_bytes, load_table, read_skills, transcript_of  # noqa: E402
from skill_triggers import is_code, skills_for, target_path  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TABLE = Path(os.environ.get("SKILL_GATE_TABLE", str(Path(__file__).resolve().parent / "skill-triggers.toml")))
SKILLS = ROOT / ".claude/skills"
# Folders, without the trailing slash. The test's own work folder sits under /var/folders, so it narrows this list.
TEMPORARY_ROOTS = tuple(os.environ.get("SKILL_GATE_TEMPORARY_ROOTS",
                                       "/tmp:/private/tmp:/var/folders:/private/var/folders").split(":"))
CONTEXT_EVENTS = {"UserPromptSubmit", "SessionStart"}


def event_of(payload: dict) -> dict:
    """The facts of the payload the table's conditions look at."""
    tool_input = payload.get("tool_input") or {}
    path_text = target_path(tool_input)
    content = tool_input.get("content") or ""
    return {
        "name": payload.get("hook_event_name") or "",
        "tool": payload.get("tool_name") or "",
        "path": path_text,
        "command": tool_input.get("command") or "",
        "cwd": payload.get("cwd") or "",
        "prompt": payload.get("prompt") or "",
        "env": dict(os.environ),
        "root": str(ROOT),
        "is_code": is_code(path_text, first_bytes(path_text), content, TEMPORARY_ROOTS),
    }


def instruction(names: list[str], reason: str) -> str:
    listed = ", ".join(f"`{name}` ({SKILLS / name / 'SKILL.md'})" for name in names)
    return (f"{reason} read the skill(s) {listed} first: call the Skill tool with each name, or Read the file. "
            "This happens once a session per skill; after the read it stays silent.")


def say(event_name: str, names: list[str], tool: str) -> None:
    if event_name in CONTEXT_EVENTS:
        output = {"hookSpecificOutput": {"hookEventName": event_name,
                                         "additionalContext": instruction(names, "[skill-gate] For what this turn asks,")}}
    else:
        output = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                         "permissionDecisionReason": instruction(names, f"Before this {tool} call,")}}
    print(json.dumps(output, ensure_ascii=False))


def main() -> None:
    """Read the payload and speak only about matched skills the transcript does not show as read."""
    try:
        payload = json.load(sys.stdin)
        event = event_of(payload)
        matched = skills_for(load_table(TABLE), event)
        if not matched:
            return
        transcript = transcript_of(payload)
        already = read_skills(transcript, matched) if transcript is not None and transcript.is_file() else set()
        unread = [name for name in matched if name not in already]
        if unread:
            say(event["name"], unread, event["tool"])
    except Exception:  # noqa: BLE001 — an unreadable payload, table or transcript never stops the agent (fail-open)
        return


if __name__ == "__main__":
    main()
