#!/usr/bin/env python3
"""Have the agent read a skill the first time its session does what the skill is for (a hook entry).

The trigger table `skill-triggers.toml` says which operation calls for which skill. When an operation matches
skills the session's transcript does not show as read, the hook says so once:
- PreToolUse: the tool is denied with the list of skills to read; the agent reads them and runs the tool again
- UserPromptSubmit / SessionStart: one line of context names the skills to read
A skill already read stays silent for the rest of the session. Only the instruction to read is given, never the
body, so a skill is never loaded twice by this hook. The instruction names each skill's SKILL.md: the agent's own
`.claude/skills/<name>/SKILL.md`, or the `file` the table gives (a plugin's skill). A Read of that very file
never stops for that skill: it is the read the gate asks for.

An unreadable payload, table or transcript passes silently (fail-open).
Called from the agent's Claude Code settings (PreToolUse, UserPromptSubmit, SessionStart).
Test: .tooling/tests/test-skill-gate.sh
"""
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from skill_reads import READING_TOOLS, first_bytes, load_table, read_skills, transcript_of  # noqa: E402
from skill_triggers import is_code, skill_file, skills_for, target_path  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TABLE = Path(os.environ.get("SKILL_GATE_TABLE", str(Path(__file__).resolve().parent / "skill-triggers.toml")))
PLATFORM = Path(os.environ.get("AGENT_PLATFORM_ROOT") or Path.home() / "agent-platform")
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


def is_own_file_read(event: dict, file: Path) -> bool:
    """Whether the call is a Read of the skill's own SKILL.md (the very read the gate asks for)."""
    return event["tool"] in READING_TOOLS and event["path"] == str(file)


def instruction(files: dict[str, Path], reason: str) -> str:
    listed = ", ".join(f"`{name}` ({file})" for name, file in files.items())
    return (f"{reason} read the skill(s) {listed} first: call the Skill tool with each name, or Read the file. "
            "This happens once a session per skill; after the read it stays silent.")


def say(event_name: str, files: dict[str, Path], tool: str) -> None:
    if event_name in CONTEXT_EVENTS:
        output = {"hookSpecificOutput": {"hookEventName": event_name,
                                         "additionalContext": instruction(files, "[skill-gate] For what this turn asks,")}}
    else:
        output = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                         "permissionDecisionReason": instruction(files, f"Before this {tool} call,")}}
    print(json.dumps(output, ensure_ascii=False))


def main() -> None:
    """Read the payload and speak only about matched skills the transcript does not show as read."""
    try:
        payload = json.load(sys.stdin)
        event = event_of(payload)
        table = load_table(TABLE)
        matched = skills_for(table, event)
        if not matched:
            return
        rows = {row["name"]: row for row in table if row["name"] in matched}
        files = {name: skill_file(row, ROOT, PLATFORM) for name, row in rows.items()}
        declared = {name: files[name] for name, row in rows.items() if "file" in row}
        transcript = transcript_of(payload)
        already = read_skills(transcript, matched, declared) if transcript is not None and transcript.is_file() else set()
        unread = {name: file for name, file in files.items()
                  if name not in already and not is_own_file_read(event, file)}
        if unread:
            say(event["name"], unread, event["tool"])
    except Exception:  # noqa: BLE001 — an unreadable payload, table or transcript never stops the agent (fail-open)
        return


if __name__ == "__main__":
    main()
