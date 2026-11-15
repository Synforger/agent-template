#!/usr/bin/env python3
"""番人が名乗りの検査をかけ、 締めの commit で初めて止まる階層を、 起動の検査の行にする。

`startup-status.sh` が起動のたびに呼ぶ (= 起動の検査の `step_pending_approvals`)。 階層の列挙は `tier_paths.py`。
行の持ち主はその階層で、 `owner_routing.py` がその階層のタブにだけ出す (= ほかの階層の分は `others:` へ)。

見つける形は今 1 つ。 階層の folder が自分の `.git` を持ち (= エージェントの git から外した階層)、 その repo を番人が
名乗りの検査をかける種類 (`no-remote`・`enforced`・`synforger`) と判定する。 その repo ではエージェントの名前の commit が止まる。
種類は番人の `dispatcher::detect_repo_kind` に訊き、 判定は持たない (= 番人の決めが変われば、 この段もそれに付いて行く)。
番人の部品の在処は `GUARD_DISPATCHER_COMMON` で差し替えられ、 部品が無い機械では何も当たらない。

出す行:
  pending_approval: guard.scope <階層>   当たる階層ごとに 1 行
  pending_approval: none                 当たる階層が無い

走らせ方:
  python3 .tooling/startup/pending_approvals.py [--root <agent の folder>]
"""
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from tier_paths import tier_folders  # noqa: E402

GIT_TIMEOUT_SEC = 10
SCOPE_KEY = "guard.scope"
GUARD_COMMON = Path(os.environ.get("GUARD_DISPATCHER_COMMON")
                    or Path.home() / ".git-hooks/_internal/dispatcher-common.sh")
# 番人が名乗り (= 個人の名前) の検査をかける repo の種類
CHECKED_KINDS = frozenset({"no-remote", "enforced", "synforger"})


def git_output(folder: Path, *args: str) -> str:
    """`git -C <folder> <args>` の標準出力 (= 動かせない・失敗・超過は空)。"""
    try:
        done = subprocess.run(["git", "-C", str(folder), *args], capture_output=True, text=True,
                              timeout=GIT_TIMEOUT_SEC, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return done.stdout.strip() if done.returncode == 0 else ""


def guard_kind(folder: Path) -> str:
    """番人がその folder の repo をどの種類と判定するか (= 部品が無い・訊けない時は空)。"""
    if not GUARD_COMMON.is_file():
        return ""
    try:
        done = subprocess.run(["bash", "-c", '. "$1" && dispatcher::detect_repo_kind', "_", str(GUARD_COMMON)],
                              cwd=folder, capture_output=True, text=True, timeout=GIT_TIMEOUT_SEC, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return done.stdout.strip() if done.returncode == 0 else ""


def is_pending(folder: Path) -> bool:
    """階層の folder が自分の repo で、 番人がそこに名乗りの検査をかけるか。"""
    top_level = git_output(folder, "rev-parse", "--show-toplevel")
    if not top_level or Path(top_level).resolve() != folder.resolve():
        return False
    return guard_kind(folder) in CHECKED_KINDS


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if argv[:1] == ["--root"] and len(argv) > 1 else Path(__file__).resolve().parents[2]
    pending = [folder.relative_to(root).as_posix() for folder in tier_folders(root) if is_pending(folder)]
    for tier in pending:
        print(f"pending_approval: {SCOPE_KEY} {tier}")
    if not pending:
        print("pending_approval: none")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
