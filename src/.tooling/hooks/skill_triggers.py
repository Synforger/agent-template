"""Which skills an event calls for, by the trigger table (pure: no file, state or command is touched).

Two tables are read (by `skill_reads.py`): the base table `skill-triggers.base.toml`, which the agent template
ships with rows for the skills it ships, and the agent's own `skill-triggers.toml`. Each lists one skill per
`[[skill]]` with one or more `[[skill.when]]`. A `[[skill]]` has:

- `name`  the name the Skill tool calls it by (a plugin's skill is `<plugin>:<skill>`)
- `off`   true, in the agent's own table only: drop the base table's row of that name
- `file`  where its SKILL.md is (optional). `{platform}` stands for the platform's root (`AGENT_PLATFORM_ROOT`,
          else `~/agent-platform`) and `{root}` for the agent's own folder. Without it the skill is the agent's
          own: `<agent>/.claude/skills/<name>/SKILL.md`

A `when` matches when every condition it writes holds:

- `event`   the hook event (default `PreToolUse`; also `UserPromptSubmit`, `SessionStart`)
- `tools`   tool names; a name ending in `*` matches by prefix
- `path`    a regular expression searched in the path the tool reads or writes
- `command` a regular expression searched in a Bash command, leaving out the body of a here-document (the text a
          command writes with `<<EOF`, such as a message, is not a command)
- `cwd`     a regular expression searched in the session's working folder
- `subagent` a regular expression searched in the Agent tool's `subagent_type` (`general-purpose` when the call
          leaves it out)
- `prompt`  a regular expression searched in the operator's message
- `env`     `NAME=value` pairs that the hook's environment holds
- `code`    true: the path is a code file (by suffix, or `#!` on the first line), outside the scratch places (the
          temporary roots and any folder named `_scratch` or `scratchpad`, with all inside them)
- `code_place` true: the Bash command makes a place for code, that is, a `mkdir` of it makes a folder outside the
          scratch places. The command's own variables (and the hook's environment) and its `cd` are followed; an
          operand that is only unknown variables says nothing. A folder is no place for code when the command only
          writes documents (`.md`, `.txt`, `.json`) and what it writes into that folder is documents. A `mkdir`
          inside a string or a substitution is not read

An own row with a base row's name adds its `when` to that row; any other own row is a skill of the agent's own.
`{root}` in a regular expression stands for the agent's own folder. Called by `skill_gate.py`.
"""
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

from shell_segments import segments, without_text  # noqa: E402
from test_time import VARIABLE, command_words, expanded, step_assignments, without_redirections  # noqa: E402

DEFAULT_EVENT = "PreToolUse"
HEREDOC_START = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
CODE_SUFFIXES = {
    ".py", ".sh", ".bash", ".zsh", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".swift", ".go",
    ".rs", ".rb", ".kt", ".java", ".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".lua", ".ipynb",
}
DOCUMENT_SUFFIXES = frozenset((".md", ".txt", ".json"))
#: Folder names whose inside is a scratch place (notes, message bodies, a session's temporary files)
SCRATCH_FOLDERS = frozenset(("_scratch", "scratchpad"))
#: The heads of the steps a command that only writes documents is made of: moving, making folders, writing and
#: looking at text, and sending it to a tab
DOCUMENT_STEPS = frozenset((
    "cd", "mkdir", "echo", "printf", "cat", "tee", "true", ":", "export", "ls", "wc", "head", "tail", "grep", "date",
    "test", "[", "tabs",
))
#: An innermost `$(…)`
SUBSTITUTION = re.compile(r"\$\(([^()]*)\)")
#: What stands for a substitution whose value the command does not tell
UNKNOWN_VALUE = "${_substituted}"
#: A redirection that writes (`>`, `>>`, `2>`, `&>`), with its target when it is in the same word; `2>&1` is not one
WRITE_REDIRECTION = re.compile(r"^(?:\d*|&)>>?(?!&)(.*)$")
#: The `mkdir` flags that take the next word as their value (`-m`, `-pm`, `--mode`)
MODE_FLAG = re.compile(r"^(?:--mode|-[A-Za-z]*m)$")


