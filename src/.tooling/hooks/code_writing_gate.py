#!/usr/bin/env python3
"""Have the agent read the code-writing skill before its first code write (a PreToolUse hook).

When Write / Edit / MultiEdit / NotebookEdit targets a code file (told by its suffix, or by `#!` on the
first line), the tool is denied unless the transcript of that session (a subagent's own transcript for a
subagent) shows the skill `code-writing` was read. Once it was read the hook stays silent, so it stops at
most once a session.

Read means: the body the harness injects when the skill is loaded (`Base directory for this skill:
.../code-writing`), or a Read / Bash tool call naming the skill's SKILL.md. Files under the temporary
roots are not kept code and pass. Files written by a Bash heredoc are outside this hook (the tool name does
not tell them apart).

An unreadable payload or a missing transcript passes silently (fail-open): a write is stopped only when
the transcript says the skill was not read.
Called from the agent's Claude Code settings (PreToolUse). Test: .tooling/tests/test-code-writing-gate.sh
"""
import json
import os
import sys
from pathlib import Path

SKILL_NAME = "code-writing"
SKILL_FILE = Path(__file__).resolve().parents[2] / ".claude/skills" / SKILL_NAME / "SKILL.md"
SKILL_MARK = f"{SKILL_NAME}/SKILL.md"
LOADED_MARK = "Base directory for this skill:"
WRITING_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
CODE_SUFFIXES = {
    ".py", ".sh", ".bash", ".zsh", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".swift", ".go",
    ".rs", ".rb", ".kt", ".java", ".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".lua", ".ipynb",
}
# Folders, without the trailing slash. The test's own work folder sits under /var/folders, so it narrows this list.
TEMPORARY_ROOTS = tuple(os.environ.get("CODE_WRITING_GATE_TEMPORARY_ROOTS",
                                       "/tmp:/private/tmp:/var/folders:/private/var/folders").split(":"))


def target_path(tool_input: dict) -> str:
    """The path the tool writes, or an empty string."""
    return tool_input.get("file_path") or tool_input.get("notebook_path") or ""


def starts_with_shebang(path: Path, new_content: str) -> bool:
    """Whether a file without a suffix is a script (the new content or the current first line is `#!`)."""
    if new_content.startswith("#!"):
        return True
    try:
        with path.open("rb") as handle:
            return handle.read(2) == b"#!"
    except OSError:
        return False


def is_temporary(path_text: str) -> bool:
    """Whether the path is one of the temporary roots or inside one."""
    return any(path_text == root or path_text.startswith(root + "/") for root in TEMPORARY_ROOTS)


def is_code(path_text: str, new_content: str) -> bool:
    """Whether the write targets a code file this hook guards."""
    if not path_text or is_temporary(path_text):
        return False
    path = Path(path_text)
    if path.suffix:
        return path.suffix.lower() in CODE_SUFFIXES
    return starts_with_shebang(path, new_content)


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


def has_read_skill(transcript: Path) -> bool:
    """Whether the transcript shows the skill was read."""
    raw = transcript.read_bytes()
    if SKILL_NAME.encode() not in raw:
        return False
    for line in raw.decode("utf-8", "replace").splitlines():
        if SKILL_NAME not in line:
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
            if row.get("type") == "user" and LOADED_MARK in text and f"/{SKILL_NAME}" in text:
                return True
            if block.get("type") == "tool_use" and block.get("name") in {"Read", "Bash"} \
                    and SKILL_MARK in json.dumps(block.get("input") or {}, ensure_ascii=False):
                return True
    return False


def deny(path_text: str) -> None:
    """Deny the tool and say what to read."""
    reason = (f"Before writing the code file {path_text}, read the code-writing rules: call the Skill tool "
              f"with `{SKILL_NAME}`, or Read {SKILL_FILE}. This happens once a session; after the read, "
              "writes pass. A brief handed to a child tab or a subagent carries that file's path and version.")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "deny",
                                             "permissionDecisionReason": reason}}))


def main() -> None:
    """Read the payload and deny only when the transcript shows the skill was not read."""
    try:
        payload = json.load(sys.stdin)
        if payload.get("tool_name") not in WRITING_TOOLS:
            return
        tool_input = payload.get("tool_input") or {}
        path_text = target_path(tool_input)
        if not is_code(path_text, tool_input.get("content") or ""):
            return
        transcript = transcript_of(payload)
        if transcript is None or not transcript.is_file():
            return
        if not has_read_skill(transcript):
            deny(path_text)
    except Exception:  # noqa: BLE001 — an unreadable payload or transcript never stops a write (fail-open)
        return


if __name__ == "__main__":
    main()
