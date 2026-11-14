"""公開の repo で全体の試験 `task ci` を手元で打つ呼び出しを止める PreToolUse hook (Bash)。

公開の repo は、 PR ごとに GitHub の Actions が同じ `task ci` を流す。 手元でも流すと同じ物を 2 回回し、
重い機械をさらに重くする。 決まりは skill `sub-agent § 中央 merge の責務` (エージェントによっては常時の決まりにも在る) で、 これはその止め。
settings の PreToolUse (matcher Bash) から呼ぶ。 試験 = tests/test-ci-duplicate-guard.sh

- 見る命令: `;`・`&&`・`||`・`|`・改行で区切った段ごとに、 `task ci` (= `task -d <dir> ci` / `--dir` も) を探す。
  前の段の `cd <dir>` は、 後の段の作業の folder として数える
- 止める線: その repo の `.github/workflows/` に `task ci` を呼ぶ workflow があり、 `gh repo view` が PUBLIC と
  答えた時だけ。 private の repo は Actions の workflow が走らないので通す
- 読めない時 (git の外・gh が無い・答えない・入力が壊れている) は通す (= fail-open)

入口・判定・読み書きを 1 file に置くのは、 hook が 1 本の入口で呼ばれるため。 判定は関数に分け、 試験から呼べる。
"""
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

SEGMENT_SPLIT = re.compile(r"\|\||&&|[;|\n]")
WORKFLOW_CALLS_CI = re.compile(r"\btask\s+(?:-\S+\s+\S+\s+)*ci\b")
GH_TIMEOUT_SECONDS = 8
GIT_TIMEOUT_SECONDS = 5
#: 試験が gh の代わりに呼ぶ命令 (= 既定は gh)
GH_COMMAND = os.environ.get("CI_GUARD_GH", "gh")
REASON = (
    "公開の repo ({repo}) の全体の試験は、 PR で GitHub の Actions が同じ `task ci` を流すので、 その結果で判定します。"
    " 手元では直した file の試験だけを流してください (skill `sub-agent` § 中央 merge の責務)。"
)


def ci_folders(command: str, cwd: Path) -> list[Path]:
    """命令の中で `task ci` を打つ段ごとに、 その作業の folder を返す (= 無ければ空)。"""
    folders: list[Path] = []
    current = cwd
    for segment in SEGMENT_SPLIT.split(command):
        try:
            words = shlex.split(segment)
        except ValueError:
            continue
        while words and "=" in words[0] and not words[0].startswith("-"):
            words = words[1:]
        if len(words) >= 2 and words[0] == "cd":
            current = (current / os.path.expanduser(words[1])).resolve()
            continue
        if not words or words[0] != "task":
            continue
        folder, rest = current, words[1:]
        while rest and rest[0].startswith("-"):
            flag = rest.pop(0)
            if flag in ("-d", "--dir") and rest:
                folder = (current / os.path.expanduser(rest.pop(0))).resolve()
            elif flag.startswith("--dir="):
                folder = (current / os.path.expanduser(flag.split("=", 1)[1])).resolve()
        if rest and rest[0] == "ci":
            folders.append(folder)
    return folders


def repo_root(folder: Path) -> Path | None:
    """folder を含む git の repo の根 (= git の外なら None)。"""
    try:
        done = subprocess.run(
            ["git", "-C", str(folder), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=GIT_TIMEOUT_SECONDS, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return Path(done.stdout.strip()) if done.returncode == 0 and done.stdout.strip() else None


def workflow_runs_ci(root: Path) -> bool:
    """repo の `.github/workflows/` に `task ci` を呼ぶ workflow があれば真。"""
    workflows = root / ".github" / "workflows"
    if not workflows.is_dir():
        return False
    for path in sorted(workflows.glob("*.y*ml")):
        try:
            if WORKFLOW_CALLS_CI.search(path.read_text(encoding="utf-8", errors="replace")):
                return True
        except OSError:
            continue
    return False


def is_public(root: Path) -> bool:
    """`gh repo view` がその repo を PUBLIC と答えれば真 (= 答えない時は偽)。"""
    try:
        done = subprocess.run(
            [GH_COMMAND, "repo", "view", "--json", "visibility", "-q", ".visibility"],
            cwd=root, capture_output=True, text=True, timeout=GH_TIMEOUT_SECONDS, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return done.returncode == 0 and done.stdout.strip().upper() == "PUBLIC"


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if payload.get("tool_name") != "Bash":
        return 0
    command = (payload.get("tool_input") or {}).get("command") or ""
    if "task" not in command or "ci" not in command:
        return 0
    cwd = Path(payload.get("cwd") or os.getcwd())
    for folder in ci_folders(command, cwd):
        root = repo_root(folder)
        if root and workflow_runs_ci(root) and is_public(root):
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
