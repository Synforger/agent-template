#!/usr/bin/env python3
"""skill の一覧 (= description + when_to_use) を測る / 出す (= LLM 不使用)。

なぜ要るか:
  - 測る: skill は本文を呼んだ時にしか読まないが、 `description` と `when_to_use` は一覧として
    毎 session 文脈に入る (= その階層の file を読んだ時点から)。 常時 load と同じく読んでいるのに
    数えていない量を作らないため、 check-static-capacity.sh が階層ごとに合計する
  - 出す: ハーネスは gitignored な folder の skill を探さない (= 2026-09-26 実測、
    `respectGitignore: false` + 再起動でも同じ)。 その階層では起動時にこの出力を一覧の代わりに読む

走らせ方:
  python3 .tooling/lib/skill-listing.py <SKILL.md>...     # 1 行 1 file の `<bytes>\t<file>`
  python3 .tooling/lib/skill-listing.py --list <階層 dir>  # その階層の一覧 (= 名前 / path / 説明 / 使う場面)
"""
import glob
import os
import re
import sys

KEYS = ("description", "when_to_use")


def frontmatter(path):
    """frontmatter の `key: value` を dict で返す (= 折り返した続き行は空白 1 つで繋ぐ)。"""
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except OSError:
        return {}
    if not lines or lines[0] != "---":
        return {}
    out, key = {}, None
    for line in lines[1:]:
        if line == "---":
            break
        m = re.match(r"^([A-Za-z_-]+):\s*(.*)$", line)
        if m:
            key = m.group(1)
            out[key] = m.group(2).strip()
        elif key and line.strip():
            out[key] = (out[key] + " " + line.strip()).strip()
    return out


def listing_bytes(path):
    fm = frontmatter(path)
    return sum(len(fm.get(k, "").encode("utf-8")) for k in KEYS)


def list_tier(tier):
    files = sorted(glob.glob(os.path.join(tier, ".claude", "skills", "*", "SKILL.md")))
    if not files:
        print(f"skills: {tier} に skill は無い")
        return
    print(f"skills: {tier} ({len(files)} 本、 使う場面に入ったら path の本文を Read)")
    for path in files:
        fm = frontmatter(path)
        name = os.path.basename(os.path.dirname(path))
        when = f" - {fm['when_to_use']}" if fm.get("when_to_use") else ""
        print(f"- {name} (`{path}`): {fm.get('description', '')}{when}")


def main():
    args = sys.argv[1:]
    if args[:1] == ["--list"]:
        for tier in args[1:]:
            list_tier(tier.rstrip("/"))
        return
    for path in args:
        print(f"{listing_bytes(path)}\t{path}")


if __name__ == "__main__":
    main()