def target_path(tool_input: dict) -> str:
    """The path the tool reads or writes, or an empty string."""
    return tool_input.get("file_path") or tool_input.get("notebook_path") or tool_input.get("path") or ""


def is_temporary(path_text: str, temporary_roots: tuple[str, ...]) -> bool:
    """Whether the path is one of the temporary roots or inside one."""
    return any(path_text == root or path_text.startswith(root + "/") for root in temporary_roots)


def is_scratch(folder: str, temporary_roots: tuple[str, ...]) -> bool:
    """Whether the folder is a scratch place or inside one (nothing written there is kept in a repository)."""
    return is_temporary(folder, temporary_roots) or bool(SCRATCH_FOLDERS.intersection(Path(folder).parts))


def is_code(path_text: str, first_bytes: bytes, new_content: str, temporary_roots: tuple[str, ...]) -> bool:
    """Whether the path is a code file worth the rules (told by suffix, or by `#!` without a suffix)."""
    if not path_text or is_scratch(os.path.dirname(os.path.normpath(path_text)), temporary_roots):
        return False
    suffix = Path(path_text).suffix
    if suffix:
        return suffix.lower() in CODE_SUFFIXES
    return new_content.startswith("#!") or first_bytes.startswith(b"#!")


def without_heredocs(command: str) -> str:
    """The command with the body of each here-document taken out (its opening line stays)."""
    kept: list[str] = []
    ending = None
    for line in command.split("\n"):
        if ending is not None:
            if line.strip() == ending:
                ending = None
            continue
        kept.append(line)
        opened = HEREDOC_START.findall(line)
        if opened:
            ending = opened[-1][1]
    return "\n".join(kept)


def without_substitutions(command: str, temporary_root: str) -> str:
    """The command with each `$(…)` as one word: a temporary root for `mktemp`, else an unknown variable."""
    def stand_in(match: re.Match[str]) -> str:
        return temporary_root if match[1].split()[:1] == ["mktemp"] else UNKNOWN_VALUE

    count = 1
    while count:
        command, count = SUBSTITUTION.subn(stand_in, command)
    return command


def resolved_path(path_text: str, folder: str, home: str) -> str:
    """The path as seen from the folder (by its text alone: no file is looked at)."""
    if path_text == "~" or path_text.startswith("~/"):
        path_text = home + path_text[1:]
    return os.path.normpath(os.path.join(folder, path_text))


def shell_steps(command: str, cwd: str, variables: dict[str, str]) -> list[tuple[list[str], str, dict[str, str]]]:
    """Each step of the command: its words, the folder it runs in (following `cd`, and back out of a `(…)`), and the
    variables known there."""
    steps = []
    folder, outer_folders = cwd, []
    known = dict(variables)
    for step in segments(command):
        if step[0].startswith("("):
            outer_folders.append(folder)
        known.update(step_assignments(step, known))
        words = command_words([step[0].lstrip("(") or "(", *step[1:]])
        if words:
            steps.append((words, folder, dict(known)))
            if words[0] == "cd":
                targets = [word.rstrip(")") for word in without_redirections(words[1:]) if not word.startswith("-")]
                target = expanded(targets[0], known) if targets else known.get("HOME", "")
                folder = resolved_path(target, folder, known.get("HOME", ""))
        if outer_folders and any(word.endswith(")") for word in step):
            folder = outer_folders.pop()
    return steps


def mkdir_operands(words: list[str]) -> list[str]:
    """The folders a `mkdir` step names (its flags and redirections left out)."""
    rest = without_redirections(words[1:])
    operands = []
    while rest:
        word = rest.pop(0)
        if word.startswith("-"):
            if MODE_FLAG.match(word) and rest:
                rest.pop(0)
            continue
        operands.append(word.rstrip(")"))
    return operands


def written_files(words: list[str]) -> list[str]:
    """The files a step writes by a redirection or `tee` (`/dev/null` is no file)."""
    targets = []
    rest = list(words)
    while rest:
        match = WRITE_REDIRECTION.match(rest.pop(0))
        if match:
            targets.append(match[1] or (rest.pop(0) if rest else ""))
    if os.path.basename(words[0]) == "tee":
        targets += [word for word in without_redirections(words[1:]) if not word.startswith("-")]
    return [target.rstrip(")") for target in targets if target.rstrip(")") != "/dev/null"]


