"""この機械の client のタブの土台 (= tmux) が 1 本にまとまっているかを、起動と締めで見る。

警告にするのは形の崩れだけ (= 線を引く値は持たない):
  - 同じ名前の tmux の server が 2 本以上 (= 開ける file が尽きた server の代わりに、仮の server が立った印)
  - tmux に在るのに、client のタブの一覧に無い session (= 誰も消さない残り物)
数 (= タブの数・24 時間で作られた数・server が開いている file の数と OS の天井) は素の値で同じ行に出す。

  python3 .tooling/startup/tab_health.py
出力は `tab_health: ok (…)` か `tab_health: WARN …` の 1 行。読めない時は `tab_health: UNKNOWN (<理由>)`。
"""

import json
import os
import re
import subprocess
import sys
import time

SENTINEL = re.compile(r"tmux -L (\S+) new-session -d -s claudepwa-sentinel")
DAY = 24 * 3600


def run(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def servers() -> dict[str, list[str]]:
    """socket の名前 → その名前で立っている server の pid。"""
    found: dict[str, list[str]] = {}
    for line in run(["ps", "-axo", "pid=,command="]).splitlines():
        pid, _, command = line.strip().partition(" ")
        match = SENTINEL.search(command)
        if match:
            found.setdefault(match.group(1), []).append(pid)
    return found


def main() -> int:
    root = os.environ.get("AGENT_PLATFORM_ROOT", os.path.expanduser("~/agent-platform"))
    meta_path = os.path.join(root, "state/claude-pwa-client/data/session_meta.json")
    try:
        with open(meta_path, encoding="utf-8") as fh:
            tabs = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"tab_health: UNKNOWN (タブの一覧を読めない: {type(exc).__name__})")
        return 0
    ids = {t.get("id") for t in tabs}
    recent = sum(1 for t in tabs if time.time() - (t.get("created_at") or 0) < DAY)

    by_name = servers()
    if not by_name:
        print("tab_health: UNKNOWN (client の tmux の server が見つからない)")
        return 0

    problems, numbers = [], [f"タブ {len(tabs)} (24 時間で作られた {recent})"]
    limit = run(["launchctl", "limit", "maxfiles"]).split()
    ceiling = limit[1] if len(limit) > 1 else "?"
    for name, pids in sorted(by_name.items()):
        if len(pids) > 1:
            problems.append(f"{name} の server が {len(pids)} 本 (pid {', '.join(pids)})")
        opened = [str(max(len(run(["lsof", "-p", p]).splitlines()) - 1, 0)) for p in pids]
        numbers.append(f"server の開いた file {'/'.join(opened)} (天井 {ceiling})")
        sessions = run(["tmux", "-L", name, "list-sessions", "-F", "#{session_name}"]).split()
        orphans = [s for s in sessions if s.startswith("pwa-") and s[4:] not in ids]
        if orphans:
            problems.append(f"一覧に無い tmux session {len(orphans)} ({' '.join(orphans)})")

    if problems:
        print(f"tab_health: WARN {' / '.join(problems)} [{' ・'.join(numbers)}]")
    else:
        print(f"tab_health: ok ({'・'.join(numbers)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
