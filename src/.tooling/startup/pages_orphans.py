#!/usr/bin/env python3
"""起動した階層の `pages/` の下に、生きているタブの物でない folder が残っていないかを出す (起動の検査 startup-status.sh が呼ぶ)。

使い方: `python3 pages_orphans.py [--root DIR] [--tier TIER] [--live-ids FILE]`。
- 階層は `--tier`、無ければ環境変数 `AGENT_TIER` (無ければ `normal`)。`normal` は根の `pages/`、ほかは `<階層>/pages/`
- 生きているタブの id は `--live-ids` の file (1 行 1 id) から、無ければ `tabs list` の各行の頭の id から読む。
  別の機械のタブ (`home:ses_…`) は機械の名前を外して数える。git で配られた別の機械のタブの folder を残り物にしないため
- `_` で始まる folder (雛形・部品・退避) は数えない
- 出すのは 1 行: `pages_orphans: <数> (中身あり <数>: <id>… / 雛形だけ <数>: <id>…)`。中身ありは、タブのトップ
  `index.html` とメモ `memo.md` の外に file を 1 つでも持つ folder。一覧が読めない時は `pages_orphans: UNKNOWN (<理由>)`

小さな検査なので、読み書きと判定を 1 file に入れている (規則の「役割ごとに file」から外れる理由)。
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

TOP_PAGE = "index.html"
MEMO = "memo.md"
SKIPPED_PREFIX = "_"
NORMAL_TIER = "normal"
TABS_TIMEOUT_S = 20


def pages_folder(root: Path, tier: str) -> Path:
    """階層の `pages/` の folder。"""
    return root / "pages" if tier in ("", NORMAL_TIER) else root / tier / "pages"


def live_ids_from_list(text: str) -> set[str]:
    """`tabs list` の出力から、生きているタブの id の集合。別の機械の `<機械>:<id>` は id だけにする。"""
    ids: set[str] = set()
    for line in text.splitlines():
        words = line.split()
        if words:
            ids.add(words[0].rsplit(":", 1)[-1])
    return ids


def has_content(folder: Path) -> bool:
    """タブのトップとメモの外に file を 1 つでも持つか。"""
    return any(p.is_file() and p.relative_to(folder).as_posix() not in (TOP_PAGE, MEMO) for p in folder.rglob("*"))


def orphans(pages: Path, live_ids: set[str]) -> tuple[list[str], list[str]]:
    """→ (中身ありの folder 名, 雛形だけの folder 名)。どちらも名前順。"""
    with_content: list[str] = []
    template_only: list[str] = []
    for folder in sorted(p for p in pages.iterdir() if p.is_dir() and not p.name.startswith(SKIPPED_PREFIX)):
        if folder.name in live_ids:
            continue
        (with_content if has_content(folder) else template_only).append(folder.name)
    return with_content, template_only


def read_live_ids(path: str | None) -> set[str] | str:
    """生きているタブの id の集合。読めない時は理由の文字列。"""
    if path:
        return {line.strip() for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()}
    if not shutil.which("tabs"):
        return "tabs が無い"
    try:
        done = subprocess.run(["tabs", "list"], capture_output=True, text=True, timeout=TABS_TIMEOUT_S, check=False)
    except subprocess.TimeoutExpired:
        return f"tabs list が {TABS_TIMEOUT_S} 秒で返らない"
    if done.returncode != 0 or not done.stdout.strip():
        return "tabs list が読めない (PWA のタブの外)"
    return live_ids_from_list(done.stdout)


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
    live_ids = read_live_ids(option(argv, "--live-ids"))
    if isinstance(live_ids, str):
        print(f"pages_orphans: UNKNOWN ({live_ids})")
        return 0
    with_content, template_only = orphans(pages, live_ids)
    count = len(with_content) + len(template_only)
    if not count:
        print("pages_orphans: 0")
        return 0
    print(f"pages_orphans: {count} (中身あり {len(with_content)}: {' '.join(with_content) or '-'}"
          f" / 雛形だけ {len(template_only)}: {' '.join(template_only) or '-'})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
