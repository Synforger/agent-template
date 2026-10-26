#!/usr/bin/env python3
"""文を書き直した file が、書き直す前と同じ物を指しているかを確かめる。

書き直しで変えてよいのは言い回しだけで、指している物は変えない。指している物は、
`code`、「引用」、日付、URL、[発言者] の印の 5 種で、句読点と括弧の前後の空白だけの違いは
数えない。

見出しは、段と並びを変えずに文だけを直してよい。ルールの台帳は file と見出しの組で行を
引くので、見出しの文を直した file は `--update-registry` で台帳の行の見出しも書き換える。
そうすると ID と発火の記録が新しい見出しに引き継がれる。見出しの数か段が変わったら差に数える。

使い方:
  check-rewrite-keeps.py [--ref <git の ref>] [--update-registry] <file>...   既定の ref は HEAD
  check-rewrite-keeps.py --selftest

出力は file ごとに、減った物と増えた物と、文を直した見出しを 1 行ずつ。
減った物か増えた物が 1 件でも在れば exit 1。
"""
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

HEADING = re.compile(r"^(#{1,6}) (.*)$", re.M)
PATTERNS = {
    "code": re.compile(r"(?<!`)(`+)(?!`)[^\n]+?(?<!`)\1(?!`)"),
    "quote": re.compile(r"「[^」\n]*」"),
    "date": re.compile(r"\b\d{4}-\d{2}-\d{2}\b"),
    "url": re.compile(r"https?://[^\s)>\]`、。「」（）]+"),
    "speaker": re.compile(r"\[[^\]\s`]{1,24}\](?!\()"),
}
# 句読点と括弧の前後の空白は書き方の違いなので数えない
SPACING = re.compile(r"(?<=[、。「」（）])\s+|\s+(?=[、。「」（）])")


FENCE = re.compile(r"^\s*(`{3,}|~{3,})")


def fence_states(lines):
    """各行が code block の中か (囲みの行も中に数える) を返す。閉じるのは開いた印と同じ字で同じ本数以上の行だけ。"""
    opened = None
    for line in lines:
        m = FENCE.match(line)
        if opened is None:
            if m:
                opened = m.group(1)
                yield True
            else:
                yield False
        else:
            if m and m.group(1)[0] == opened[0] and len(m.group(1)) >= len(opened) and not line.strip()[len(m.group(1)):].strip():
                opened = None
            yield True


def normalize(token: str) -> str:
    return SPACING.sub("", token)


def outside_fences(text: str) -> str:
    """code block と frontmatter の `updated:` の行を除いた本文を返す。"""
    all_lines = text.splitlines()
    lines = [line for line, inside in zip(all_lines, fence_states(all_lines))
             if not inside and not line.startswith("updated:")]
    return "\n".join(lines)


def tokens(text: str) -> dict[str, Counter]:
    body = outside_fences(text)
    return {kind: Counter(normalize(m.group(0)) for m in rx.finditer(body)) for kind, rx in PATTERNS.items()}


def headings(text: str) -> list[tuple[int, str]]:
    return [(len(m.group(1)), m.group(2).strip()) for m in HEADING.finditer(outside_fences(text))]


def compare(before: str, after: str) -> tuple[list[str], list[tuple[int, str, str]]]:
    """差の行と、文を直した見出し (段, 前, 後) を返す。"""
    a, b = tokens(before), tokens(after)
    lines = []
    for kind in PATTERNS:
        for tok, n in (a[kind] - b[kind]).items():
            lines.append(f"  lost {kind} x{n}: {tok}")
        for tok, n in (b[kind] - a[kind]).items():
            lines.append(f"  added {kind} x{n}: {tok}")
    ha, hb = headings(before), headings(after)
    renamed = []
    if [lv for lv, _ in ha] != [lv for lv, _ in hb]:
        lines.append(f"  heading structure changed: {len(ha)} -> {len(hb)} headings or their levels differ")
    else:
        renamed = [(lv, old, new) for (lv, old), (_, new) in zip(ha, hb) if old != new]
    return lines, renamed


def crumbs(heads: list[tuple[int, str]]) -> list[tuple[str, str]]:
    """台帳と同じ H2 / H3 の (見出し, 道筋) を並びのまま返す。"""
    out, h2 = [], None
    for lv, text in heads:
        if lv == 2:
            h2 = text
            out.append((text, text))
        elif lv == 3:
            out.append((text, f"{h2} > {text}" if h2 else text))
    return out


