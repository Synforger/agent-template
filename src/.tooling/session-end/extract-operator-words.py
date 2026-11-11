#!/usr/bin/env python3
"""この session で操作者が打った言葉を、 作った物の path つきで journal の隣に書き出す (= LLM 不使用)。

用途: 終了手順 Step 2。 書き出した行を読んで、 作った物の形についての言葉を道具の skill の「見本」の節へ積むのは
エージェント (= `.claude/skills/session-end/SKILL.md`)。 この script は拾うだけで、 何が好みかは判定しない。

使い方:
    python3 .tooling/session-end/extract-operator-words.py <journal-dir> [--nn <NN>]
    python3 .tooling/session-end/extract-operator-words.py <journal-dir> --all-sessions --out <file>

- `<journal-dir>` = 当 session が touch した階層の journal (= `journal` / `projects/<P>/journal` / …)。 階層の名前は
  この path から決まる (`journal` は `normal`)。 親とサブの両方を触った時は階層ごとに 1 回ずつ流す
- `--nn` = この session の journal の番号。 無ければその日の journal (.md) の最大 + 1。 書き出し先は
  `<journal-dir>/<日付>/session-<NN>-operator-words.jsonl`
- `--all-sessions` = 過去の分を一度に拾う口。 読むのは、 走らせた口座 (`CLAUDE_CONFIG_DIR`、 無ければ `~/.claude`) の記録のうち、
  その階層の持ち物の session だけ (= 通った階層がその階層と上の段だけ。 判定は `lib/session_scope.py`)。 書き出し先は `--out`
- `--out` = 書き出し先を指定する
- `--root` = エージェントの folder (= 無ければこの script の置き場から決める)。 記録の作業 folder の突き合わせに使う

読むのは自分のタブの記録だけ。 今の session は session id で引いた 1 本 (`lib/session_transcript.py`) で、 他の口座と
境界の外の session は読まない。

1 行 1 発話 `{"ts", "session", "tier", "text", "artifacts": [...]}`。 同じ session と ts の行は 2 度書かない。
`artifacts` は指す file の絶対の path で、 チャットに出た書き方の起点 (= 作業 folder・階層・`pages/`・タブの folder) から解き、
どの起点からも在る file に当たらない path は落とす (`artifact_resolver`)。
今の session では、この session の発話に添えたスライドの file の folder の `.pptx-agent-maker/reviews.jsonl`
(資料の道具が PowerPoint の直しを取り込んだ記録) のうち、この session が始まった後の行も、`"source": "review"` を付けて並べる。
操作者の発話の判定は `lib/operator_words.py`。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections.abc import Callable, Iterator
from datetime import datetime
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(DEFAULT_ROOT / ".tooling" / "lib"))

from client_openings import all_openings  # noqa: E402
from operator_words import deck_folders, first_time, operator_words, parse_rows, review_entries, working_folders  # noqa: E402
from session_scope import belongs_to  # noqa: E402
from session_transcript import account_transcripts, find_transcript, running_account  # noqa: E402

USAGE_ERROR = 2
NN_PATTERN = re.compile(r"(0?[1-9]|[1-9][0-9])")
SESSION_FILE = re.compile(r"session-0*(\d+)\.md$")
JOURNAL_DIR_NAME = "journal"
NORMAL_TIER = "normal"


def fail(message: str, code: int = USAGE_ERROR) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(code)


def tier_of(journal_dir: Path, root: Path) -> str:
    """journal の folder が属する階層の名前 (= `AGENT_TIER` の値)。"""
    if journal_dir.name != JOURNAL_DIR_NAME:
        fail(f"{journal_dir} is not a journal folder (the argument is the tier's journal, e.g. journal / projects/<P>/journal)")
    try:
        relative = journal_dir.parent.relative_to(root)
    except ValueError:
        fail(f"{journal_dir} is outside {root}")
    return relative.as_posix() if relative.parts else NORMAL_TIER


def _up_to(folder: Path, root: Path) -> list[Path]:
    """folder と、 その上の段をエージェントの根まで (= 根の外の folder は自分だけ)。"""
    if not folder.is_relative_to(root):
        return [folder]
    return [folder, *[parent for parent in folder.parents if parent.is_relative_to(root)]]


def artifact_resolver(root: Path, tier: str) -> Callable[[str, str | None], str | None]:
    """作った物の path を、 指す file の絶対の path に解く関数。 どの起点からも在る file に当たらなければ None。

    チャットに出た path の起点は書き方ごとに違う (= エージェントの根・上の階層・その階層・階層の `pages/`・タブの
    folder・その 1 つ上)。 拾う時なら作業 folder と階層の folder が分かるので、 ここで解く。 起点は、 その行の作業
    folder と上の段、 階層の folder と `pages/` とタブの folder (= `pages/<PWA_SID>`)、 階層の上の段 (= どれも根まで)。"""
    tier_folder = root if tier == NORMAL_TIER else root / tier
    tab_id = os.environ.get("PWA_SID")
    fixed = [tier_folder, tier_folder / "pages", *([tier_folder / "pages" / tab_id] if tab_id else []), *_up_to(tier_folder, root)]

    def resolve(path: str, cwd: str | None) -> str | None:
        written = Path(path).expanduser()
        if written.is_absolute():
            return str(written) if written.is_file() else None
        bases = [*(_up_to(Path(cwd), root) if cwd else []), *fixed]
        for base in dict.fromkeys(bases):
            candidate = Path(os.path.normpath(base / written))
            if candidate.is_file():
                return str(candidate)
        return None

    return resolve


def next_number(day_folder: Path) -> int:
    """その日の journal (.md) の最大の番号 + 1。"""
    numbers = [int(match.group(1)) for path in day_folder.glob("session-*.md") if (match := SESSION_FILE.match(path.name))]
    return max(numbers, default=0) + 1


def output_path(journal_dir: Path, number_text: str | None) -> Path:
    day_folder = journal_dir / datetime.now().strftime("%Y-%m-%d")
    number = int(number_text) if number_text else next_number(day_folder)
    return day_folder / f"session-{number:02d}-operator-words.jsonl"


def known_keys(path: Path) -> set[tuple[str, str]]:
    """書き出し先に既にある行の (session, ts)。"""
    if not path.is_file():
        return set()
    with path.open(encoding="utf-8") as handle:
        return {(row.get("session", ""), row.get("ts", "")) for row in parse_rows(handle)}


def transcript_entries(arguments: argparse.Namespace, root: Path, tier: str) -> Iterator[dict]:
    """会話の記録から拾った発話。 今の session の 1 本か、 `--all-sessions` なら走らせた口座の中のその階層の持ち物の session。"""
    if arguments.all_sessions:
        account = running_account(Path.home(), os.environ.get("CLAUDE_CONFIG_DIR"))
        transcripts = [path for path in account_transcripts(account) if _belongs(path, root, tier)]
    else:
        path, _ = find_transcript(root, Path.home(), os.environ.get("CLAUDE_CODE_SESSION_ID"))
        if path is None:
            fail("no transcript found (run inside the session)", code=1)
        transcripts = [path]
    for transcript in transcripts:
        with transcript.open(encoding="utf-8", errors="replace") as handle:
            yield from operator_words(parse_rows(handle), transcript.stem, tier, client_openings(), artifact_resolver(root, tier))


_OPENINGS: tuple[str, ...] | None = None


def client_openings() -> tuple[str, ...]:
    """client が打つ発話の 1 行目 (番人に 1 回だけ訊く)。 取れなければ stderr に 1 行出し、 空のまま進む。"""
    global _OPENINGS
    if _OPENINGS is None:
        _OPENINGS = all_openings()
        if not _OPENINGS:
            print("extract-operator-words: the guard gave no opening lines of the client: "
                  "messages the client typed may be counted as the operator's words", file=sys.stderr)
    return _OPENINGS


def _belongs(transcript: Path, root: Path, tier: str) -> bool:
    with transcript.open(encoding="utf-8", errors="replace") as handle:
        return belongs_to(working_folders(parse_rows(handle)), root, tier)


REVIEW_LOG = Path(".pptx-agent-maker") / "reviews.jsonl"


def review_log_entries(arguments: argparse.Namespace, root: Path, tier: str) -> Iterator[dict]:
    """この session で触った資料の、PowerPoint の直しの取り込みの記録 (今の session だけ。過去の分は拾わない)。"""
    if arguments.all_sessions:
        return
    path, _ = find_transcript(root, Path.home(), os.environ.get("CLAUDE_CODE_SESSION_ID"))
    if path is None:
        return
    with path.open(encoding="utf-8", errors="replace") as handle:
        rows = list(parse_rows(handle))
    since = first_time(rows)
    if since is None:
        return
    for folder in deck_folders(operator_words(rows, path.stem, tier, client_openings(), artifact_resolver(root, tier)), root, Path.home()):
        log = folder / REVIEW_LOG
        if log.is_file():
            with log.open(encoding="utf-8", errors="replace") as handle:
                yield from review_entries(parse_rows(handle), path.stem, tier, since)


# 発話を拾う源。 同じ引数で `{ts, session, tier, text, artifacts}` を出す関数を足せば、 別の源も同じ file に並ぶ
ENTRY_SOURCES: tuple[Callable[[argparse.Namespace, Path, str], Iterator[dict]], ...] = (transcript_entries, review_log_entries)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("journal_dir")
    parser.add_argument("--nn")
    parser.add_argument("--all-sessions", action="store_true")
    parser.add_argument("--out")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    arguments = parser.parse_args()
    if arguments.nn is not None and not NN_PATTERN.fullmatch(arguments.nn):
        fail(f"--nn takes the session number of this journal (1 to 99), got: {arguments.nn or 'nothing'}")
    if arguments.all_sessions and not arguments.out:
        fail("--all-sessions needs --out <file> (the rows of every past session have no journal number)")
    return arguments


def main() -> None:
    arguments = parse_arguments()
    root = arguments.root.resolve()
    journal_dir = Path(arguments.journal_dir)
    journal_dir = journal_dir if journal_dir.is_absolute() else root / journal_dir
    tier = tier_of(journal_dir, root)
    out = Path(arguments.out) if arguments.out else output_path(journal_dir, arguments.nn)

    seen = known_keys(out)
    fresh: list[dict] = []
    for source in ENTRY_SOURCES:
        for entry in source(arguments, root, tier):
            key = (entry["session"], entry["ts"])
            if key not in seen:
                seen.add(key)
                fresh.append(entry)
    if fresh:
        out.parent.mkdir(parents=True, exist_ok=True)
        with out.open("a", encoding="utf-8") as handle:
            handle.writelines(json.dumps(entry, ensure_ascii=False) + "\n" for entry in fresh)
    print(f"operator-words: {len(fresh)} new rows -> {out}")


if __name__ == "__main__":
    main()
