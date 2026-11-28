#!/usr/bin/env python3
"""Have the agent read a skill the first time its session does what the skill is for (a hook entry).

The trigger tables say which operation calls for which skill: `skill-triggers.base.toml`, which the agent
template ships for the skills it ships, under the agent's own `skill-triggers.toml` (rules in `skill_triggers.py`). When an operation matches
skills the session's transcript does not show as read, the hook adds one line of context naming the skills to read.
The tool runs as the agent wrote it: denying it would make the agent write the same call a second time.
A skill already read stays silent for the rest of the session, until its SKILL.md is written after that read (another
tab changed the rule, or a pull brought a new version). Then the next matching operation shows what changed since that
read (the file's git diff from the commit it had then), so a long session does not keep working by a rule that has
since changed and does not read the whole file again; only when no such diff can be made, or it is too long, does it
ask for the whole file once more. Apart from those diffs only the instruction to read is given, never the body. The instruction names each skill's SKILL.md: the agent's own
`.claude/skills/<name>/SKILL.md`, or the `file` the table gives (a plugin's skill). A Read of that very file
never stops for that skill: it is the read the gate asks for.

The settings of every account on the machine name this one copy of the hook, so a session of another agent reaches
it too. The agent is the one its launcher names in `AGENT_ROOT`, and its own table and skills are used: a session
of another agent never hears about this agent's skills, and an agent without tables hears nothing.

An unreadable payload, table or transcript passes silently (fail-open).
Called from the agent's Claude Code settings (PreToolUse, UserPromptSubmit, SessionStart).
Test: .tooling/tests/test-skill-gate.sh
"""
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from skill_reads import DIFF_MARK, READING_TOOLS, changed_since, first_bytes, load_rows, read_times, transcript_of  # noqa: E402
from skill_triggers import is_code, makes_code_place, skill_file, skills_for, target_path  # noqa: E402

ROOT = Path(os.environ.get("AGENT_ROOT") or Path(__file__).resolve().parents[2]).resolve()
TABLE = Path(os.environ.get("SKILL_GATE_TABLE") or ROOT / ".tooling/hooks/skill-triggers.toml")
BASE_TABLE = Path(os.environ.get("SKILL_GATE_BASE_TABLE") or ROOT / ".tooling/hooks/skill-triggers.base.toml")
PLATFORM = Path(os.environ.get("AGENT_PLATFORM_ROOT") or Path.home() / "agent-platform")
# Folders, without the trailing slash. The test's own work folder sits under /var/folders, so it narrows this list.
TEMPORARY_ROOTS = tuple(os.environ.get("SKILL_GATE_TEMPORARY_ROOTS",
                                       "/tmp:/private/tmp:/var/folders:/private/var/folders").split(":"))
#: A diff longer than this asks for the whole file instead (reading it is shorter than reading the change)
DIFF_MAX_CHARS = 6000
#: The tags Claude Code puts around a long typed text (the same pattern `lib/operator_words.py` takes off)
PASTED_TAG = re.compile(r"</?pasted_content[^>\n]*>\n?")


def own_prompt(prompt: str) -> str:
    """The prompt the session's own operator gave, or nothing when it is a note another tab sent.

    The client relays a note as an opening line followed by an `<agent-message …>` envelope. Words inside another
    tab's note say what that tab is doing, not what this session is about to do, so they call for no skill.
    Claude Code hands a long typed text over inside `<pasted_content …>` tags, after blank lines; the tags and the
    leading blank lines are taken off first, so the note's opening line (and the openings the table's rows look for)
    is at the start again.
    """
    prompt = PASTED_TAG.sub("", prompt).lstrip()
    lines = prompt.split("\n", 2)
    return "" if len(lines) > 1 and lines[1].startswith("<agent-message") else prompt


def event_of(payload: dict) -> dict:
    """The facts of the payload the table's conditions look at."""
    tool_input = payload.get("tool_input") or {}
    path_text = target_path(tool_input)
    content = tool_input.get("content") or ""
    command = tool_input.get("command") or ""
    cwd = payload.get("cwd") or ""
    return {
        "name": payload.get("hook_event_name") or "",
        "tool": payload.get("tool_name") or "",
        "path": path_text,
        "command": command,
        "cwd": cwd,
        "subagent": tool_input.get("subagent_type") or "general-purpose",
        "prompt": own_prompt(payload.get("prompt") or ""),
        "env": dict(os.environ),
        "root": str(ROOT),
        "is_code": is_code(path_text, first_bytes(path_text), content, TEMPORARY_ROOTS),
        "makes_code_place": makes_code_place(command, cwd, dict(os.environ), TEMPORARY_ROOTS),
    }


