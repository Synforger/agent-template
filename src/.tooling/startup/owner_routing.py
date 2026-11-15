"""起動の検査の行を、 持ち主の階層で「このタブに出す物」と「ほかの階層の持ち物」に振り分ける判定 (= file にも外の命令にも触らない)。

`route_by_owner.py` が呼ぶ。 持ち主の対応表は `owner_table.py`。 `tier_paths.py` (= lib) が import できる path に居る前提。

行は、 字下げの無い 1 行 (= 頭の行) と、 続く字下げの行 (= 詳細) の組。 振り分けは頭の行の名前で決める。

- 持ち主の表に無い行 (= stale_rules・duplicates・weekly_audit・children ほか): そのまま出す
- 持ち主が normal の行と tool_actions・pending_approval の行 (= 持ち主は行が名指す階層): 健全な行はそのまま、 警告は持ち主のタブだけにそのまま出し、
  ほかの階層には `others: <行の名前> <件数> (owner <階層>)` の 1 行にまとめる
- docs-check: FAIL の行 (= 詳細の `  fail: <本文>`) ごとに持ち主を決め、 このタブの分だけ数え直す
- static_capacity: 溢れた階層ごとに持ち主を決め、 このタブの階層の分だけ出す
"""
import re
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass, field

from owner_table import NORMAL, NORMAL_ROWS, TOOL_ACTIONS_HEALTHY
from tier_paths import tier_prefix

ROW_NAME = re.compile(r"[A-Za-z][\w-]*")
TOOL_NAME = re.compile(r"^tool_actions\((?P<tool>[^)]+)\)")
PENDING_ROW = re.compile(r"^pending_approval: \S+ (?P<tier>.+)$")
PENDING_HEALTHY = r"^pending_approval: none"
FAIL_COUNT = re.compile(r"FAIL: \d+")
FAIL_DETAIL_PREFIX = "fail: "
OVERFLOW_LINE = re.compile(r"^  - (?P<name>.+?)(?P<skills> skills listing)?: \d+ B > \d+ B$")
AGENT_PARENT_NAME = "agent parent"
# `/` を含み、 引用符・括弧・矢印・区切りで切れる 1 語 (= docs-check の本文から path を拾う)
PATH_TOKEN = re.compile(r"[^\s`'\"()\[\],;:→]+/[^\s`'\"()\[\],;:→]*")
FAIL_TEXT_LIMIT = 200
HIDDEN_OWNER = "(別の境界)"
PARENT_CAPACITY_FILES = ["CLAUDE.md", "profile/profile.md", "rules/always.md"]
SUBPROJECTS_PART = "/subprojects/"


@dataclass
class Row:
    """頭の行 1 本と、 続く字下げの行。"""

    head: str
    detail: list[str] = field(default_factory=list)

    def lines(self) -> list[str]:
        return [self.head, *self.detail]


@dataclass
class Routed:
    """振り分けた結果。 このタブに出す行と、 ほかの階層の持ち物の数 (= (行の名前, 持ち主) ごと)。"""

    lines: list[str]
    others: Counter[tuple[str, str]]


def split_rows(text: str) -> list[Row]:
    """出力の本文を、 頭の行と詳細の組に割る。 空行は捨てる。"""
    rows: list[Row] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        if line[0].isspace() and rows:
            rows[-1].detail.append(line)
        else:
            rows.append(Row(line))
    return rows


def row_name(head: str) -> str:
    """頭の行の名前 (`docs-check: …` → `docs-check`、 `clone_deploy(x): …` → `clone_deploy`)。"""
    found = ROW_NAME.match(head)
    return found.group(0) if found else ""


def capacity_owner(display_name: str) -> str:
    """static_capacity の溢れの表示名 (`agent parent` / `<P>` / `<P>/<S>`…) から持ち主の階層。"""
    if display_name == AGENT_PARENT_NAME:
        return NORMAL
    return "projects/" + display_name.replace("/", SUBPROJECTS_PART)


def capacity_files(tier: str) -> list[str]:
    """階層の常時 load の file (= check-static-capacity.sh が数える物と同じ組)。"""
    if tier == NORMAL:
        return list(PARENT_CAPACITY_FILES)
    return [f"{tier}/_README.md", f"{tier}/rules/always.md"]


def docs_fail_owner(message: str, tiers: frozenset[str]) -> str:
    """docs-check の FAIL の本文から持ち主を決める。 本文の path を含む一番深い階層、 どこにも入らなければ normal。"""
    overflow = OVERFLOW_LINE.match(f"  - {message}")
    if overflow:
        return capacity_owner(overflow["name"])
    deepest: tuple[str, ...] = ()
    for token in PATH_TOKEN.findall(message):
        prefix = tier_prefix([*token.split("/"), ""])
        # 実在しない階層名は、 実在する一番近い親の階層まで戻す
        while prefix and "/".join(prefix) not in tiers:
            prefix = prefix[:-2]
        if len(prefix) > len(deepest):
            deepest = prefix
    return "/".join(deepest) if deepest else NORMAL


