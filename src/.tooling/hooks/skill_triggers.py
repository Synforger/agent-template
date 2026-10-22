"""Which skills an event calls for, by the trigger table (pure: no file, state or command is touched).

The table (`skill-triggers.toml`, read by `skill_reads.py`) lists one skill per `[[skill]]` with one or more
`[[skill.when]]`. A `when` matches when every condition it writes holds:

- `event`   the hook event (default `PreToolUse`; also `UserPromptSubmit`, `SessionStart`)
- `tools`   tool names; a name ending in `*` matches by prefix
- `path`    a regular expression searched in the path the tool reads or writes
- `command` a regular expression searched in a Bash command
- `cwd`     a regular expression searched in the session's working folder
- `prompt`  a regular expression searched in the operator's message
- `env`     `NAME=value` pairs that the hook's environment holds
- `code`    true: the path is a code file (by suffix, or `#!` on the first line), outside the temporary roots

`{root}` in a regular expression stands for the agent's own folder. Called by `skill_gate.py`.
"""
import re
from pathlib import Path

DEFAULT_EVENT = "PreToolUse"
CODE_SUFFIXES = {
    ".py", ".sh", ".bash", ".zsh", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".swift", ".go",
    ".rs", ".rb", ".kt", ".java", ".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".lua", ".ipynb",
}


def target_path(tool_input: dict) -> str:
    """The path the tool reads or writes, or an empty string."""
    return tool_input.get("file_path") or tool_input.get("notebook_path") or tool_input.get("path") or ""


def is_temporary(path_text: str, temporary_roots: tuple[str, ...]) -> bool:
    """Whether the path is one of the temporary roots or inside one."""
    return any(path_text == root or path_text.startswith(root + "/") for root in temporary_roots)


def is_code(path_text: str, first_bytes: bytes, new_content: str, temporary_roots: tuple[str, ...]) -> bool:
    """Whether the path is a code file worth the rules (told by suffix, or by `#!` without a suffix)."""
    if not path_text or is_temporary(path_text, temporary_roots):
        return False
    suffix = Path(path_text).suffix
    if suffix:
        return suffix.lower() in CODE_SUFFIXES
    return new_content.startswith("#!") or first_bytes.startswith(b"#!")


def tool_matches(tool_name: str, tools: list[str]) -> bool:
    return any(tool_name.startswith(name[:-1]) if name.endswith("*") else tool_name == name for name in tools)


def searched(pattern: str, text: str, root: str) -> bool:
    return bool(text) and re.search(pattern.replace("{root}", re.escape(root)), text) is not None


def when_matches(when: dict, event: dict) -> bool:
    """Whether one `when` of the table holds for the event.

    `event` carries: name, tool, path, command, cwd, prompt, env (dict), root, is_code (bool).
    """
    if when.get("event", DEFAULT_EVENT) != event["name"]:
        return False
    if "tools" in when and not tool_matches(event["tool"], when["tools"]):
        return False
    for key in ("path", "command", "cwd", "prompt"):
        if key in when and not searched(when[key], event[key], event["root"]):
            return False
    for pair in when.get("env", []):
        name, _, value = pair.partition("=")
        if event["env"].get(name) != value:
            return False
    return not when.get("code") or event["is_code"]


def skills_for(table: list[dict], event: dict) -> list[str]:
    """The skills whose `when` holds for the event, in table order."""
    return [row["name"] for row in table if any(when_matches(when, event) for when in row.get("when", []))]
