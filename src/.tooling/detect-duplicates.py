#!/usr/bin/env python3
"""rule file の section 単位重複検出 (= LLM 不使用、 標準ライブラリのみ).

対象 file (= 起動時必読の常時 load 群):
  - CLAUDE.md
  - profile/profile-core.md
  - rules/always/*.md
  - rules/lazy/*.md

方針:
  - H2/H3 section 単位で chunk 化
  - 全 chunk ペアの最長共通部分文字列 (= LCS 簡易版) が MIN_PHRASE_LEN 以上のペアを抽出
  - 出力 = .tooling/_output/duplicates.md

起動: python3 <agent-repo-root>/.tooling/detect-duplicates.py [--summary]
完遂条件: error なく走ること、 出力が空でも OK
"""

from __future__ import annotations

import datetime
import pathlib
import re
import sys

# script 所在から ROOT を推定 (= worktree 対応)
SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent

OUT_PATH = ROOT / ".tooling" / "_output" / "duplicates.md"
ALLOWLIST_PATH = ROOT / ".tooling" / "duplicates-allowlist.txt"
# allowlist 形式: 1 行 1 ペア、 "labelA -- labelB" (= 順不同、 # 行と空行は無視)。
# reference 判定済 (= 意図的な共通 command / path 参照) のペアを恒久 suppress する。
MIN_PHRASE_LEN = 60  # 同一フレーズの最小長 (= 2026-06-24 60→90、 短コマンド片 3 件常駐の false positive 抑制)

TARGET_GLOBS = [
    "CLAUDE.md",
    "profile/profile-core.md",
    "rules/always/*.md",
    "rules/lazy/*.md",
    "projects/*/rules/always/*.md",
    "projects/*/rules/lazy/*.md",
    "projects/*/subprojects/*/rules/always/*.md",
    "projects/*/subprojects/*/rules/lazy/*.md",
]


def collect_targets() -> list[pathlib.Path]:
    targets: list[pathlib.Path] = []
    for pat in TARGET_GLOBS:
        if "*" in pat:
            targets.extend(sorted(ROOT.glob(pat)))
        else:
            p = ROOT / pat
            if p.is_file():
                targets.append(p)
    return targets


SECTION_RE = re.compile(r"^(#{2,3})\s+(.+)$", re.MULTILINE)


def chunk_by_section(path: pathlib.Path) -> list[tuple[str, str]]:
    """H2/H3 で分割、 (section_label, body) のリストを返す。"""
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return []

    # frontmatter を除去
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            text = text[end + 5 :]

    matches = list(SECTION_RE.finditer(text))
    if not matches:
        return [(f"{path.relative_to(ROOT)}:(全体)", text)]

    chunks: list[tuple[str, str]] = []
    rel = path.relative_to(ROOT)
    for i, m in enumerate(matches):
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        body = text[start:end].strip()
        if len(body) < MIN_PHRASE_LEN:
            continue
        label = f"{rel}#{m.group(2).strip()}"
        chunks.append((label, body))
    return chunks


def normalize(s: str) -> str:
    """空白系を 1 個に潰す (= 同一性比較用)。"""
    return re.sub(r"\s+", " ", s).strip()


def longest_common_substring(a: str, b: str) -> str:
    """最長共通部分文字列 (= 古典 DP、 N=M=数千字なら問題なし)。"""
    if not a or not b:
        return ""
    la, lb = len(a), len(b)
    prev = [0] * (lb + 1)
    best_len = 0
    best_end = 0
    for i in range(1, la + 1):
        curr = [0] * (lb + 1)
        ai = a[i - 1]
        for j in range(1, lb + 1):
            if ai == b[j - 1]:
                curr[j] = prev[j - 1] + 1
                if curr[j] > best_len:
                    best_len = curr[j]
                    best_end = i
        prev = curr
    return a[best_end - best_len : best_end] if best_len else ""


def load_allowlist() -> set[frozenset[str]]:
    pairs: set[frozenset[str]] = set()
    if ALLOWLIST_PATH.is_file():
        for line in ALLOWLIST_PATH.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if " -- " in line:
                a, b = line.split(" -- ", 1)
                pairs.add(frozenset((a.strip(), b.strip())))
    return pairs


def main() -> int:
    summary_mode = "--summary" in sys.argv
    allow = load_allowlist()

    targets = collect_targets()
    chunks: list[tuple[str, str]] = []
    for t in targets:
        chunks.extend(chunk_by_section(t))

    duplicates: list[tuple[str, str, str]] = []
    n = len(chunks)
    for i in range(n):
        for j in range(i + 1, n):
            label_a, body_a = chunks[i]
            label_b, body_b = chunks[j]
            # 同一 file 内は skip
            if label_a.split("#", 1)[0] == label_b.split("#", 1)[0]:
                continue
            if frozenset((label_a, label_b)) in allow:
                continue
            lcs = longest_common_substring(normalize(body_a), normalize(body_b))
            if len(lcs) >= MIN_PHRASE_LEN:
                duplicates.append((label_a, label_b, lcs))

    # Summary mode = 1 行出力で起動時 status に集約
    if summary_mode:
        print(f"duplicates: files={len(targets)} chunks={len(chunks)} dup_pairs={len(duplicates)}")
        for label_a, label_b, _ in duplicates[:3]:
            print(f"  - {label_a}  vs  {label_b}")
        return 0

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    lines.append("---")
    lines.append("title: エージェント rule file 間重複検出 (= 自動生成)")
    lines.append("description: detect-duplicates.py による section 単位重複検出結果")
    lines.append(f"generated: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"min_phrase_len: {MIN_PHRASE_LEN}")
    lines.append("---")
    lines.append("")
    lines.append("# section 重複候補")
    lines.append("")
    lines.append(
        f"走査 file 数: {len(targets)} / 走査 chunk 数: {len(chunks)} / 重複ペア: {len(duplicates)}"
    )
    lines.append("")

    if not duplicates:
        lines.append("(重複検出なし)")
    else:
        for label_a, label_b, lcs in duplicates:
            lines.append(f"## {label_a}  vs  {label_b}")
            lines.append("")
            lines.append("共通部分:")
            lines.append("```")
            lines.append(lcs[:400] + ("..." if len(lcs) > 400 else ""))
            lines.append("```")
            lines.append("")

    OUT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(
        f"detect-duplicates: {len(targets)} files / {len(chunks)} chunks / "
        f"{len(duplicates)} dup pairs = OUT: {OUT_PATH}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
