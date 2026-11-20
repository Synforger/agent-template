"""Read the trigger tables, and find which skills a session's transcript shows were read.

Read means: the body the harness injects when a skill is loaded (`Base directory for this skill: <folder>`),
or a Read tool call on the skill's SKILL.md. A skill the table gives a `file` is found by that file: its folder
after the mark, or its path in the Read call. Any other skill is found by its name: `.../<name>` after the mark,
or `skills/<name>/SKILL.md` in the Read call. A Bash command that only names the file (an edit, a search) is not
a read. Each read keeps the time of its transcript row, so the gate can ask again when the SKILL.md changed after
it; an Edit or Write the session itself made to that file, after a read, counts as reading the version it wrote.
Called by `skill_gate.py`.
"""
import json
import re
import tomllib
from datetime import datetime
from pathlib import Path

from skill_triggers import merged, skill_file

LOADED_MARK = "Base directory for this skill:"
READING_TOOLS = {"Read"}
WRITING_TOOLS = {"Edit", "MultiEdit", "Write"}


def load_table(path: Path) -> list[dict]:
    """The `[[skill]]` rows of the trigger table, or an empty list when the file is missing."""
    if not path.is_file():
        return []
    return tomllib.loads(path.read_text(encoding="utf-8")).get("skill", [])


def load_rows(base: Path, own: Path, root: Path, platform: Path) -> list[dict]:
    """The rows the gate uses: the base table laid under the agent's own, keeping a base row only when the agent
    has that skill's SKILL.md (an agent the template made without a skill hears nothing about it)."""
    rows = merged(load_table(base), load_table(own))
    return [row for row in rows if not row["from_base"] or skill_file(row, root, platform).is_file()]


def transcript_of(payload: dict) -> Path | None:
    """The transcript to search: the subagent's own one when a subagent calls the tool."""
    main = payload.get("transcript_path")
    if not main:
        return None
    main_path = Path(main)
    agent_id = payload.get("agent_id")
    if agent_id:
        own = main_path.with_suffix("") / "subagents" / f"agent-{agent_id}.jsonl"
        if own.is_file():
            return own
    return main_path


def read_times(transcript: Path, names: list[str], files: dict[str, Path] | None = None) -> dict[str, float | None]:
    """When each of the named skills was last read in the transcript, as epoch seconds (`None` for a read whose row
    carries no time); a skill never read is left out. `files` maps a name to its SKILL.md when the table gives one."""
    files = files or {}
    raw = transcript.read_text(encoding="utf-8", errors="replace")
    needles = {name: str(files[name].parent) if name in files else name for name in names}
    wanted = [name for name in names if needles[name] in raw]
    loaded = {name: _loaded_pattern(name, files.get(name)) for name in wanted}
    times: dict[str, float | None] = {}
    writes: dict[str, str] = {}
    for line in raw.splitlines():
        candidates = [name for name in wanted if needles[name] in line]
        pending = [tool_id for tool_id in writes if tool_id in line]
        if not candidates and not pending:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        when = _row_time(row)
        content = (row.get("message") or {}).get("content")
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        for block in content or []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_result" and block.get("tool_use_id") in writes:
                name = writes.pop(block["tool_use_id"])
                if name in times and not block.get("is_error"):
                    _note_read(times, name, when)
                continue
            text = json.dumps(block, ensure_ascii=False)
            arguments = json.dumps(block.get("input") or {}, ensure_ascii=False)
            for name in candidates:
                if row.get("type") == "user" and loaded[name].search(text):
                    _note_read(times, name, when)
                elif block.get("type") == "tool_use" and block.get("name") in READING_TOOLS \
                        and _read_path(name, files.get(name)) in arguments:
                    _note_read(times, name, when)
                elif block.get("type") == "tool_use" and block.get("name") in WRITING_TOOLS and block.get("id") \
                        and _read_path(name, files.get(name)) in arguments:
                    writes[block["id"]] = name
    return times


def changed_since(file: Path, read_time: float | None) -> bool:
    """Whether the file was written after the read (a read with no time, or a file that cannot be stat'ed, is
    taken as current, so the gate stays silent rather than asking on a guess)."""
    if read_time is None:
        return False
    try:
        return file.stat().st_mtime > read_time
    except OSError:
        return False


def _row_time(row: dict) -> float | None:
    """The time a transcript row was written, as epoch seconds, or `None` when it has none."""
    try:
        return datetime.fromisoformat(row["timestamp"]).timestamp()
    except (KeyError, TypeError, ValueError):
        return None


def _note_read(times: dict[str, float | None], name: str, when: float | None) -> None:
    """Keep the later of the skill's read times, where `None` (a read of unknown time) wins: it may be the newest."""
    if name not in times:
        times[name] = when
    elif times[name] is not None:
        times[name] = None if when is None else max(times[name], when)


def _loaded_pattern(name: str, file: Path | None) -> re.Pattern[str]:
    """The mark the harness writes when it loads the skill: its folder, or any folder ending in its name.

    The name must be the folder's last part: a plugin's skill folder such as `.../tools/<name>/skills/tabs` only
    passes through it. The block is searched as JSON text, where the line break after the folder is the two characters
    `\\n`, so the folder ends at a backslash, a quote or a line break."""
    if file is None:
        return re.compile(re.escape(LOADED_MARK) + r"[^\n\"\\]*/" + re.escape(name) + r"(?![\w/.-])")
    return re.compile(re.escape(LOADED_MARK) + r"\s*" + re.escape(str(file.parent)) + r"(?![\w/.-])")


def _read_path(name: str, file: Path | None) -> str:
    """What a Read call's arguments must hold to count as reading the skill."""
    return f"skills/{name}/SKILL.md" if file is None else str(file)


def first_bytes(path_text: str) -> bytes:
    """The first two bytes of a file (to tell a script without a suffix), or nothing."""
    try:
        with Path(path_text).open("rb") as handle:
            return handle.read(2)
    except OSError:
        return b""
