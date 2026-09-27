#!/usr/bin/env python3
"""ルールの主文が肯定形で書かれているかを検査する。

否定形で書かれた指示は、 読み手に「やってはいけないこと」 を思い浮かべさせてから
打ち消させるので、 肯定形より守られにくくなる (= 心理学で反跳効果として知られる形)。
ルールは読んだ次の手が決まる形であるべきなので、 主文は「何をするか」 で書く。

検査するのは主文だけ (= 見出し行と、 太字で始まる箇条書きの先頭節)。
`Why:` / `How:` 行と、 `(= ...)` の補足節は失敗の描写を書く場所なので対象外。

判定は節の末尾で行う。 打ち消しの語尾 (= ない / ません / ず / 禁止 / 不可) で
終わる節が主文に在れば 1 件として報告する。

出力: 違反 1 行ずつ TSV (= path <TAB> message)。 違反ゼロなら無出力。
`--selftest` で fixture を通し、 bad が鳴り clean が黙ることを実証する。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# 打ち消しの語尾 (= 節の末尾に来た時だけ主文を否定形にする)
NEGATIVE_TAIL = re.compile(
    r"(?:ない|ないで|なく|ません|ず|ずに|禁止|厳禁|不可|ダメ)$"
)
# 語尾が「ない」 でも打ち消しではない形容詞 (= 語幹の一部)
ADJECTIVE_NAI = ("少ない", "危ない", "情けない", "もったいない", "仕方ない")
# 節の区切り
CLAUSE_SPLIT = re.compile(r"[。、，,]")
# 主文から落とす部分 (= 補足節 / 引用 / code span)
DROP = [
    re.compile(r"\(=[^)]*\)"),
    re.compile(r"（=[^）]*）"),
    re.compile(r"「[^」]*」"),
    re.compile(r"`[^`]*`"),
    re.compile(r"\*\*"),
]
# 主文ではない行 (= 失敗の描写を書く場所)
EXEMPT_PREFIX = ("Why", "How", "why", "how")


def rule_files() -> list[Path]:
    """検査対象 = 常時 load と skill のルール本体、 および起動手順の真値。"""
    out = [ROOT / "CLAUDE.md"]
    for pat in ("rules/always.md", ".claude/skills/*/SKILL.md", "projects/*/rules/always.md",
                "projects/*/.claude/skills/*/SKILL.md", "projects/*/subprojects/*/rules/always.md",
                "projects/*/subprojects/*/.claude/skills/*/SKILL.md"):
        out.extend(ROOT.glob(pat))
    keep = []
    for p in out:
        parts = p.parts
        if any(seg.startswith("_") for seg in parts[len(ROOT.parts):-1]):
            continue
        if p.name.startswith("_"):
            continue
        if p.exists():
            keep.append(p)
    return sorted(set(keep))


def statement_of(line: str) -> str | None:
    """行から主文を取り出す。 主文でなければ None。"""
    s = line.strip()
    if not s:
        return None
    # 見出し (= level 3 以上がルール 1 本の名前)
    m = re.match(r"^(#{3,6})\s+(.*)$", s)
    if m:
        return m.group(2)
    # 太字で始まる箇条書き (= 強調された短文 1 行)
    m = re.match(r"^[-*]\s+\*\*(.+?)\*\*(.*)$", s)
    if m:
        head = m.group(1)
        if head.rstrip(":： ").split()[0] in EXEMPT_PREFIX:
            return None
        return head
    return None


def violations_in(text: str) -> list[tuple[int, str]]:
    hits = []
    in_fence = False
    for i, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        stmt = statement_of(line)
        if stmt is None:
            continue
        for rx in DROP:
            stmt = rx.sub(" ", stmt)
        for clause in CLAUSE_SPLIT.split(stmt):
            c = clause.strip().rstrip("。 ").strip()
            if not c or any(c.endswith(a) for a in ADJECTIVE_NAI):
                continue
            if NEGATIVE_TAIL.search(c):
                hits.append((i, c))
                break
    return hits


FIXTURE_BAD = """\
### 役割が違う file を同じ階層に並べない

- **落ちた段だけ直して投げ直さない** ― 通る道を最後まで静的に読む
"""

FIXTURE_CLEAN = """\
### file は役割ごとに folder で分ける

- **通る道を最後まで静的に読んでから直す** (= 落ちた段だけ直して投げ直すと往復が増える)
  - Why: もっともらしい原因への飛びつきは別経路 leak で再発しない
"""


def selftest() -> int:
    bad = violations_in(FIXTURE_BAD)
    clean = violations_in(FIXTURE_CLEAN)
    ok = len(bad) == 2 and len(clean) == 0
    print(f"bad fixture  -> {len(bad)} 件 (期待 2): {[c for _, c in bad]}")
    print(f"clean fixture-> {len(clean)} 件 (期待 0): {[c for _, c in clean]}")
    print("selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    for f in rule_files():
        for lineno, clause in violations_in(f.read_text(encoding="utf-8")):
            rel = f.relative_to(ROOT)
            print(f"{rel}:{lineno}\t主文が否定形: 「{clause}」 を何をするかの形で書く")
    return 0


if __name__ == "__main__":
    sys.exit(main())
