#!/usr/bin/env python3
"""起動した階層の `pages/` の下に、この階層の生きているタブの物でない folder が残っていないかと、階層のトップ
`pages/index.html` がこの階層のタブの説明のページへ辿れるかを出す (起動の検査 startup-status.sh が呼ぶ)。

使い方: `python3 pages_orphans.py [--root DIR] [--tier TIER] [--live-ids FILE]`。
- 階層は `--tier`、無ければ環境変数 `AGENT_TIER` (無ければ `normal`)。`normal` は根の `pages/`、ほかは `<階層>/pages/`
- 生きているタブの id と階層は `--live-ids` の file (1 行に `<id> [<階層>]`) から、無ければ `tabs list` の各行の
  頭の id と 2 つ目の欄の階層から読む。階層が分かるのは `normal` と `projects/…` の欄だけで、境界の外・別の機械・
  別のエージェントのタブは階層が伏せてあるので、分からない物として扱う。別の機械のタブ (`home:ses_…`) は機械の名前を
  外して数える。git で配られた別の機械のタブの folder を残り物にしないため
- 生きているタブでも、階層が分かって今の階層と違うタブの folder は「別の階層のタブ」として数える。タブが別の
  階層へ移った後に、元の階層に残った folder が当たる
- 階層のトップのリンクを読み、説明のページ (タブのトップ以外の html) を持つ、この階層の生きているタブの folder を
  指していない物を「階層のトップから辿れない」、リンクの先が無い物を「階層のトップの無いリンク先」として数える。
  階層の分からないタブはここでも数えない
- `_` で始まる folder (雛形・部品・退避) は数えない
- `tabs list` に出たこの機械のタブの id (別の機械の行を除く) を、機械ごとの状態
  `$AGENT_PLATFORM_ROOT/state/pages-orphans/seen-tabs.txt` (無ければ `~/.local/state/agent-pages-orphans/`) に貯める。
  git に載っていて、一度もこの機械で見ていない id の folder は残り物に数えず、「別の機械のタブか不明」として
  数の外に出す。別の機械の一覧には、連絡できない口座のタブが載らず、閉じた物と見分けられないため
- 出すのは 1 行: `pages_orphans: <数> (中身あり <数>: <id>… / 雛形だけ <数>: <id>…)`。中身ありは、タブのトップ
  `index.html` とメモ `memo.md` の外に file を 1 つでも持つ folder。上の 3 つは、在る時だけ
  ` / 別の階層のタブ <数>: <id>→<階層>…`・` / 階層のトップから辿れない <数>: <id>…`・
  ` / 階層のトップの無いリンク先 <数>: <href>…` を後ろに足す。一覧が読めない時は `pages_orphans: UNKNOWN (<理由>)`
- git に 1 file も載っていない folder (= この機械にしか無い物。別の機械へは渡らず、消さない限り残る) は、id の後ろに
  `(<日数>日)` を付ける。日数は folder の中の一番新しい file の時刻から数える。git の様子が読めない時は、全部を載っていない物として扱う

小さな検査なので、読み書きと判定を 1 file に入れている (規則の「役割ごとに file」から外れる理由)。
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

TOP_PAGE = "index.html"
MEMO = "memo.md"
SKIPPED_PREFIX = "_"
TAB_ID_PREFIX = "ses_"
SEEN_FILE = "seen-tabs.txt"
UNKNOWN_GROUP = "別の機械のタブか不明"
NORMAL_TIER = "normal"
TABS_TIMEOUT_S = 20
GIT_TIMEOUT_S = 20
SECONDS_PER_DAY = 86400
HREF_PATTERN = re.compile(r'href="([^"]+)"')
# HTML のコメントの中 (雛形の書き方の例など) はリンクに数えない
HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
# 階層のトップのリンクのうち、pages/ の中の file を指さない物
OUTSIDE_LINK_PREFIXES = ("#", "http://", "https://", "mailto:", "data:")
# tabs list の 2 つ目の欄のうち、このエージェントの階層を名乗る物
KNOWN_TIER_PREFIX = "projects/"


def pages_folder(root: Path, tier: str) -> Path:
    """階層の `pages/` の folder。"""
    return root / "pages" if tier in ("", NORMAL_TIER) else root / tier / "pages"


def known_tier(word: str) -> str | None:
    """`tabs list` の階層の欄の語が、このエージェントの階層を名乗っていればその階層。伏せてあれば None。"""
    return word if word == NORMAL_TIER or word.startswith(KNOWN_TIER_PREFIX) else None


def live_tabs_from_list(text: str) -> dict[str, str | None]:
    """`tabs list` の出力から、生きているタブの id → 階層 (分からなければ None)。別の機械の `<機械>:<id>` は id だけにする。"""
    tabs: dict[str, str | None] = {}
    for line in text.splitlines():
        words = line.split()
        if not words:
            continue
        machine_and_id = words[0].rsplit(":", 1)
        tier = known_tier(words[1]) if len(words) > 1 and len(machine_and_id) == 1 else None
        tabs[machine_and_id[-1]] = tier
    return tabs


def local_tab_ids(text: str) -> set[str]:
    """`tabs list` の出力のうち、この機械のタブの id。別の機械の `<機械>:<id>` は入れない。"""
    first_words = (line.split()[0] for line in text.splitlines() if line.split())
    return {word for word in first_words if word.startswith(TAB_ID_PREFIX)}


def seen_file() -> Path:
    """この機械で見たタブの id を貯める file。"""
    root = os.environ.get("AGENT_PLATFORM_ROOT")
    folder = Path(root) / "state" / "pages-orphans" if root else Path.home() / ".local" / "state" / "agent-pages-orphans"
    return folder / SEEN_FILE


def load_seen_tabs() -> set[str]:
    """この機械で見たタブの id (読めなければ空)。"""
    try:
        return set(seen_file().read_text(encoding="utf-8").split())
    except OSError:
        return set()


def save_seen_tabs(ids: set[str]) -> None:
    """まだ貯めていない id を足す (書けなければ何もしない)。"""
    new = sorted(ids - load_seen_tabs())
    if not new:
        return
    try:
        seen_file().parent.mkdir(parents=True, exist_ok=True)
        with seen_file().open("a", encoding="utf-8") as handle:
            handle.write("".join(f"{tab_id}\n" for tab_id in new))
    except OSError:
        return


def has_pages(folder: Path) -> bool:
    """タブのトップの外に、説明のページ (html) を 1 つでも持つか。`_archive/` の下は数えない。"""
    return any(p.is_file() and p.suffix == ".html" and p.relative_to(folder).as_posix() != TOP_PAGE
               and "_archive" not in p.relative_to(folder).parts for p in folder.rglob("*"))


def has_content(folder: Path) -> bool:
    """タブのトップとメモの外に file を 1 つでも持つか。"""
    return any(p.is_file() and p.relative_to(folder).as_posix() not in (TOP_PAGE, MEMO) for p in folder.rglob("*"))


def tracked_folders(pages: Path) -> set[str]:
    """`pages/` の直下の folder のうち、git に file が 1 つでも載っている物の名前。git が読めない時は空 (= 全部が載っていない扱い)。"""
    try:
        done = subprocess.run(["git", "-C", str(pages), "ls-files", "-z", "--", "."], capture_output=True, text=True,
                              timeout=GIT_TIMEOUT_S, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return set()
    if done.returncode != 0:
        return set()
    return {path.split("/", 1)[0] for path in done.stdout.split("\0") if "/" in path}


def idle_days(folder: Path, now_s: float) -> int:
    """folder の中の一番新しい file の時刻から、今までに経った日数 (file が 1 つも無ければ folder 自身の時刻)。"""
    newest_s = max((p.stat().st_mtime for p in folder.rglob("*") if p.is_file()), default=folder.stat().st_mtime)
    return max(0, int((now_s - newest_s) // SECONDS_PER_DAY))


def tab_folders(pages: Path) -> list[Path]:
    """`pages/` の直下のタブの folder (`_` で始まる物を除く)。名前順。"""
    return sorted(p for p in pages.iterdir() if p.is_dir() and not p.name.startswith(SKIPPED_PREFIX))


def orphans(pages: Path, live_tabs: dict[str, str | None], seen_tabs: set[str], tier: str,
            now_s: float) -> tuple[list[str], list[str], list[str], list[str]]:
    """→ (中身ありの folder 名, 雛形だけの folder 名, 別の階層のタブの `<id>→<階層>`, 別の機械のタブか不明の folder 名)。どれも名前順。
    git に載っていない folder の名前には `(<日数>日)` が付く。"""
    tracked = tracked_folders(pages)
    with_content: list[str] = []
    template_only: list[str] = []
    moved: list[str] = []
    unknown: list[str] = []
    for folder in tab_folders(pages):
        if folder.name in live_tabs:
            other_tier = live_tabs[folder.name]
            if other_tier is not None and other_tier != tier:
                moved.append(f"{folder.name}→{other_tier}")
            continue
        if folder.name in tracked and folder.name not in seen_tabs:
            unknown.append(folder.name)
            continue
        label = folder.name if folder.name in tracked else f"{folder.name}({idle_days(folder, now_s)}日)"
        (with_content if has_content(folder) else template_only).append(label)
    return with_content, template_only, moved, unknown


def top_page_gaps(pages: Path, live_tabs: dict[str, str | None], tier: str) -> tuple[list[str], list[str]]:
    """階層のトップについて → (説明のページを持つのに指されていない、この階層の生きているタブの id, 先の無いリンク)。"""
    top = pages / TOP_PAGE
    hrefs = HREF_PATTERN.findall(HTML_COMMENT.sub("", top.read_text(encoding="utf-8"))) if top.is_file() else []
    linked_tabs: set[str] = set()
    missing: list[str] = []
    for href in hrefs:
        if href.startswith(OUTSIDE_LINK_PREFIXES):
            continue
        target = (pages / href.split("#", 1)[0]).resolve()
        if not target.exists():
            missing.append(href)
        elif target.is_relative_to(pages.resolve()) and target != pages.resolve():
            linked_tabs.add(target.relative_to(pages.resolve()).parts[0])
    unlinked = [folder.name for folder in tab_folders(pages)
                if live_tabs.get(folder.name) == tier and folder.name not in linked_tabs and has_pages(folder)]
    return unlinked, missing


def read_live_tabs(path: str | None) -> dict[str, str | None] | str:
    """生きているタブの id → 階層 (分からなければ None)。読めない時は理由の文字列。`tabs list` から読んだ時は、この機械のタブの id を貯める。"""
    if path:
        tabs: dict[str, str | None] = {}
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            words = line.split()
            if words:
                tabs[words[0]] = known_tier(words[1]) if len(words) > 1 else None
        return tabs
    if not shutil.which("tabs"):
        return "tabs が無い"
    try:
        done = subprocess.run(["tabs", "list"], capture_output=True, text=True, timeout=TABS_TIMEOUT_S, check=False)
    except subprocess.TimeoutExpired:
        return f"tabs list が {TABS_TIMEOUT_S} 秒で返らない"
    if done.returncode != 0 or not done.stdout.strip():
        return "tabs list が読めない (PWA のタブの外)"
    save_seen_tabs(local_tab_ids(done.stdout))
    return live_tabs_from_list(done.stdout)


def option(argv: list[str], name: str) -> str | None:
    """`--name value` の値。無ければ None。"""
    if name not in argv or argv.index(name) + 1 >= len(argv):
        return None
    return argv[argv.index(name) + 1]


def main(argv: list[str]) -> int:
    """起動した階層の pages/ の残り物を 1 行で出す。"""
    root = Path(option(argv, "--root") or Path(__file__).resolve().parents[2])
    tier = option(argv, "--tier") or os.environ.get("AGENT_TIER", NORMAL_TIER)
    pages = pages_folder(root, tier)
    if not pages.is_dir():
        print("pages_orphans: 0 (この階層に pages/ が無い)")
        return 0
    live_tabs = read_live_tabs(option(argv, "--live-ids"))
    if isinstance(live_tabs, str):
        print(f"pages_orphans: UNKNOWN ({live_tabs})")
        return 0
    tier = tier if tier else NORMAL_TIER
    with_content, template_only, moved, unknown = orphans(pages, live_tabs, load_seen_tabs(), tier, time.time())
    unlinked, missing = top_page_gaps(pages, live_tabs, tier)
    count = len(with_content) + len(template_only) + len(moved) + len(unlinked) + len(missing)
    unknown_group = f"{UNKNOWN_GROUP} {len(unknown)}: {' '.join(unknown)}" if unknown else ""
    if not count:
        print(f"pages_orphans: 0 ({unknown_group})" if unknown else "pages_orphans: 0")
        return 0
    groups = [f"中身あり {len(with_content)}: {' '.join(with_content) or '-'}",
              f"雛形だけ {len(template_only)}: {' '.join(template_only) or '-'}"]
    for name, items in (("別の階層のタブ", moved), ("階層のトップから辿れない", unlinked),
                        ("階層のトップの無いリンク先", missing)):
        if items:
            groups.append(f"{name} {len(items)}: {' '.join(items)}")
    if unknown:
        groups.append(unknown_group)
    print(f"pages_orphans: {count} ({' / '.join(groups)})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
