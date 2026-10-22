"""Read the trigger table, and find which skills a session's transcript shows were read.

Read means: the body the harness injects when a skill is loaded (`Base directory for this skill: .../<name>`),
or a Read tool call on `.claude/skills/<name>/SKILL.md`. A Bash command that only names the file (an edit, a
search) is not a read. Called by `skill_gate.py`.
"""
import json
import re
import tomllib
from pathlib import Path

LOADED_MARK = "Base directory for this skill:"
READING_TOOLS = {"Read"}


def load_table(path: Path) -> list[dict]:
    """The `[[skill]]` rows of the trigger table, or an empty list when the file is missing."""
    if not path.is_file():
        return []
    return tomllib.loads(path.read_text(encoding="utf-8")).get("skill", [])


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


def read_skills(transcript: Path, names: list[str]) -> set[str]:
    """Which of the named skills the transcript shows were read."""
    raw = transcript.read_text(encoding="utf-8", errors="replace")
    wanted = [name for name in names if name in raw]
    loaded = {name: re.compile(re.escape(LOADED_MARK) + r"[^\n\"]*/" + re.escape(name) + r"(?![\w-])")
              for name in wanted}
    found: set[str] = set()
    for line in raw.splitlines():
        candidates = [name for name in wanted if name not in found and name in line]
        if not candidates:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        content = (row.get("message") or {}).get("content")
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        for block in content or []:
            if not isinstance(block, dict):
                continue
            text = json.dumps(block, ensure_ascii=False)
            arguments = json.dumps(block.get("input") or {}, ensure_ascii=False)
            for name in candidates:
                if row.get("type") == "user" and loaded[name].search(text):
                    found.add(name)
                elif block.get("type") == "tool_use" and block.get("name") in READING_TOOLS \
                        and f"skills/{name}/SKILL.md" in arguments:
                    found.add(name)
    return found


def first_bytes(path_text: str) -> bytes:
    """The first two bytes of a file (to tell a script without a suffix), or nothing."""
    try:
        with Path(path_text).open("rb") as handle:
            return handle.read(2)
    except OSError:
        return b""
