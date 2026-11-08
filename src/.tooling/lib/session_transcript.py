#!/usr/bin/env python3
"""会話の記録 (= `~/.claude*/projects/<folder-hash>/<session id>.jsonl`) の在処を引く部品。

呼ぶのは `session-end/extract-operator-words.py` (= 操作者の言葉の抜き出し) で、終了発話の確かめのように
今の session の記録を引く script も同じ引き方を使える。 今の session は session id で名指しで引き、 id が無い時だけ、 そのエージェントの folder の
記録のうち一番新しい物に倒す。 「一番新しい file」だけで選ぶと、 並行する別の session や別の口座の記録を掴むため。
口座 1 つの記録全部 (= 過去の分) は `account_transcripts` が返す。 どの口座を読むかは呼ぶ側が決める (= 別の口座は読まない)。
"""

from __future__ import annotations

import glob
from pathlib import Path

ACCOUNT_FOLDER = ".claude"


def find_transcript(root: Path, home: Path, session_id: str | None) -> tuple[Path | None, str | None]:
    """今の session の記録と session id。 返り値 = (記録の path か None, session id か None)。"""
    if session_id:
        hits = glob.glob(str(home / ".claude*" / "projects" / "*" / f"{session_id}.jsonl"))
        if hits:
            return Path(hits[0]), session_id
    encoded = "-" + root.as_posix().strip("/").replace("/", "-")
    hits = glob.glob(str(home / ".claude*" / "projects" / encoded / "*.jsonl"))
    if not hits:
        return None, session_id
    newest = max(hits, key=lambda hit: Path(hit).stat().st_mtime)
    return Path(newest), Path(newest).stem


def running_account(home: Path, config_dir: str | None) -> Path:
    """今走らせている口座の設定の folder (= `CLAUDE_CONFIG_DIR`、 無ければ個人の口座)。"""
    return Path(config_dir) if config_dir else home / ACCOUNT_FOLDER


def account_transcripts(config_folder: Path) -> list[Path]:
    """口座 (= Claude の設定の folder。 既定の口座は `~/.claude`、 別の口座は `~/.claude-work` など) の全 session の記録。 名前順。 体 (sub-agent) の記録は含めない。"""
    return sorted(Path(hit) for hit in glob.glob(str(config_folder / "projects" / "*" / "*.jsonl")))