def holds_only_documents(folder: str, files: list[str]) -> bool:
    """Whether some of the files are inside the folder and every one of those is a document."""
    inside = [file for file in files if file.startswith(folder + "/")]
    return bool(inside) and all(Path(file).suffix.lower() in DOCUMENT_SUFFIXES for file in inside)


def makes_code_place(command: str, cwd: str, variables: dict[str, str], temporary_roots: tuple[str, ...]) -> bool:
    """Whether the command makes a place for code (the `code_place` condition at the top of this file)."""
    if "mkdir" not in command:
        return False
    command = without_substitutions(without_text(command), temporary_roots[0])
    folders, files = [], []
    only_document_steps = True
    for words, folder, known in shell_steps(command, cwd, variables):
        head = os.path.basename(words[0])
        only_document_steps = only_document_steps and head in DOCUMENT_STEPS
        files += [resolved_path(expanded(target, known), folder, known.get("HOME", ""))
                  for target in written_files(words)]
        for operand in mkdir_operands(words) if head == "mkdir" else []:
            path_text = expanded(operand, known)
            if VARIABLE.sub("", path_text).strip("/"):
                folders.append(resolved_path(path_text, folder, known.get("HOME", "")))
    return any(
        not (is_scratch(folder, temporary_roots) or (only_document_steps and holds_only_documents(folder, files)))
        for folder in folders)


def merged(base: list[dict], own: list[dict]) -> list[dict]:
    """The base table's rows with the agent's own rows laid over them, each marked with `from_base`.

    An own row with a base row's name adds its `when` to that row (`file` too, when it gives one), and `off = true`
    drops that row. Any other own row follows the base rows.
    """
    rows = {row["name"]: {**row, "when": list(row.get("when", [])), "from_base": True} for row in base}
    for row in own:
        name = row["name"]
        if name in rows and rows[name]["from_base"]:
            if row.get("off"):
                del rows[name]
                continue
            rows[name]["when"] += row.get("when", [])
            if "file" in row:
                rows[name]["file"] = row["file"]
        elif not row.get("off"):
            rows[name] = {**row, "when": list(row.get("when", [])), "from_base": False}
    return list(rows.values())


def tool_matches(tool_name: str, tools: list[str]) -> bool:
    return any(tool_name.startswith(name[:-1]) if name.endswith("*") else tool_name == name for name in tools)


def searched(pattern: str, text: str, root: str) -> bool:
    return bool(text) and re.search(pattern.replace("{root}", re.escape(root)), text) is not None


def when_matches(when: dict, event: dict) -> bool:
    """Whether one `when` of the table holds for the event.

    `event` carries: name, tool, path, command, cwd, subagent, prompt, env (dict), root, is_code (bool),
    makes_code_place (bool).
    """
    if when.get("event", DEFAULT_EVENT) != event["name"]:
        return False
    if "tools" in when and not tool_matches(event["tool"], when["tools"]):
        return False
    for key in ("path", "command", "cwd", "subagent", "prompt"):
        text = without_heredocs(event[key]) if key == "command" else event[key]
        if key in when and not searched(when[key], text, event["root"]):
            return False
    for pair in when.get("env", []):
        name, _, value = pair.partition("=")
        if event["env"].get(name) != value:
            return False
    if when.get("code_place") and not event["makes_code_place"]:
        return False
    return not when.get("code") or event["is_code"]


def skill_file(row: dict, root: Path, platform: Path) -> Path:
    """Where the SKILL.md of a table row is (the agent's own skill folder unless the row says `file`)."""
    if "file" not in row:
        return root / ".claude/skills" / row["name"] / "SKILL.md"
    return Path(row["file"].replace("{platform}", str(platform)).replace("{root}", str(root)))


def skills_for(table: list[dict], event: dict) -> list[str]:
    """The skills whose `when` holds for the event, in table order."""
    return [row["name"] for row in table if any(when_matches(when, event) for when in row.get("when", []))]