def tool_owner(head: str, tool_owners: dict[str, str]) -> str:
    """`tool_actions(<道具>): …` の持ち主。 持ち主の書かれていない道具は normal。"""
    found = TOOL_NAME.match(head)
    return tool_owners.get(found["tool"], NORMAL) if found else NORMAL


def pending_owner(head: str) -> str:
    """`pending_approval: guard.scope <階層>` の持ち主 (= 行が名指す階層)。"""
    found = PENDING_ROW.match(head)
    return found["tier"] if found else NORMAL


def route_plain(row: Row, name: str, owner: str, healthy: str, me: str, routed: Routed) -> None:
    """健全な行と、 持ち主が自分の警告はそのまま。 ほかの階層の警告は数えるだけ。"""
    if owner == me or re.match(healthy, row.head):
        routed.lines += row.lines()
    else:
        routed.others[(name, owner)] += 1


def route_docs(row: Row, me: str, tiers: frozenset[str], routed: Routed) -> None:
    """docs-check の頭の行の FAIL を、 このタブの階層の分に数え直す。 詳細の無い行はそのまま。"""
    fails = [line.strip().removeprefix(FAIL_DETAIL_PREFIX) for line in row.detail
             if line.strip().startswith(FAIL_DETAIL_PREFIX)]
    if not fails or not FAIL_COUNT.search(row.head):
        routed.lines += row.lines()
        return
    mine: list[str] = []
    for message in fails:
        owner = docs_fail_owner(message, tiers)
        if owner == me:
            mine.append(message)
        else:
            routed.others[("docs-check", owner)] += 1
    routed.lines.append(FAIL_COUNT.sub(f"FAIL: {len(mine)}", row.head).rstrip())
    routed.lines += [f"  {FAIL_DETAIL_PREFIX}{message[:FAIL_TEXT_LIMIT]}" for message in mine]


def route_capacity(row: Row, me: str, capacity_detail: Callable[[str, bool], list[str]], routed: Routed) -> None:
    """static_capacity の溢れを、 このタブの階層の分だけにする。 詳細 (削減候補) はこのタブの階層の分を引き直す。"""
    overflows = [(found, line) for line in row.detail if (found := OVERFLOW_LINE.match(line))]
    if not overflows:
        routed.lines += row.lines()
        return
    mine_lines: list[str] = []
    kinds: set[bool] = set()  # False = 常時 load の溢れ、 True = skill の一覧の溢れ
    for found, line in overflows:
        owner = capacity_owner(found["name"])
        if owner == me:
            mine_lines.append(line)
            kinds.add(bool(found["skills"]))
        else:
            routed.others[("static_capacity", owner)] += 1
    if not mine_lines:
        routed.lines.append(f"static_capacity: OK (this tab's tier is within limits; {len(overflows)} over limit"
                            " elsewhere, listed under others:)")
        return
    routed.lines.append(f"static_capacity: {len(mine_lines)} tier(s) over limit")
    routed.lines += mine_lines
    for is_skills in sorted(kinds):
        routed.lines += capacity_detail(me, is_skills)


def route(text: str, me: str, tiers: frozenset[str],
          capacity_detail: Callable[[str, bool], list[str]], tool_owners: dict[str, str]) -> Routed:
    """出力の本文を、 階層 `me` のタブ向けに振り分ける。

    `tool_owners` は道具の名前 → その道具を持つ階層 (= deployed-clones.txt の 4 列目)。
    `capacity_detail(階層, skill の一覧か)` は溢れた階層の削減候補の行を返す (= 外の命令を呼ぶので呼び手が渡す)。"""
    routed = Routed([], Counter())
    for row in split_rows(text):
        name = row_name(row.head)
        if name == "docs-check":
            route_docs(row, me, tiers, routed)
        elif name == "static_capacity":
            route_capacity(row, me, capacity_detail, routed)
        elif name == "tool_actions":
            route_plain(row, name, tool_owner(row.head, tool_owners), TOOL_ACTIONS_HEALTHY, me, routed)
        elif name == "pending_approval":
            route_plain(row, name, pending_owner(row.head), PENDING_HEALTHY, me, routed)
        elif name in NORMAL_ROWS:
            route_plain(row, name, NORMAL, NORMAL_ROWS[name], me, routed)
        else:
            routed.lines += row.lines()
    return routed


def others_lines(others: Counter[tuple[str, str]], is_readable: Callable[[str], bool]) -> list[str]:
    """ほかの階層の持ち物を `others:` の行にする。 このタブが読めない階層の名前は伏せる。"""
    lines = []
    for (name, owner), count in others.items():
        shown = owner if owner == NORMAL or is_readable(owner) else HIDDEN_OWNER
        lines.append(f"others: {name} {count} (owner {shown})")
    return lines