def registry_of(rel: Path) -> Path:
    parts = rel.parts
    if len(parts) >= 4 and parts[0] == "projects" and parts[2] == "subprojects":
        return ROOT.joinpath(*parts[:4], "rules", "registry.jsonl")
    if len(parts) >= 2 and parts[0] == "projects":
        return ROOT.joinpath(*parts[:2], "rules", "registry.jsonl")
    return ROOT / "rules" / "registry.jsonl"


def update_registry(path: Path, before: str, after: str) -> int:
    """文を直した見出しの台帳の行を、新しい見出しと道筋に書き換える。書き換えた行の数を返す。"""
    rel = path.resolve().relative_to(ROOT)
    old, new = crumbs(headings(before)), crumbs(headings(after))
    moves = {o: n for o, n in zip(old, new) if o != n}
    if not moves:
        return 0
    reg = registry_of(rel)
    rows = [json.loads(ln) for ln in reg.read_text(encoding="utf-8").splitlines() if ln.strip()]
    changed = 0
    for row in rows:
        if row["file"] != rel.as_posix() or row.get("retired"):
            continue
        key = (row["heading"], row["path"])
        if key in moves:
            row["heading"], row["path"] = moves[key]
            changed += 1
    reg.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    return changed


def show(ref: str, path: Path) -> str:
    top = subprocess.run(["git", "-C", str(path.resolve().parent), "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True, check=True).stdout.strip()
    rel = path.resolve().relative_to(Path(top).resolve())
    return subprocess.run(["git", "-C", top, "show", f"{ref}:{rel.as_posix()}"],
                          capture_output=True, text=True, check=True).stdout


SAMPLE_BEFORE = """\
### 基本

- 「環境がない」 を理由に断らない (= 実際に無いことを確かめてから言う、 2026-10-20 [操作者])
- commit は `git commit` で行う
"""
SAMPLE_SAME = """\
### 基本

- 「環境がない」と言うのは、実際に無いことを確かめてからにする (2026-10-20 [操作者])。
- commit は `git commit` で行う。
"""
SAMPLE_CHANGED = """\
### 基本の決まり

- 環境が無いと言うのは、確かめてからにする (2026-10-21)。
- commit は `git commit -m` で行う。
"""


def selftest() -> int:
    same, same_renamed = compare(SAMPLE_BEFORE, SAMPLE_SAME)
    changed, renamed = compare(SAMPLE_BEFORE, SAMPLE_CHANGED)
    moved, _ = compare(SAMPLE_BEFORE, SAMPLE_BEFORE.replace("### 基本", "#### 基本"))
    # 変えた方は、code と日付が入れ替わり、引用と発言者が消える。減った 4 行と増えた 2 行。
    # 見出しは段が同じなので差に数えず、直した見出し 1 本として出る
    ok = (not same and not same_renamed and len(changed) == 6
          and renamed == [(3, "基本", "基本の決まり")] and len(moved) == 1)
    print(f"same sample    -> {len(same)} 行 (期待 0)")
    print(f"changed sample -> {len(changed)} 行 (期待 6)、直した見出し {renamed}")
    print(f"level changed  -> {len(moved)} 行 (期待 1)")
    for line in changed + moved:
        print(line)
    print("selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    ref = "HEAD"
    write = "--update-registry" in argv
    argv = [a for a in argv if a != "--update-registry"]
    if "--ref" in argv:
        i = argv.index("--ref")
        ref = argv[i + 1]
        del argv[i:i + 2]
    if not argv:
        print("usage: check-rewrite-keeps.py [--ref <ref>] [--update-registry] <file>...", file=sys.stderr)
        return 2
    bad = 0
    for name in argv:
        path = Path(name)
        before, after = show(ref, path), path.read_text(encoding="utf-8")
        diff, renamed = compare(before, after)
        if diff:
            bad += 1
            print(f"differs: {name}")
            print("\n".join(diff))
        else:
            print(f"same: {name}")
        for lv, old, new in renamed:
            print(f"  heading {'#' * lv} {old} -> {new}")
        if write and renamed and not diff:
            print(f"  registry rows updated: {update_registry(path, before, after)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
