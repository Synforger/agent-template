"""タブのトップページ (= `<タブの folder>/index.html`) が、そのタブの説明の全部への入口になっているかを確かめる (= 説明のページを置いた後と、渡す前に人かエージェントが呼ぶ)。

使い方: `python3 -I check-tab-links.py <タブの folder>`。抜けが 1 つでもあれば一覧を出して 1 で終わる。

確かめる事:
1. タブの folder の直下の `*.html` (= 説明のページ) が、全部トップページからリンクされている
2. トップページのリンクの先が、全部実在する (= `#` だけのリンクと `http` のリンクは除く)
3. メモ (= `memo.md`) に書いた file の path が、全部トップページからもリンクされている (= メモだけに入口を作らない)

小さな検査なので、読み書きと判定を 1 file に入れている (= 規則の「役割ごとに file」から外れる理由)。
"""

import re
import sys
from pathlib import Path
from urllib.parse import unquote

HREF_PATTERN = re.compile(r'href="([^"]+)"')
MEMO_PATH_PATTERN = re.compile(r"`(~/[^`]+?\.(?:html|md|pdf|pptx|docx|xlsx|png|svg))`")
SKIPPED_PREFIXES = ("#", "http://", "https://", "mailto:", "data:")


def linked_targets(index_path: Path) -> tuple[set[Path], list[str]]:
    """トップページのリンクの先 (= 実在する物) と、実在しないリンクを返す。"""
    targets: set[Path] = set()
    missing: list[str] = []
    for href in HREF_PATTERN.findall(index_path.read_text(encoding="utf-8")):
        if href.startswith(SKIPPED_PREFIXES):
            continue
        path_part = unquote(href.split("#", 1)[0])
        target = (index_path.parent / path_part).resolve()
        if target.exists():
            targets.add(target)
        else:
            missing.append(href)
    return targets, missing


def check(tab_dir: Path) -> list[str]:
    """抜けを 1 行ずつの文で返す (= 無ければ空の並び)。"""
    index_path = tab_dir / "index.html"
    if not index_path.is_file():
        return [f"トップページが無い: {index_path}"]
    targets, missing = linked_targets(index_path)
    problems = [f"リンクの先が無い: {href}" for href in missing]
    for page in sorted(tab_dir.glob("*.html")):
        if page.name != "index.html" and page.resolve() not in targets:
            problems.append(f"トップページから辿れないページ: {page.name}")
    memo_path = tab_dir / "memo.md"
    if memo_path.is_file():
        for written in MEMO_PATH_PATTERN.findall(memo_path.read_text(encoding="utf-8")):
            target = Path(written).expanduser().resolve()
            if target == index_path.resolve():
                continue
            if target not in targets:
                problems.append(f"メモにだけ書かれ、トップページから辿れない: {written}")
    return problems


def main() -> int:
    """引数のタブの folder を確かめ、抜けを出す。"""
    if len(sys.argv) != 2:
        print("使い方: python3 -I check-tab-links.py <タブの folder>", file=sys.stderr)
        return 2
    tab_dir = Path(sys.argv[1]).expanduser()
    problems = check(tab_dir)
    for problem in problems:
        print(problem)
    if problems:
        return 1
    print(f"ok: {tab_dir} のトップページから全部辿れる")
    return 0


if __name__ == "__main__":
    sys.exit(main())
