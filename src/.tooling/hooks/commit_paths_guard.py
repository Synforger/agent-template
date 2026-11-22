"""エージェントの checkout で、 path を `--` で名指さない `git commit` を止める PreToolUse hook (Bash)。

エージェントの checkout は、 全部の階層のタブが同じ作業木と index を使う。 path を名指さない commit は、
別のタブが stage して置いていた物まで載せる。
締めの手順 (skill `session-end` Step 3) は path を名指す形で、 これは締め以外の commit にも同じ形を求める止め。
settings の PreToolUse (matcher Bash) から呼ぶ。 試験 = tests/test-commit-paths-guard.sh

- 見る命令: 引用符ごと字句に割り、 `;`・`&&`・`||`・`|`・`&`・改行で段を分け、 段ごとに `git [-C <dir>] commit` を探す。
  前の段の `cd <dir>` は、 後の段の作業の folder として数える
- 止める線: その commit の repo の根がエージェントの folder (= `AGENT_ROOT` と、 この hook を持つエージェントの根) で、
  `--` の後に path が無いか、 `-a` / `--all` を使う時
- 読めない時 (git の外・入力が壊れている・字句に割れない) は通す (= fail-open)

入口・判定・読み書きを 1 file に置くのは、 hook が 1 本の入口で呼ばれるため。 判定は関数に分け、 試験から呼べる。
"""
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

from shell_segments import segments  # noqa: E402

GIT_TIMEOUT_SECONDS = 5
GIT_OPTIONS_WITH_VALUE = {"-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}
SHORT_OPTIONS_WITH_VALUE = set("mFCctS")
HOOK_AGENT_ROOT = Path(__file__).resolve().parents[2]
REASON = (
    "{repo} の checkout は全部のタブが同じ index を使うので、 path を名指さない commit は別のタブが stage した物まで載せます。"
    " `git commit -m <message> -- <自分が書いた path>...` の形で打ってください (`-a` も同じ理由で使いません。"
    " merge を閉じる時は `git merge --continue`)。"
)


def commit_calls(command: str, cwd: Path) -> list[tuple[Path, list[str]]]:
    """命令の中の `git commit` ごとに、 その作業の folder と commit の後ろの字句を返す (= 無ければ空)。"""
    calls: list[tuple[Path, list[str]]] = []
    current = cwd
    for words in segments(command):
        while words and "=" in words[0] and not words[0].startswith("-"):
            words = words[1:]
        if len(words) >= 2 and words[0] == "cd":
            current = (current / os.path.expanduser(words[1])).resolve()
            continue
        if not words or words[0] != "git":
            continue
        folder, rest = current, words[1:]
        while rest and rest[0].startswith("-"):
            flag = rest.pop(0)
            if flag == "-C" and rest:
                folder = (folder / os.path.expanduser(rest.pop(0))).resolve()
            elif flag in GIT_OPTIONS_WITH_VALUE and rest:
                rest.pop(0)
        if rest and rest[0] == "commit":
            calls.append((folder, rest[1:]))
    return calls


def names_paths(arguments: list[str]) -> bool:
    """commit の後ろの字句が `--` の後に path を持ち、 `-a` / `--all` を使っていなければ真。"""
    if "--" not in arguments:
        return False
    before, after = arguments[:arguments.index("--")], arguments[arguments.index("--") + 1:]
    return bool(after) and not any(word == "--all" or uses_short_all(word) for word in before)


def uses_short_all(word: str) -> bool:
    """短い旗の束 (= `-qa`・`-am`) が `-a` を含めば真。 値を取る旗の後ろの字は値なので見ない。"""
    if not word.startswith("-") or word.startswith("--"):
        return False
    for letter in word[1:]:
        if letter == "a":
            return True
        if letter in SHORT_OPTIONS_WITH_VALUE:
            return False
    return False


def repo_root(folder: Path) -> Path | None:
    """folder を含む git の repo の根 (= git の外なら None)。"""
    try:
        done = subprocess.run(
            ["git", "-C", str(folder), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=GIT_TIMEOUT_SECONDS, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return Path(done.stdout.strip()).resolve() if done.returncode == 0 and done.stdout.strip() else None


def agent_roots() -> set[Path]:
    """止める対象のエージェントの folder (= session の `AGENT_ROOT` と、 この hook を持つエージェントの根)。"""
    roots = {HOOK_AGENT_ROOT}
    if os.environ.get("AGENT_ROOT"):
        roots.add(Path(os.environ["AGENT_ROOT"]).expanduser().resolve())
    return roots


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if payload.get("tool_name") != "Bash":
        return 0
    command = (payload.get("tool_input") or {}).get("command") or ""
    if "git" not in command or "commit" not in command:
        return 0
    cwd = Path(payload.get("cwd") or os.getcwd())
    roots = agent_roots()
    for folder, arguments in commit_calls(command, cwd):
        root = repo_root(folder)
        if root in roots and not names_paths(arguments):
            decision = {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": REASON.format(repo=root.name),
                }
            }
            print(json.dumps(decision, ensure_ascii=False))
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
