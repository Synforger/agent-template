#!/usr/bin/env python3
"""vision.md の形を検査する (= 必須節の存在と、 節ごとの段落数上限)。

vision は「長期の状態」 を 1 枚で持つ file だが、 実作業が毎日走る階層ほど
「その日わかったこと」 が段落として積まれ、 journal の要約に化ける。
文章側には既に「段落を増やさず既にある行を書き換える」 と書いてあり、
それが守られなかったので機械で赤くする。

上限は実測から引いた (= 2026-08-23、 全 6 階層)。 健全な 4 階層は
「今どこ」 3-4 段落 / 「到達点」 1 段落で、 膨らんだ 2 階層は 12 / 8 段落だった。
「今どこ」 は実測最大 4 の 1 段上、 「到達点」 は全階層一致の 1 に置く。

段落 = 空行で区切られた 1 ブロック (= 連続する箇条書きは 1 段落)。
説明のための節 (= サブプロが案件を説明する枠) は本数も段落数も縛らない。

出力: 違反 1 行ずつ TSV (= path <TAB> message)。 違反ゼロなら無出力。
"""
import re
import sys
from pathlib import Path

# 節名 -> 段落数の上限
SECTION_MAX = {"今どこ": 5, "到達点": 1}
# 無いと FAIL にする節 (= 名前が揺れると機械が状態を見つけられなくなる)
REQUIRED = ("今どこ", "到達点")

SKIP_PARTS = ("_archive", "_template-project", "_template-subproject")


def sections(text):
    """## 見出しごとに段落数を返す。"""
    out = {}
    name = None
    blank = True
    for line in text.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            name = m.group(1)
            out.setdefault(name, 0)
            blank = True
            continue
        if name is None:
            continue
        if line.strip() == "":
            blank = True
            continue
        if blank:
            out[name] += 1
            blank = False
    return out


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    rows = []
    for path in sorted(root.rglob("vision.md")):
        if any(part in SKIP_PARTS for part in path.parts):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        found = sections(text)
        rel = path.as_posix().removeprefix("./")
        for req in REQUIRED:
            if req not in found:
                rows.append((rel, f"vision shape: missing required section → ## {req}"))
        for name, limit in SECTION_MAX.items():
            n = found.get(name)
            if n is not None and n > limit:
                rows.append((
                    rel,
                    f"vision shape: ## {name} has {n} paragraphs > {limit} "
                    f"(rewrite an existing paragraph instead of adding one)",
                ))
    for rel, msg in rows:
        print(f"{rel}\t{msg}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # fail-open (= 検査の事故で docs-check を止めない)
        print(f"check-vision-shape: {exc}", file=sys.stderr)
