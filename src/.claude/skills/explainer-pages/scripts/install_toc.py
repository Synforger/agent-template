"""説明のページに横の目次の部品を入れる (説明のページを置いた後と、階層の pages/ を作った後に、人かエージェントが呼ぶ)。

使い方: `python3 -I install_toc.py <ページの file か folder>...`。folder なら中の `*.html` を全部 (`_archive/` を除く)。

する事:
1. ページの階層 (`vision.md` の在る一番近い folder) の `pages/_common/toc-sidebar.js` を、真値と同じ中身にする。
   真値はエージェントの根の `pages/_common/toc-sidebar.js` で、根の階層のページはそれをそのまま読む
2. ページの `</body>` の前に、その file を読む 1 行を足す。path はページから階層の `pages/_common/` への相対で、
   タブの folder のページなら `../_common/toc-sidebar.js`、その中の枝の folder のページなら `../../_common/toc-sidebar.js`。
   既に読む行が在れば、path だけを直す。枝の中のページのタブのトップは、部品が自分の置き場から決める
3. 2 回流しても増えない。file ごとに added / fixed / ok を 1 行ずつ出す
4. 組み立ての元は触らずに skipped と出す。元とみなすのは、階層から見て `src/` の下の file と、名前に `template` を
   含む `.html`。書き出し先から見た path は、
   この file の置き場からは決まらないので、元には人が書き出し先から見た path で 1 行を入れる

小さな道具なので、読み書きと判定を 1 file に入れている (規則の「役割ごとに file」から外れる理由)。
"""

import os
import re
import shutil
import sys
from pathlib import Path

AGENT_DIR = Path(__file__).resolve().parents[4]
COMPONENT_NAME = "toc-sidebar.js"
SOURCE = AGENT_DIR / "pages" / "_common" / COMPONENT_NAME
TIER_MARKER = "vision.md"
SCRIPT_TAG = re.compile(r'<script\b[^>]*\bsrc="([^"]*' + re.escape(COMPONENT_NAME) + r')"[^>]*>\s*</script>')
BODY_END = re.compile(r"</body\s*>", re.IGNORECASE)
SKIPPED_FOLDER = "_archive"
BUILD_SOURCE_FOLDER = "src"
BUILD_TEMPLATE_WORD = "template"


def tier_of(page: Path) -> Path:
    """ページの階層の folder (`vision.md` の在る一番近い folder)。見つからなければエージェントの根。"""
    for folder in page.resolve().parents:
        if (folder / TIER_MARKER).is_file():
            return folder
        if folder == AGENT_DIR:
            break
    return AGENT_DIR


def component_for(tier: Path) -> Path:
    """その階層のページが読む部品の file。"""
    return tier / "pages" / "_common" / COMPONENT_NAME


def tagged(html: str, src: str) -> tuple[str, str]:
    """→ (新しい本文, added / fixed / ok)。読む行が無ければ `</body>` の前に足し、在れば path を src に揃える。"""
    tag = f'<script src="{src}" defer></script>'
    found = SCRIPT_TAG.search(html)
    if found:
        if found.group(1) == src:
            return html, "ok"
        return html[:found.start()] + tag + html[found.end():], "fixed"
    ends = list(BODY_END.finditer(html))
    if not ends:
        return html.rstrip("\n") + "\n" + tag + "\n", "added"
    at = ends[-1].start()
    return html[:at] + tag + "\n" + html[at:], "added"


def pages_in(target: Path) -> list[Path]:
    """渡された file か folder から、目次を入れるページの並び。"""
    if target.is_file():
        return [target]
    return sorted(p for p in target.rglob("*.html") if SKIPPED_FOLDER not in p.parts)


def is_build_source(page: Path) -> bool:
    """組み立ての元か。`src/` は階層から見た相対の path で見る (根が `src/` の下に在る repo でも全部を飛ばさない)。"""
    inside_tier = page.resolve().relative_to(tier_of(page)).parts[:-1]
    return BUILD_SOURCE_FOLDER in inside_tier or BUILD_TEMPLATE_WORD in page.name.lower()


def install(page: Path) -> str:
    """ページ 1 本に部品を入れ、結果の 1 語を返す。"""
    if is_build_source(page):
        return "skipped"
    component = component_for(tier_of(page))
    if component.resolve() != SOURCE and (not component.is_file() or component.read_bytes() != SOURCE.read_bytes()):
        component.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SOURCE, component)
    src = os.path.relpath(component, page.resolve().parent)
    html = page.read_text(encoding="utf-8")
    new_html, result = tagged(html, src)
    if new_html != html:
        page.write_text(new_html, encoding="utf-8")
    return result


def main() -> int:
    """引数の file と folder のページに部品を入れ、1 本ずつ結果を出す。"""
    if len(sys.argv) < 2:
        print("使い方: python3 -I install_toc.py <ページの file か folder>...", file=sys.stderr)
        return 2
    if not SOURCE.is_file():
        print(f"部品の真値が無い: {SOURCE}", file=sys.stderr)
        return 1
    outside = 0
    for target in (Path(arg).expanduser() for arg in sys.argv[1:]):
        for page in pages_in(target):
            if not page.resolve().is_relative_to(AGENT_DIR):
                print(f"outside: {page} (この道具のエージェントの folder {AGENT_DIR} の外。そのエージェントの道具で流す)")
                outside += 1
                continue
            print(f"{install(page)}: {page}")
    return 1 if outside else 0


if __name__ == "__main__":
    sys.exit(main())
