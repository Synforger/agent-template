"""タブのトップページ (= `<タブの folder>/index.html`) が、そのタブの説明の全部への入口になっているかを確かめる (= 説明のページを置いた後と、渡す前に人かエージェントが呼ぶ)。

使い方: `python3 -I check-tab-links.py <タブの folder>`。抜けが 1 つでもあれば一覧を出して 1 で終わる。

確かめる事:
1. タブの folder の直下の `*.html` (= 説明のページ) が、全部トップページからリンクされている
2. トップページのリンクの先が、全部実在する (= `#` だけのリンクと `http` のリンクは除く)
3. メモ (= `memo.md`) に書いた file の path が、全部トップページからもリンクされている (= メモだけに入口を作らない)
4. 直下の `*.html` が、全部横の目次の部品 (`../_common/toc-sidebar.js`) を読んでいる
5. 階層の `pages/_common/toc-sidebar.js` が在り、真値と同じ中身 (入れるのは隣の `install_toc.py`)

小さな検査なので、読み書きと判定を 1 file に入れている (= 規則の「役割ごとに file」から外れる理由)。
"""

import re
import sys
from pathlib import Path
from urllib.parse import unquote

# `python3 -I` では隣の file が import の道に乗らないので、自分の folder を足す
sys.path.insert(0, str(Path(__file__).resolve().parent))
from install_toc import COMPONENT_NAME, SCRIPT_TAG, SOURCE  # noqa: E402

TAB_COMPONENT_SRC = f"../_common/{COMPONENT_NAME}"

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
    for page in sorted(tab_dir.glob("*.html")):
        found = SCRIPT_TAG.search(page.read_text(encoding="utf-8"))
        if not found or found.group(1) != TAB_COMPONENT_SRC:
            problems.append(f"横の目次を読む行が無い: {page.name} (install_toc.py で入れる)")
    component = tab_dir.parent / "_common" / COMPONENT_NAME
    if not component.is_file():
        problems.append(f"横の目次の部品が無い: {component} (install_toc.py で入れる)")
    elif component.resolve() != SOURCE and component.read_bytes() != SOURCE.read_bytes():
        problems.append(f"横の目次の部品が真値と違う: {component} (install_toc.py で写し直す)")
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
