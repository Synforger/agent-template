#!/usr/bin/env python3
"""起動で読む journal を出す: 全文で読む 1 本と、ほかのタブが書いた物の一覧 (起動の手順がエージェントの根で打つ)。

使い方: `python3 .tooling/startup/journal_index.py [--tier TIER] [--tab ID] [--pc LABEL]`
- エージェントの根は、打った folder
- 階層は `--tier`、無ければ環境変数 `AGENT_TIER` (無ければ `normal`)。journal の folder は、`normal` なら根の
  `journal/`、ほかは `<階層>/journal/`。読むのは日付の folder の `session-NN.md` だけ
- タブは `--tab`、無ければ環境変数 `PWA_SID`
- 機械は `--pc`、無ければ起動の検査の `PC:` 行と同じ label (`.tooling/startup/pc-labels.txt` を機械の名前で引く)。
  label が引けない機械では、機械で絞らずに、その旨を stderr に 1 行出す

選び方 (新しさは日付、同じ日は session の番号):
- 全文の 1 本は、自分のタブ (`tab:` が自分) の最新。自分の物が無ければ、その階層・その機械の最新
- 一覧は、自分の最新より後に、同じ階層・同じ機械のほかのタブが書いた物。自分の物が無ければ、全文の 1 本より前の 2 本。
  自分から分かれた fork (`forked_from:` が自分) を先頭に、ほかは新しい順
- `tab:` の無い journal はほかのタブの物として数え、`pc:` の無い journal は機械で外さない

出すのは次の形 (一覧の description は 1 文目だけ):

    journal_full: <path>  (自分のタブの最新 | 自分の journal が無いので階層の最新)
    journal_others: <N> 本 (<基準の journal> の後に、同じ階層・同じ機械のほかのタブが書いた物)
    - [fork] <date> session-<NN> <tab> — <description の 1 文> (<path>)
    - <date> session-<NN> <tab または -> — <description の 1 文> (<path>)
    elapsed: <秒>s

自分の物が無い時の 2 行目の括弧は `(<全文の 1 本> より前の物。自分の journal が無いので直近を出す)`、journal が
1 本も無い時の path は `-`。階層の folder が無い時は、理由を stderr に出して 2 で終わる。

この file は読み書きと入口。選び方と出す行を作る関数は file に触らない。1 つの命令の分で小さいので 1 file に置く
(規則の「役割ごとに file」から外れる理由)。
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

NORMAL_TIER = "normal"
JOURNAL_DIR = "journal"
PC_LABELS_PATH = ".tooling/startup/pc-labels.txt"
# 起動の検査 (startup-status.sh) と同じ順で機械の名前を訊く
HOST_COMMANDS = (("scutil", "--get", "LocalHostName"), ("hostname", "-s"))
HOST_TIMEOUT_S = 10
DATE_FOLDER = re.compile(r"\d{4}-\d{2}-\d{2}")
SESSION_FILE = re.compile(r"session-(\d+)\.md")
FIELD_LINE = re.compile(r"([A-Za-z_]+):(.*)")
FRONTMATTER_MARK = "---"
# 雛形の埋め忘れは、値が無い物として扱う
PLACEHOLDER_PREFIX = "{{"
SENTENCE_END = "。"
OPENING_BRACKETS = "「『（("
CLOSING_BRACKETS = "」』）)"
# 自分の journal が無い時に、全文の 1 本より前から一覧へ出す数
EARLIER_COUNT_WITHOUT_OWN = 2
NO_VALUE = "-"
NO_DESCRIPTION = "(description 無し)"


@dataclass(frozen=True)
class Journal:
    """journal 1 本の、選ぶ時と一覧に出す時に使う欄。無い欄は空文字。"""

    path: str
    date: str
    session: int
    name: str
    tab: str
    forked_from: str
    pc: str
    description: str

    @property
    def order(self) -> tuple[str, int]:
        """新しさの順の鍵。"""
        return (self.date, self.session)


@dataclass(frozen=True)
class Selection:
    """起動で読む物。`full` は全文の 1 本、`others` は一覧に並べる順。"""

    full: Journal | None
    is_own: bool
    others: list[Journal]
    tab: str


def journal_folder(tier: str) -> str:
    """階層の journal の folder (エージェントの根からの path)。"""
    return JOURNAL_DIR if tier == NORMAL_TIER else f"{tier}/{JOURNAL_DIR}"


def frontmatter_fields(text: str) -> dict[str, str]:
    """file の頭の `---` に挟まれた `欄: 値` の行。閉じていなければ空。"""
    lines = text.splitlines()
    if not lines or lines[0].strip() != FRONTMATTER_MARK:
        return {}
    fields: dict[str, str] = {}
    for line in lines[1:]:
        if line.strip() == FRONTMATTER_MARK:
            return fields
        found = FIELD_LINE.fullmatch(line.rstrip())
        if not found:
            continue
        value = found.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        fields[found.group(1)] = "" if value.startswith(PLACEHOLDER_PREFIX) else value
    return {}


def parse_journal(path: str, date: str, session: int, text: str) -> Journal:
    """journal の本文から `Journal` を作る。"""
    fields = frontmatter_fields(text)
    return Journal(
        path=path, date=date, session=session, name=Path(path).stem,
        tab=fields.get("tab", ""), forked_from=fields.get("forked_from", ""),
        pc=fields.get("pc", ""), description=fields.get("description", ""),
    )


def first_sentence(text: str) -> str:
    """文の 1 文目 (句点は付けない)。かぎ括弧と丸括弧の中の句点では切らない。"""
    depth = 0
    for index, char in enumerate(text):
        if char in OPENING_BRACKETS:
            depth += 1
        elif char in CLOSING_BRACKETS:
            depth = max(depth - 1, 0)
        elif char == SENTENCE_END and depth == 0:
            return text[:index]
    return text


def is_own_fork(journal: Journal, tab: str) -> bool:
    """`tab` のタブから分かれた fork が書いた物か。"""
    return bool(tab) and journal.forked_from == tab


def select(journals: Sequence[Journal], tab: str, pc: str) -> Selection:
    """1 つの階層の journal から、全文の 1 本と一覧を選ぶ。`pc` が空なら機械で絞らない。"""
    newest_first = sorted(journals, key=lambda journal: journal.order, reverse=True)
    own = next((journal for journal in newest_first if tab and journal.tab == tab), None)
    here = [journal for journal in newest_first if not (pc and journal.pc and journal.pc != pc)]
    if own:
        full = own
        others = [journal for journal in here if journal.order > own.order]
    else:
        full = here[0] if here else None
        others = here[1:1 + EARLIER_COUNT_WITHOUT_OWN]
    # 並べ替えは安定なので、fork の中と、ほかの中は新しい順のまま
    others.sort(key=lambda journal: not is_own_fork(journal, tab))
    return Selection(full=full, is_own=own is not None, others=others, tab=tab)


def report_lines(selection: Selection) -> list[str]:
    """出力の行 (所要時間の行を除く)。"""
    full = selection.full
    if full is None:
        return [f"journal_full: {NO_VALUE}  (この階層・この機械の journal が無い)",
                "journal_others: 0 本 (journal が無い)"]
    if selection.is_own:
        reason = "自分のタブの最新"
        scope = f"{full.path} の後に、同じ階層・同じ機械のほかのタブが書いた物"
    else:
        reason = "自分の journal が無いので階層の最新"
        scope = f"{full.path} より前の物。自分の journal が無いので直近を出す"
    lines = [f"journal_full: {full.path}  ({reason})",
             f"journal_others: {len(selection.others)} 本 ({scope})"]
    for journal in selection.others:
        mark = "[fork] " if is_own_fork(journal, selection.tab) else ""
        summary = first_sentence(journal.description) or NO_DESCRIPTION
        lines.append(f"- {mark}{journal.date} {journal.name} {journal.tab or NO_VALUE} — {summary} ({journal.path})")
    return lines


def label_for_host(labels: str, host: str) -> str:
    """`pc-labels.txt` の本文から機械の label を引く。無ければ空文字。"""
    for line in labels.splitlines():
        words = line.split()
        if not line.startswith("#") and len(words) > 1 and words[0] == host:
            return words[1]
    return ""


def host_name() -> str:
    """この機械の名前。どの命令でも訊けなければ空文字。"""
    for command in HOST_COMMANDS:
        try:
            done = subprocess.run(command, capture_output=True, text=True, timeout=HOST_TIMEOUT_S, check=False)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if done.returncode == 0:
            return done.stdout.strip()
    return ""


def load_pc_label(root: Path) -> str:
    """この機械の label。表が無い・表に無い時は空文字。"""
    try:
        labels = (root / PC_LABELS_PATH).read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""
    return label_for_host(labels, host_name())


def load_journals(root: Path, folder: str) -> list[Journal]:
    """`folder` の日付の folder にある journal を全部読む。"""
    journals: list[Journal] = []
    for path in (root / folder).glob("*/session-*.md"):
        numbered = SESSION_FILE.fullmatch(path.name)
        if not numbered or not DATE_FOLDER.fullmatch(path.parent.name):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        journals.append(parse_journal(path.relative_to(root).as_posix(), path.parent.name,
                                      int(numbered.group(1)), text))
    return journals


def main(argv: Sequence[str]) -> int:
    """引数と環境を読んで、起動で読む journal を出す。"""
    started = time.monotonic()
    parser = argparse.ArgumentParser(description="起動で読む journal (全文の 1 本と、ほかのタブの一覧) を出す")
    parser.add_argument("--tier", default=os.environ.get("AGENT_TIER") or NORMAL_TIER, help="階層")
    parser.add_argument("--tab", default=os.environ.get("PWA_SID", ""), help="自分のタブの id")
    parser.add_argument("--pc", help="この機械の label")
    args = parser.parse_args(argv)

    root = Path.cwd()
    tier = args.tier.strip("/")
    # `normal` の階層の folder は根そのものなので、根を取り違えていないかは journal/ の有無で見る
    expected = root / (JOURNAL_DIR if tier == NORMAL_TIER else tier)
    if not expected.is_dir():
        print(f"journal_index: {expected} が無い (エージェントの根で打ち、階層の名前を確かめる)", file=sys.stderr)
        return 2
    pc = args.pc if args.pc is not None else load_pc_label(root)
    if not pc:
        print(f"journal_index: この機械の label が {PC_LABELS_PATH} から引けないので、機械で絞らない", file=sys.stderr)

    for line in report_lines(select(load_journals(root, journal_folder(tier)), args.tab, pc)):
        print(line)
    print(f"elapsed: {time.monotonic() - started:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
