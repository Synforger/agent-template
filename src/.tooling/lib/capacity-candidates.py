#!/usr/bin/env python3
"""容量超過時に「どれを消せば何バイト減るか」を出す (= 圧縮の往復を 1 回で終わらせる)。

なぜ要るか: 超過を知らされても、 どの section が何バイトかは分からない。 結果として
「少し削る → 測り直す」 を何度も繰り返すことになり、 その待ち時間がそのまま人の待ち時間に
なる。 削る前に全 section のバイト数が並んでいれば、 消す対象は 1 回で決まる。

発火 / 違反の実績も並べる (= 記録が貯まるまでは 0 のままだが、 バイト数だけでも往復は消える)。
実績が同じならバイト数の大きいほうから消す、 ではなく **実績 0 のものから消す** のが原則
(= 真値 = rules/always.md § meta)。

走らせ方: python3 .tooling/lib/capacity-candidates.py <rule file>...
出力: 上位 15 section を `バイト数 / 発火 / 違反 / file :: path` で降順に。
"""
import glob
import importlib.util
import json
import os
import re
import sys

sys.dont_write_bytecode = True  # import の副産物 (.pyc) を repo に残さない

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOP_N = 15
HEADING = re.compile(r"^(#{2,3})\s+(.*)$")


def sections_of(rel):
    """file を H2/H3 section に割り、 (heading, bytes) を返す。 前文は見出し無しで数えない。"""
    path = os.path.join(ROOT, rel)
    try:
        lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
    except OSError:
        return []
    out, cur, buf = [], None, []
    for ln in lines:
        m = HEADING.match(ln.rstrip("\n"))
        if m:
            if cur is not None:
                out.append((cur, len("".join(buf).encode())))
            cur, buf = m.group(2).strip(), [ln]
        elif cur is not None:
            buf.append(ln)
    if cur is not None:
        out.append((cur, len("".join(buf).encode())))
    return out


def load_hits():
    """rule-hits-summary の集計を借りる (= 判定ロジックを二重に持たない)。"""
    spec = importlib.util.spec_from_file_location(
        "rhs", os.path.join(ROOT, ".tooling", "rule-hits-summary.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    reg, _live, _hits, fired, violated, *_ = mod.summarize()
    by_key = {}
    for r in reg:
        by_key[(r.get("file"), r.get("heading"))] = (r["tier"], r["id"])
    return by_key, fired, violated


def main():
    files = sys.argv[1:]
    if not files:
        return 0
    try:
        by_key, fired, violated = load_hits()
    except Exception:  # 実績が引けなくてもバイト数だけで役に立つ
        by_key, fired, violated = {}, {}, {}

    rows = []
    for rel in files:
        for heading, size in sections_of(rel):
            key = by_key.get((rel, heading))
            f = fired.get(key, 0) if key else 0
            v = violated.get(key, 0) if key else 0
            rows.append((size, f, v, rel, heading))
    if not rows:
        return 0

    rows.sort(key=lambda r: -r[0])
    print("  削減候補 (= バイト数降順、 実績 0 のものから消す):")
    for size, f, v, rel, heading in rows[:TOP_N]:
        print(f"    {size:5} B  発火 {f:2}  違反 {v:2}  {rel} :: {heading}")
    rest = len(rows) - TOP_N
    if rest > 0:
        print(f"    (他 {rest} section)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # fail-open (= 容量検査そのものを止めない)
        print(f"capacity-candidates: {e}", file=sys.stderr)
        sys.exit(0)
