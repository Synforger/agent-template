#!/usr/bin/env python3
"""階層の folder を、 サブプロが何段続いても同じ手順で列挙する部品。

階層 = `projects/<P>` と、 その下に何段でも続く `subprojects/<S>`。 `_` と `.` で始まる名前は階層ではない
(= 雛形・退避)。 検査と道具が深さを決め打ちせずに階層を数えるための 1 か所で、 呼ぶのは docs-check・
session-end・ルール台帳 (= 階層の系列と ID の頭の字も)・起動の検査。 python からは import し (= `tier_folders` / `tier_files` / `tier_prefix`)、
shell からは `python3 tier_paths.py [--root DIR] [--with-templates]` が階層の folder を root からの path で 1 行 1 件出す。
"""

from __future__ import annotations

import sys
from collections.abc import Sequence
from pathlib import Path

PROJECTS_DIR = "projects"
SUBPROJECTS_DIR = "subprojects"


def is_tier_name(name: str, *, with_templates: bool = False) -> bool:
    """階層の folder の名前か (= `.` で始まる退避ではなく、 `with_templates` でなければ `_` で始まる雛形でもない)。"""
    return not name.startswith(("." if with_templates else ("_", ".")))


def child_tiers(parent: Path, *, with_templates: bool = False) -> list[Path]:
    """`parent` (= `projects/` か `subprojects/` の folder) の直下の階層。 名前順。"""
    try:
        return sorted(d for d in parent.iterdir() if d.is_dir() and is_tier_name(d.name, with_templates=with_templates))
    except OSError:
        return []


def tier_folders(root: Path, *, with_templates: bool = False) -> list[Path]:
    """`root` の下の全階層 (= プロジェクトとサブプロ、 何段でも)。 親が子より先に並ぶ。

    `with_templates` は `_template-project` のような `_` 始まりの folder も階層として数える (= 雛形も検査する時)。"""
    found: list[Path] = []

    def walk(parent: Path) -> None:
        for folder in child_tiers(parent, with_templates=with_templates):
            found.append(folder)
            walk(folder / SUBPROJECTS_DIR)

    walk(root / PROJECTS_DIR)
    return found


def tier_files(root: Path, pattern: str, *, with_templates: bool = False) -> list[Path]:
    """全階層の folder からの相対 `pattern` に当たる実在の path (= 階層ごとに名前順)。"""
    folders = tier_folders(root, with_templates=with_templates)
    return [path for folder in folders for path in sorted(folder.glob(pattern))]


def tier_prefix(parts: Sequence[str]) -> tuple[str, ...]:
    """root からの file の path の部品から、 それを持つ一番深い階層の部品を返す (= 階層の外の path は空)。

    最後の部品は file 名として扱うので、 階層の folder 自身の path には使わない。"""
    if len(parts) < 3 or parts[0] != PROJECTS_DIR or not is_tier_name(parts[1]):
        return ()
    end = 2
    while (end + 2 < len(parts) and parts[end] == SUBPROJECTS_DIR and is_tier_name(parts[end + 1])):
        end += 2
    return tuple(parts[:end])


def lineage(tier: str) -> list[str]:
    """階層 (= root からの path。 親は空文字) から親までの系列 (= 自階層 → 一つ上の階層 → … → project → 親)。

    1 つの session が読む台帳と規則はこの中だけ。"""
    parts = tier.split("/") if tier else []
    chain = ["/".join(parts[:end]) for end in range(len(parts), 1, -2)]
    return [*chain, ""]


def id_letter(tier: str) -> str:
    """その階層のルール ID の頭の字 (= 親 `R` / project `P` / 1 段目の subproject `S` / 2 段目 `S2` / 3 段目 `S3` …)。

    ID は `<頭の字>-<4 桁>`。 1 段目までの字は `S` のまま変えず、 それより深い段は `S` に段の数を足す。"""
    if not tier:
        return "R"
    depth = tier.split("/").count(SUBPROJECTS_DIR)
    if depth == 0:
        return "P"
    return "S" if depth == 1 else f"S{depth}"


def main(argv: list[str]) -> int:
    root = Path(argv[argv.index("--root") + 1]) if "--root" in argv else Path(__file__).resolve().parents[2]
    for folder in tier_folders(root, with_templates="--with-templates" in argv):
        print(folder.relative_to(root).as_posix())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
