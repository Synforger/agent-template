#!/usr/bin/env python3
"""起動の検査の各段の出力をつなぎ、 持ち主の階層で振り分けて出す入口 (= startup-status.sh が全段の後に 1 回呼ぶ)。

起動した階層 (`AGENT_TIER`、 無ければ normal) が持ち主の警告は今の行のまま出し、 ほかの階層が持ち主の警告は
`others: <行の名前> <件数> (owner <階層>)` の 1 行にして最後に出す。 判定は `owner_routing.py`、 持ち主の表は
`owner_table.py`。 ここは入力を読み、 階層の一覧と番人の答えと削減候補の命令を集めて渡すだけ。

階層の名前は git に載らない物があるので、 `others:` に名前を書くのは、 このタブがその階層の境界を全部読める時だけ
(= 番人の `area-guard.py reach` で、 その階層のタブが読む境界がこのタブの読む境界に収まる時)。 読めなければ伏せる。
番人に訊けない時も伏せる。

走らせ方:
  python3 .tooling/startup/route_by_owner.py --root <agent の folder> <段の出力の file>...
"""
import os
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from audit_findings import load_reach  # noqa: E402
from owner_routing import capacity_files, others_lines, route  # noqa: E402
from owner_table import NORMAL  # noqa: E402
from tier_paths import tier_folders  # noqa: E402

DETAIL_TIMEOUT_SEC = 30
INDENT = "    "


def run_text(command: list[str], cwd: Path) -> list[str]:
    """命令の出力の行。 動かせない・終わらない時は空 (= 削減候補が出ないだけで、 起動の検査は止めない)。"""
    try:
        done = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=DETAIL_TIMEOUT_SEC, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return []
    return done.stdout.splitlines()


def tool_owners_of(root: Path) -> dict[str, str]:
    """deployed-clones.txt の 4 列目に書かれた、 道具の名前 → その道具を持つ階層。 無い・読めない時は空。"""
    declaration = Path(os.environ.get("DEPLOYED_CLONES_FILE") or root / ".tooling/startup/deployed-clones.txt")
    try:
        lines = declaration.read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    fields = (line.split("#", 1)[0].split() for line in lines)
    return {row[0]: row[3] for row in fields if len(row) >= 4}


def capacity_detail_for(root: Path) -> Callable[[str, bool], list[str]]:
    """溢れた階層の削減候補の行を返す関数 (= 常時 load は capacity-candidates.py、 skill の一覧は skill-listing.py)。"""

    def detail(tier: str, is_skills: bool) -> list[str]:
        if not is_skills:
            files = [rel for rel in capacity_files(tier) if (root / rel).is_file()]
            return run_text([sys.executable, str(root / ".tooling/startup/capacity-candidates.py"), *files], root) if files else []
        tier_dir = root if tier == NORMAL else root / tier
        skills = sorted(str(path) for path in tier_dir.glob(".claude/skills/*/SKILL.md"))
        if not skills:
            return []
        listing = run_text([sys.executable, str(root / ".tooling/lib/skill-listing.py"), *skills], root)
        return [INDENT + line for line in sorted(listing, key=lambda line: int(line.split()[0]), reverse=True)]

    return detail


def readable_by(root: Path) -> Callable[[str], bool]:
    """階層の名前をこのタブが書いてよいか (= その階層のタブが読む境界が、このタブの読む境界に全部収まる)。"""
    mine = load_reach()
    cache: dict[str, bool] = {}

    def is_readable(tier: str) -> bool:
        if tier not in cache:
            theirs = load_reach(root / tier) if (root / tier).is_dir() else None
            cache[tier] = mine is not None and theirs is not None and theirs <= mine
        return cache[tier]

    return is_readable


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[0] != "--root":
        print("usage: route_by_owner.py --root <agent folder> <step output file>...", file=sys.stderr)
        return 2
    root = Path(argv[1])
    text = "\n".join(Path(name).read_text(encoding="utf-8", errors="replace") for name in argv[2:])
    me = (os.environ.get("AGENT_TIER") or NORMAL).strip("/")
    tiers = frozenset(folder.relative_to(root).as_posix() for folder in tier_folders(root))
    routed = route(text, me, tiers, capacity_detail_for(root), tool_owners_of(root))
    for line in [*routed.lines, *others_lines(routed.others, readable_by(root))]:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
