"""起動と締めの固定費の記録 (hook `hooks/fixed_cost.py` が書く) を読み、起動の検査の 1 行か、階層ごとの表にする。

  python3 .tooling/startup/fixed_cost_summary.py            起動の検査の 1 行 (今の階層と全体)
  python3 .tooling/startup/fixed_cost_summary.py --by-tier  agent と階層ごとの表 (どのプロジェクトがどれだけ減らしたか)
起動は入れ替えと階層のタブの封筒で始まった物だけを数える (子のタブは仕事が最初の発話なので外す)。締めは入れ替えの締め。
線は引かず素の値で出す。記録が無い時は `fixed_cost: no record yet`。
"""

import json
import os
import statistics
import sys
import time
from collections import defaultdict

DAYS = 7
BOOT_KINDS = ("rollover", "tab-open")


def load() -> list[dict]:
    root = os.environ.get("AGENT_PLATFORM_ROOT", os.path.expanduser("~/agent-platform"))
    path = os.path.join(root, "state", "token-usage", "fixed.jsonl")
    since = time.strftime("%Y-%m-%d", time.localtime(time.time() - DAYS * 86400))
    rows = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if row.get("ts", "") < since:
                    continue
                if row.get("phase") == "close" or row.get("kind") in BOOT_KINDS:
                    rows.append(row)
    except OSError:
        pass
    return rows


def brief(rows: list[dict]) -> str:
    if not rows:
        return "0 回"
    used = statistics.median(r["used_weighted"] for r in rows) / 1e3
    total = sum(r["used_weighted"] for r in rows) / 1e3
    return f"{len(rows)} 回・中央値 {used:.0f}k・計 {total:.0f}k"


def main() -> None:
    rows = load()
    if not rows:
        print("fixed_cost: no record yet")
        return
    if "--by-tier" in sys.argv:
        groups = defaultdict(lambda: {"startup": [], "close": []})
        for r in rows:
            groups[(r.get("agent_dir") or "?", r.get("tier") or "-")][r["phase"]].append(r)
        print(f"直近 {DAYS} 日 (重みつき) | agent | 階層 | 起動 | 締め")
        for (agent, tier), g in sorted(groups.items(), key=lambda kv: -sum(r["used_weighted"] for p in kv[1].values() for r in p)):
            print(f"{agent} | {tier} | {brief(g['startup'])} | {brief(g['close'])}")
        return
    tier = os.environ.get("AGENT_TIER", "normal")
    mine = [r for r in rows if r.get("tier") == tier]
    parts = []
    for phase, name in (("startup", "起動"), ("close", "締め")):
        parts.append(f"{name}: この階層 {brief([r for r in mine if r['phase'] == phase])} / 全体 {brief([r for r in rows if r['phase'] == phase])}")
    print(f"fixed_cost: 直近 {DAYS} 日 (重みつき) " + " | ".join(parts))


if __name__ == "__main__":
    main()
