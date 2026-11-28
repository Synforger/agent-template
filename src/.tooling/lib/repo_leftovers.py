"""repo に開いたまま残っている物 (手元の branch・worktree・stash・書きかけ・open の PR) を読んで並べる。

読むだけで、fetch も checkout もしない。呼ぶのは work/plan_run.py。片付けの棚卸しの元になる。
"""

import json
import os
import subprocess
from dataclasses import dataclass

MAIN_BRANCHES = ("develop", "main", "master")
COMMAND_TIMEOUT_S = 20


@dataclass(frozen=True)
class Leftover:
    """開いたままの物 1 件。"""

    repo: str
    kind: str
    name: str
    detail: str


def find_repos(roots: list[str]) -> list[str]:
    """root の直下の folder のうち、自分の `.git` の folder を持つ物を返す。

    `.worktrees` で終わる folder と、`.git` が file の folder (別の repo の worktree) は除く。同じ repo を 2 回数えないため。
    """
    repos: list[str] = []
    for root in roots:
        try:
            names = sorted(os.listdir(root))
        except OSError:
            continue
        for name in names:
            path = os.path.join(root, name)
            if name.endswith(".worktrees") or name.startswith("."):
                continue
            if os.path.isdir(os.path.join(path, ".git")):
                repos.append(path)
    return repos


def list_leftovers(repo: str, gh_command: list[str] | None) -> list[Leftover]:
    """repo 1 つの開いたままの物を返す。`gh_command` が None なら PR は見ない。"""
    name = os.path.basename(repo)
    found: list[Leftover] = []
    base = _base_ref(repo)
    head = _git(repo, "rev-parse", "--abbrev-ref", "HEAD").strip()
    if head == "HEAD":
        found.append(Leftover(name, "detached", _git(repo, "rev-parse", "--short", "HEAD").strip(), "branch の上に居ない"))
    for line in _git(repo, "for-each-ref", "refs/heads", "--format=%(refname:short)\t%(committerdate:short)").splitlines():
        branch, _, date = line.partition("\t")
        if branch in MAIN_BRANCHES:
            continue
        ahead = _git(repo, "rev-list", "--count", f"{base}..{branch}").strip() if base else "?"
        found.append(Leftover(name, "branch", branch, f"{base or '基準なし'} より {ahead} commit 先・最後 {date}"))
    worktrees = [line[len("worktree ") :] for line in _git(repo, "worktree", "list", "--porcelain").splitlines() if line.startswith("worktree ")]
    for path in worktrees[1:]:
        found.append(Leftover(name, "worktree", os.path.basename(path), _home(path)))
    stashes = _git(repo, "stash", "list").splitlines()
    if stashes:
        found.append(Leftover(name, "stash", str(len(stashes)), stashes[0][:80]))
    dirty = _git(repo, "status", "--porcelain").splitlines()
    if dirty:
        found.append(Leftover(name, "dirty", str(len(dirty)), "commit していない file"))
    if gh_command:
        found.extend(_open_prs(repo, name, gh_command))
    return found


def _open_prs(repo: str, name: str, gh_command: list[str]) -> list[Leftover]:
    out = _run([*gh_command, "pr", "list", "--state", "open", "--json", "number,title,headRefName,updatedAt"], repo)
    try:
        prs = json.loads(out) if out.strip() else []
    except ValueError:
        return [Leftover(name, "pr", "?", "open の PR を読めなかった")]
    return [Leftover(name, "pr", f"#{pr['number']}", f"{pr['headRefName']}・最後 {pr['updatedAt'][:10]}・{pr['title'][:60]}") for pr in prs]


def _base_ref(repo: str) -> str:
    for branch in MAIN_BRANCHES:
        if _git(repo, "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{branch}").strip():
            return f"origin/{branch}"
    for branch in MAIN_BRANCHES:
        if _git(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}").strip():
            return branch
    return ""


def _git(repo: str, *args: str) -> str:
    return _run(["git", "-C", repo, *args], repo)


def _run(command: list[str], cwd: str) -> str:
    try:
        done = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=COMMAND_TIMEOUT_S, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return done.stdout


def _home(path: str) -> str:
    home = os.path.expanduser("~")
    return "~" + path[len(home) :] if path.startswith(home) else path