def is_own_file_read(event: dict, file: Path) -> bool:
    """Whether the call is a Read of the skill's own SKILL.md (the very read the gate asks for)."""
    return event["tool"] in READING_TOOLS and event["path"] == str(file)


def diff_since(file: Path, read_time: float | None) -> str | None:
    """What changed in the file since the read, as a git diff from the commit it had then (an empty text when nothing
    did), or `None` when no such diff can be made (no time, no repository, no commit before the read, too long)."""
    import subprocess  # noqa: PLC0415
    if read_time is None:
        return None
    folder, name = str(file.parent), file.name
    base = subprocess.run(["git", "-C", folder, "log", "-1", f"--before=@{int(read_time)}", "--format=%H", "--", name],
                          capture_output=True, text=True, check=False).stdout.strip()
    if not base:
        return None
    done = subprocess.run(["git", "-C", folder, "diff", "--no-color", "--unified=1", base, "--", name],
                          capture_output=True, text=True, check=False)
    if done.returncode != 0 or len(done.stdout) > DIFF_MAX_CHARS:
        return None
    return "\n".join(line for line in done.stdout.splitlines() if line[:1] in "+-@ " and not line.startswith(("+++", "---")))


def diff_note(name: str, file: Path, diff: str) -> str:
    """The context that shows a changed skill's diff; its mark makes it count as reading that version."""
    if not diff:
        return f"{DIFF_MARK} `{name}` ({file}) since this session read it: none in its text."
    return f"{DIFF_MARK} `{name}` ({file}) since this session read it (read these instead of the whole file):\n{diff}"


def instruction(files: dict[str, Path], changed: set[str], reason: str) -> str:
    listed = ", ".join(f"`{name}` ({file}{', changed since this session read it' if name in changed else ''})"
                       for name, file in files.items())
    return (f"{reason} read the skill(s) {listed} first: call the Skill tool with each name, or Read the file. "
            "After the read it stays silent until the SKILL.md changes again.")


def say(event_name: str, notes: list[str], files: dict[str, Path], changed: set[str], tool: str) -> None:
    """Print the hook's one context: the diffs of changed skills, then the instruction for the skills still to read."""
    texts = list(notes)
    if files:
        reason = "[skill-gate] For what this turn asks," if event_name != "PreToolUse" else \
            f"[skill-gate] This {tool} call ran as written. Before the next step,"
        texts.append(instruction(files, changed, reason))
    output = {"hookSpecificOutput": {"hookEventName": event_name or "PreToolUse", "additionalContext": "\n\n".join(texts)}}
    print(json.dumps(output, ensure_ascii=False))


def main() -> None:
    """Read the payload and speak only about matched skills the transcript does not show as read, or whose SKILL.md
    changed after the last read."""
    try:
        payload = json.load(sys.stdin)
        event = event_of(payload)
        table = load_rows(BASE_TABLE, TABLE, ROOT, PLATFORM)
        matched = skills_for(table, event)
        if not matched:
            return
        rows = {row["name"]: row for row in table if row["name"] in matched}
        files = {name: skill_file(row, ROOT, PLATFORM) for name, row in rows.items()}
        declared = {name: files[name] for name, row in rows.items() if "file" in row}
        transcript = transcript_of(payload)
        reads = read_times(transcript, matched, declared) if transcript is not None and transcript.is_file() else {}
        changed = {name for name, read_time in reads.items() if changed_since(files[name], read_time)}
        unread = {name: file for name, file in files.items()
                  if (name not in reads or name in changed) and not is_own_file_read(event, file)}
        notes = []
        for name in [name for name in unread if name in changed]:
            diff = diff_since(unread[name], reads[name])
            if diff is not None:
                notes.append(diff_note(name, unread.pop(name), diff))
        if notes or unread:
            say(event["name"], notes, unread, changed, event["tool"])
    except Exception:  # noqa: BLE001 — an unreadable payload, table or transcript never stops the agent (fail-open)
        return


if __name__ == "__main__":
    main()
