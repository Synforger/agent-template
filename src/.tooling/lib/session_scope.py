#!/usr/bin/env python3
"""過去の session の記録が、ある階層の持ち物かを、記録の作業 folder (cwd) の列から決める判定の部品 (= file にも状態にも触らない)。

呼ぶのは `session-end/extract-operator-words.py` の `--all-sessions`。 階層のタブは途中でその階層の folder に入るので、
cwd が通った階層の組を見れば、その session がどの境界を読み得たかが分かる。 読んでよいのは次の session だけ。
- エージェントの folder の下で動いた (= cwd が 1 つ以上その下に在る)
- 通った階層が、その階層と、その上の段 (project → 親) だけ。 下の段や兄弟の階層に入った session は、その階層の持ち物で、
  境界の外の記録になるので読まない
- 親 (`normal`) 以外は、その階層の folder に実際に入った
"""

from __future__ import annotations

from collections.abc import Iterable
from pathlib import Path

from tier_paths import lineage, tier_prefix

NORMAL_TIER = "normal"
FILE_PLACEHOLDER = "-"


def tier_of_folder(root: Path, folder: str) -> str | None:
    """作業 folder が属する階層の root からの path (= 親は空文字)。 エージェントの folder の外なら None。"""
    try:
        parts = Path(folder).relative_to(root).parts
    except ValueError:
        return None
    return "/".join(tier_prefix((*parts, FILE_PLACEHOLDER)))


def belongs_to(folders: Iterable[str], root: Path, tier: str) -> bool:
    """作業 folder の列が示す session が、`tier` (= `AGENT_TIER` の値) の持ち物か。"""
    own = "" if tier == NORMAL_TIER else tier
    visited = {found for folder in folders if (found := tier_of_folder(root, folder)) is not None}
    return bool(visited) and visited <= set(lineage(own)) and (own == "" or own in visited)
