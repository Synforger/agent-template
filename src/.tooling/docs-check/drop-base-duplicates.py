#!/usr/bin/env python3
"""派生の layout.txt・contracts.txt から、 型の 2 枚と重なる行を外す (= 検査の `duplicate` の全量を消す)。

使い方: python3 .tooling/docs-check/drop-base-duplicates.py <派生の根> [--apply]   (= sync-from-base.sh の後、 docs-check が二重の宣言を赤にした時)
  --apply が無ければ、 外す行の数だけを出す。 検査は派生の根に降りた check-declarations.py を使う。
外し方: layout は重なった名前を行から抜き (名前が全部無くなる行は行ごと消す)、 contracts は重なった行を消す。
"""
import collections
import os
import re
import subprocess
import sys

# 検査は、型が降ろした派生の根の check-declarations.py を使う (= 取り込みの後に打つ)
CHECK_REL = ".tooling/docs-check/check-declarations.py"


def main() -> int:
    root = os.path.abspath(sys.argv[1])
    apply = "--apply" in sys.argv
    out = subprocess.run([sys.executable, os.path.join(root, CHECK_REL), "--root", root], capture_output=True, text=True).stdout
    layout: dict[int, list[str]] = collections.defaultdict(list)
    contracts: set[int] = set()
    for line in out.splitlines():
        m = re.match(r"layout: duplicate .+? : (\S+) \(.*\[layout\.base\.txt:\d+, layout\.txt:(\d+)\]$", line)
        if m:
            layout[int(m.group(2))].append(m.group(1))
        m = re.match(r"contracts: duplicate \S+ .*\[contracts\.base\.txt:\d+, contracts\.txt:(\d+)\]$", line)
        if m:
            contracts.add(int(m.group(1)))
    print(f"layout.txt: {sum(len(v) for v in layout.values())} 名前 ({len(layout)} 行)  contracts.txt: {len(contracts)} 行")
    if not apply:
        return 0
    path = os.path.join(root, ".tooling/layout.txt")
    lines = open(path, encoding="utf-8").read().split("\n")
    kept = []
    for number, line in enumerate(lines, 1):
        if number not in layout:
            kept.append(line)
            continue
        body, _, comment = line.partition("#")
        folder, _, names = body.partition(":")
        rest = [n for n in names.split() if n.lstrip("?") not in layout[number]]
        if rest:
            kept.append(folder.rstrip() + " : " + " ".join(rest) + (("  #" + comment) if comment else ""))
    open(path, "w", encoding="utf-8").write("\n".join(kept))
    path = os.path.join(root, ".tooling/contracts.txt")
    lines = open(path, encoding="utf-8").read().split("\n")
    open(path, "w", encoding="utf-8").write("\n".join(l for n, l in enumerate(lines, 1) if n not in contracts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
