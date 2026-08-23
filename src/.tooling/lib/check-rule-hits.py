#!/usr/bin/env python3
"""発火記録の書き漏らし検査。

なぜ要るか: 発火実績は「どのルールを捨てるか」 の唯一の根拠なので、 書かれない session が
あるとその根拠が欠ける。 欠けたまま容量が詰まると、 結局「古いものから捨てる」 に戻る。

検査対象は「その階層が記録を書き始めた日以降」 の session だけ (= 機構より前の journal を
遡って責めない。 基準日を code に書かないための決め方でもある)。

走らせ方: python3 .tooling/lib/check-rule-hits.py
出力: 1 行 1 件の `<journal .md path>`。 終了コードは常に 0 (= 判定は呼び出し側)。
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

JOURNAL_GLOBS = [
    "journal/*/session-*.md",
    "projects/*/journal/*/session-*.md",
    "projects/*/subprojects/*/journal/*/session-*.md",
]
SESSION_RE = re.compile(r"/(\d{4}-\d{2}-\d{2})/session-(\d+)\.md$")


def main() -> int:
    sessions = []  # (tier, date, nn, rel path)
    for pat in JOURNAL_GLOBS:
        for p in sorted(glob.glob(os.path.join(ROOT, pat))):
            rel = os.path.relpath(p, ROOT)
            m = SESSION_RE.search("/" + rel)
            if not m:
                continue
            tier = rel.split("/journal/")[0]
            tier = "" if tier == rel else tier
            sessions.append((tier, m.group(1), m.group(2), rel))

    # 階層ごとに「記録を書き始めた日」 を出す
    started = {}
    for tier, date, nn, rel in sessions:
        hits = os.path.join(ROOT, os.path.dirname(rel), f"session-{nn}-rule-hits.jsonl")
        if os.path.exists(hits):
            prev = started.get(tier)
            if prev is None or date < prev:
                started[tier] = date

    missing = []
    for tier, date, nn, rel in sessions:
        start = started.get(tier)
        if not start or date < start:
            continue  # その階層はまだ記録を始めていない / 機構より前の session
        hits = os.path.join(ROOT, os.path.dirname(rel), f"session-{nn}-rule-hits.jsonl")
        if not os.path.exists(hits):
            missing.append(rel)

    for rel in missing:
        print(rel)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # fail-open
        print(f"check-rule-hits: {e}", file=sys.stderr)
        sys.exit(0)
