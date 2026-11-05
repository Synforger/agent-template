"""タブのトップページ (= `<タブの folder>/index.html`) が、そのタブの説明の全部への入口になっているかを確かめる (= 説明のページを置いた後と、渡す前に人かエージェントが呼ぶ)。

使い方: `python3 -I check-tab-links.py <タブの folder>`。抜けが 1 つでもあれば一覧を出して 1 で終わる。

確かめる事:
1. タブの folder の中の `*.html` (= 説明のページ。枝の folder の中も、`_archive/` は除く) が、全部トップページから
   リンクされている。横の目次の左の一覧はトップページのリンクだけを並べるので、枝の中のページもトップから直に辿る。
   トップに `data-toc-pages` の付いた要素が在れば、左の一覧はその中のリンクだけを並べるので、その中のリンクだけを数える
2. トップページのリンクの先が、全部実在する (= `#` だけのリンクと `http` のリンクは除く)
3. メモ (= `memo.md`) に書いた file の path が、全部トップページからもリンクされている (= メモだけに入口を作らない)
4. 1 のページが、全部横の目次の部品を、ページから見た path で読んでいる (直下なら `../_common/toc-sidebar.js`、
   1 段下の枝なら `../../_common/toc-sidebar.js`)
5. 階層の `pages/_common/toc-sidebar.js` が在り、真値と同じ中身 (入れるのは隣の `install_toc.py`)

小さな検査なので、読み書きと判定を 1 file に入れている (= 規則の「役割ごとに file」から外れる理由)。
"""

import os
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote

# `python3 -I` では隣の file が import の道に乗らないので、自分の folder を足す
sys.path.insert(0, str(Path(__file__).resolve().parent))
from install_toc import COMPONENT_NAME, SCRIPT_TAG, SOURCE, pages_in  # noqa: E402

HREF_PATTERN = re.compile(r'href="([^"]+)"')
# HTML のコメントの中 (雛形の書き方の例など) はリンクにも読み込みにも数えない
HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
MEMO_PATH_PATTERN = re.compile(r"`(~/[^`]+?\.(?:html|md|pdf|pptx|docx|xlsx|png|svg))`")
SKIPPED_PREFIXES = ("#", "http://", "https://", "mailto:", "data:")
# 横の目次 (toc-sidebar.js の PAGES_MARK) と同じ印
PAGES_MARK = "data-toc-pages"


class _MarkedLinks(HTMLParser):
    """`data-toc-pages` の付いた要素の中のリンクの href を集める。印の要素と同じ名前の tag の開け閉めで中を追う。"""

    def __init__(self) -> None:
        super().__init__()
        self.is_marked = False
        self.hrefs: list[str] = []
        self._tag = ""
        self._depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        names = dict(attrs)
        if self._depth:
            if tag == self._tag:
                self._depth += 1
            if tag == "a" and names.get("href"):
                self.hrefs.append(names["href"] or "")
        elif PAGES_MARK in names:
            self.is_marked = True
            self._tag = tag
            self._depth = 1

    def handle_endtag(self, tag: str) -> None:
        if self._depth and tag == self._tag:
            self._depth -= 1


def linked_targets(index_path: Path) -> tuple[set[Path], set[Path], list[str]]:
    """トップページの全部のリンクの先 (実在する物)、そのうち横の目次の左の一覧に出るリンクの先、実在しないリンクを返す。"""
    html = HTML_COMMENT.sub("", index_path.read_text(encoding="utf-8"))
    marked = _MarkedLinks()
    marked.feed(html)
    all_targets: set[Path] = set()
    missing: list[str] = []
    for href in HREF_PATTERN.findall(html):
        target = _target_of(index_path, href)
        if target is None:
            continue
        if target.exists():
            all_targets.add(target)
        else:
            missing.append(href)
    if not marked.is_marked:
        return all_targets, all_targets, missing
    listed = {t for t in (_target_of(index_path, href) for href in marked.hrefs) if t is not None and t.exists()}
    return all_targets, listed, missing


def _target_of(index_path: Path, href: str) -> Path | None:
    """リンクの先の file の path。ページの外へのリンクと `#` だけのリンクは None。"""
    if href.startswith(SKIPPED_PREFIXES):
        return None
    return (index_path.parent / unquote(href.split("#", 1)[0])).resolve()


def check(tab_dir: Path) -> list[str]:
    """抜けを 1 行ずつの文で返す (= 無ければ空の並び)。"""
    # `.` で渡されても階層の `_common/` を 1 つ上に辿れるように、絶対の path にしてから見る
    tab_dir = tab_dir.resolve()
    index_path = tab_dir / "index.html"
    if not index_path.is_file():
        return [f"トップページが無い: {index_path}"]
    targets, listed, missing = linked_targets(index_path)
    problems = [f"リンクの先が無い: {href}" for href in missing]
    pages = pages_in(tab_dir)
    for page in pages:
        if page.resolve() != index_path.resolve() and page.resolve() not in listed:
            where = f"`{PAGES_MARK}` の範囲" if listed is not targets else "トップページ"
            problems.append(f"{where}から辿れないページ: {page.relative_to(tab_dir)}")
    memo_path = tab_dir / "memo.md"
    if memo_path.is_file():
        for written in MEMO_PATH_PATTERN.findall(memo_path.read_text(encoding="utf-8")):
            target = Path(written).expanduser().resolve()
            if target == index_path.resolve():
                continue
            if target not in targets:
                problems.append(f"メモにだけ書かれ、トップページから辿れない: {written}")
    component = tab_dir.parent / "_common" / COMPONENT_NAME
    for page in pages:
        expected_src = os.path.relpath(component, page.parent)
        found = SCRIPT_TAG.search(HTML_COMMENT.sub("", page.read_text(encoding="utf-8")))
        if not found:
            problems.append(f"横の目次を読む行が無い: {page.relative_to(tab_dir)} (install_toc.py で入れる)")
        elif found.group(1) != expected_src:
            problems.append(f"横の目次を読む path が違う: {page.relative_to(tab_dir)} は {found.group(1)}、"
                            f"正しくは {expected_src} (install_toc.py で直す)")
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
