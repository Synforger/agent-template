#!/usr/bin/env python3
"""deployed-clones.txt に載った道具の repo ごとに、 develop の最新の commit と開いている PR の Actions の結果を 1 行にする。

`startup-status.sh` が起動のたびに呼ぶ (= 起動の検査の `step_tool_actions`)。 判定は `actions_verdict.py`、 行の持ち主は
宣言の 4 列目 (= `route_by_owner.py` が読む)。 道具の repo の Actions が赤のまま merge されていないかを、 起動の画面で見つけるための段。

出す行 (道具 1 本に 1 行):
  tool_actions(<名前>): ok (…)                    develop の最新の commit も、 開いている PR も赤が無い
                                                 (= develop の結果は、 その commit の run、 無ければ作った PR の検査)
  tool_actions(<名前>): RED develop (…), RED PR #N  赤の在処を全部並べる
  tool_actions(<名前>): UNKNOWN (<理由>)           gh が動かない / 上限を超えた / repo が読めない
  (何も出さない)                                    宣言の file が無い機械

`gh` は道具の folder の token が要るので、 既定は `direnv exec <器の根>/tools gh` (= `TOOL_ACTIONS_GH` で差し替えられる)。
全部で 20 秒 (= `TOOL_ACTIONS_TIMEOUT_SEC` で差し替えられる) を超えたら、 終わっていない道具は UNKNOWN。 宣言の file は `DEPLOYED_CLONES_FILE` で差し替えられる。

走らせ方:
  python3 .tooling/startup/tool_actions.py
"""
import json
import os
import re
import shlex
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from actions_verdict import branch_state, red_pull_requests, unknown_line, verdict_line  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PLATFORM_ROOT = Path(os.environ.get("AGENT_PLATFORM_ROOT") or Path.home() / "agent-platform")
DECLARATION = Path(os.environ.get("DEPLOYED_CLONES_FILE") or ROOT / ".tooling/startup/deployed-clones.txt")
GH_COMMAND = shlex.split(os.environ.get("TOOL_ACTIONS_GH") or f"direnv exec {PLATFORM_ROOT / 'tools'} gh")
TOTAL_TIMEOUT_SEC = int(os.environ.get("TOOL_ACTIONS_TIMEOUT_SEC") or 20)
LIST_LIMIT = 50
REMOTE_SLUG = re.compile(r"github[\w.-]*[:/](?P<slug>[^/\s]+/[^/\s]+?)(?:\.git)?/?$")


class ActionsUnknown(Exception):
    """結果を取れなかった理由 (= UNKNOWN の行の括弧の中身)。"""


def run(command: list[str], deadline: float) -> str:
    """命令の標準出力。 締め切りまでの残りで待ち、 動かせない・失敗・超過は ActionsUnknown。"""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ActionsUnknown(f"not finished in {TOTAL_TIMEOUT_SEC}s")
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=remaining, check=False)
    except subprocess.TimeoutExpired as error:
        raise ActionsUnknown(f"not finished in {TOTAL_TIMEOUT_SEC}s") from error
    except OSError as error:
        raise ActionsUnknown(f"could not run {command[0]}: {error.strerror}") from error
    if done.returncode != 0:
        last = next((line for line in reversed(done.stderr.splitlines()) if line.strip()), "no message")
        raise ActionsUnknown(f"{' '.join(command[:2])} exited {done.returncode}: {last.strip()[:120]}")
    return done.stdout


def gh_json(args: list[str], deadline: float) -> Any:
    """`gh <args>` の JSON。"""
    text = run([*GH_COMMAND, *args], deadline)
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise ActionsUnknown("gh printed no JSON") from error


def remote_slug(clone: Path, deadline: float) -> str:
    """clone の origin の `<owner>/<repo>`。"""
    url = run(["git", "-C", str(clone), "remote", "get-url", "origin"], deadline).strip()
    found = REMOTE_SLUG.search(url)
    if found is None:
        raise ActionsUnknown("origin is not a GitHub remote")
    return found["slug"]


def tool_line(name: str, clone: Path, branch: str, deadline: float) -> str:
    """道具 1 本の行。 取れなかった理由は UNKNOWN の行にする。"""
    try:
        slug = remote_slug(clone, deadline)
        sha = str(gh_json(["api", f"repos/{slug}/branches/{branch}", "--jq", "{sha: .commit.sha}"], deadline)["sha"])
        runs = gh_json(["run", "list", "--repo", slug, "--commit", sha, "--limit", str(LIST_LIMIT),
                        "--json", "workflowName,conclusion,status"], deadline)
        merged = gh_json(["pr", "list", "--repo", slug, "--state", "merged", "--base", branch, "--limit", "5",
                          "--json", "number,statusCheckRollup,mergeCommit"], deadline)
        pulls = gh_json(["pr", "list", "--repo", slug, "--state", "open", "--limit", str(LIST_LIMIT),
                         "--json", "number,statusCheckRollup"], deadline)
    except (ActionsUnknown, KeyError, TypeError) as error:
        return unknown_line(name, str(error) or "unexpected gh output")
    branch_red, basis = branch_state(runs, merged, sha)
    return verdict_line(name, branch, sha, branch_red, basis, red_pull_requests(pulls), len(pulls))


def declared_tools() -> list[tuple[str, Path, str]]:
    """宣言の file の (名前, clone, 追う branch)。 file が無ければ空。"""
    if not DECLARATION.is_file():
        return []
    tools = []
    for line in DECLARATION.read_text(encoding="utf-8").splitlines():
        fields = line.split("#", 1)[0].split()
        if len(fields) >= 3:
            tools.append((fields[0], Path(fields[1]).expanduser(), fields[2]))
    return tools


def main() -> int:
    tools = declared_tools()
    if not tools:
        return 0
    deadline = time.monotonic() + TOTAL_TIMEOUT_SEC
    with ThreadPoolExecutor(max_workers=len(tools)) as pool:
        for line in pool.map(lambda tool: tool_line(*tool, deadline), tools):
            print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
