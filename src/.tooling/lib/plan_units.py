"""計画の file の単位の表と波の表を読み解き、波ごとの進みの木に組む。

file にも時計にも触らない判定だけの file で、呼ぶのは work/plan_run.py。表は Markdown の `|` 区切りで、
列は見出しの名前で引く (列の順が変わっても読める)。済みの印は状態の欄の頭の ✅ で、ほかは全部まだ。
"""

import re
from dataclasses import dataclass

DONE_MARK = "✅"
OPEN_MARK = "⬜"
COLUMN_ID = "単位"
COLUMN_BODY = "中身"
COLUMN_OWNER = "持つタブ"
COLUMN_AFTER = "何の後か"
COLUMN_ESTIMATE = "見積もり"
COLUMN_STATE = "状態"
NO_PREDECESSOR = "-"
TITLE_ENDS = re.compile(r"[:：。(]")
TITLE_MAX_CHARS = 40
NOTE_MAX_CHARS = 30
CELL_BORDER = re.compile(r"(?<!\\)\|")
SEPARATOR_ROW = re.compile(r"^[\s|:-]+$")
ESTIMATE_PCT = re.compile(r"(\d+(?:\.\d+)?)\s*%")
WAVE_OF_NAME = re.compile(r"^(W\d+)\s+(.+)$")


@dataclass(frozen=True)
class Unit:
    """単位の表の 1 行。"""

    unit_id: str
    wave: str
    title: str
    owner: str
    after: str
    estimate_pct: float | None
    is_done: bool
    note: str


def parse_units(text: str, heading: str) -> list[Unit]:
    """`heading` で始まる見出しの節の最初の表から、単位を表の順に返す。節か表が無ければ空。"""
    rows = _table_rows(text, heading)
    if not rows:
        return []
    columns = {name: index for index, name in enumerate(rows[0])}
    if COLUMN_ID not in columns or COLUMN_STATE not in columns:
        return []
    units: list[Unit] = []
    for cells in rows[1:]:
        unit_id = _cell(cells, columns, COLUMN_ID)
        if not unit_id:
            continue
        state = _cell(cells, columns, COLUMN_STATE)
        estimate = ESTIMATE_PCT.search(_cell(cells, columns, COLUMN_ESTIMATE))
        units.append(
            Unit(
                unit_id=unit_id,
                wave=unit_id.split("-", 1)[0],
                title=TITLE_ENDS.split(_cell(cells, columns, COLUMN_BODY), 1)[0].strip()[:TITLE_MAX_CHARS],
                owner=_cell(cells, columns, COLUMN_OWNER),
                after=_cell(cells, columns, COLUMN_AFTER),
                estimate_pct=float(estimate.group(1)) if estimate else None,
                is_done=state.startswith(DONE_MARK),
                note=state.removeprefix(OPEN_MARK).strip()[:NOTE_MAX_CHARS],
            )
        )
    return units


def parse_wave_names(text: str, heading: str) -> dict[str, str]:
    """`heading` で始まる見出しの節の最初の表の 1 列目 (`W0 <名前>`) から、波の id → 名前を返す。"""
    names: dict[str, str] = {}
    for cells in _table_rows(text, heading)[1:]:
        found = WAVE_OF_NAME.match(cells[0]) if cells else None
        if found:
            names[found.group(1)] = found.group(2)
    return names


def status_lines(units: list[Unit], wave_names: dict[str, str]) -> list[str]:
    """数の 1 行と、波ごとの ✅/⬜ の木を返す。まだの単位には持つタブ・見積もり・何の後かを添える。"""
    open_units = [unit for unit in units if not unit.is_done]
    left_pct = sum(unit.estimate_pct or 0.0 for unit in open_units)
    lines = [f"plan_status: {DONE_MARK} {len(units) - len(open_units)} / {OPEN_MARK} {len(open_units)} (単位 {len(units)}・残りの見積もり {left_pct:.1f}%)"]
    waves: dict[str, list[Unit]] = {}
    for unit in units:
        waves.setdefault(unit.wave, []).append(unit)
    for wave, members in waves.items():
        done_count = sum(unit.is_done for unit in members)
        mark = DONE_MARK if done_count == len(members) else OPEN_MARK
        name = f" {wave_names[wave]}" if wave in wave_names else ""
        lines.append(f"{mark} {wave}{name} {done_count}/{len(members)}")
        lines.extend(f"  {_unit_line(unit)}" for unit in members)
    return lines


def _unit_line(unit: Unit) -> str:
    if unit.is_done:
        return f"{DONE_MARK} {unit.unit_id} {unit.title}"
    facts = [unit.owner, f"{unit.estimate_pct:g}%" if unit.estimate_pct is not None else ""]
    if unit.after and unit.after != NO_PREDECESSOR:
        facts.append(f"{unit.after} の後")
    if unit.note:
        facts.append(unit.note)
    return f"{OPEN_MARK} {unit.unit_id} {unit.title} [{'・'.join(fact for fact in facts if fact)}]"


def _table_rows(text: str, heading: str) -> list[list[str]]:
    """見出しが `heading` で始まる節の最初の表を、行ごとの欄の並びで返す (頭の行を含み、区切りの行は除く)。"""
    rows: list[list[str]] = []
    in_section = False
    for line in text.splitlines():
        if line.startswith("#"):
            if in_section:
                break
            in_section = line.lstrip("#").strip().startswith(heading)
            continue
        if not in_section:
            continue
        if line.startswith("|"):
            if not SEPARATOR_ROW.match(line):
                rows.append([cell.strip() for cell in CELL_BORDER.split(line.strip())[1:-1]])
        elif rows:
            break
    return rows


def _cell(cells: list[str], columns: dict[str, int], name: str) -> str:
    index = columns.get(name)
    return cells[index] if index is not None and index < len(cells) else ""
