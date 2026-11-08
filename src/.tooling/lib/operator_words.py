#!/usr/bin/env python3
"""会話の記録の行から、 操作者が打った発話と、 その直前に作られた物の path を取り出す判定の部品 (= file にも状態にも触らない)。

呼ぶのは `session-end/extract-operator-words.py`。 操作者の発話とは次の 2 つで、 連絡・封筒・通知・道具の返りは含めない。
- `type: user` の行の文字の本文 (= 道具の返りを持つ行・harness が足した行・会話の要約の行を除く)
- `type: attachment` で `attachment.type == queued_command` かつ `commandMode == prompt` の行の `prompt`
  (= 作業中に打って、 後から取り込まれた発話)

作った物の path とは、 直前の操作者の発話からこの発話までの間のアシスタントの文と道具の入力に出た、
html・スライドの file (pptx)・pdf・png・svg の path。 URL は含めない。

資料の道具が PowerPoint の直しを取り込んだ記録 (資料の folder の `.pptx-agent-maker/reviews.jsonl`、1 行 1 頁) も、
同じ形の行に直す (`review_entries`)。 操作者が手で直した所は、直す前と後の組が機械で取れる一番強い好みのため。
"""

from __future__ import annotations

import json
import re
from collections.abc import Iterable, Iterator
from datetime import datetime
from pathlib import Path

# client が貼る包みの印。 包みの中が連絡や封筒の時は、 包みを外してから判定する
PASTED_TAG = re.compile(r"</?pasted_content[^>\n]*>\n?")
# 操作者が打った物ではない発話の頭のうち、 Claude Code が書く物 (= 割り込みの印・要約)。 client が打つ物
# (= 別のタブの連絡・client の知らせ・入れ替え・立てたタブの封筒) の 1 行目は番人が真値で、 呼ぶ側が `client_openings` で渡す
NOT_OPERATOR_PREFIXES = (
    "[Request interrupted",
    "Caveat:",
    "This session is being continued",
)
# 作った物の拡張子。 URL の中の物と、 path の形でない語は拾わない
ARTIFACT = re.compile(r"[^\s\"'`<>()\[\]{}\\,;|=]+\.(?:html?|pptx|pdf|png|svg)(?![\w/.-])", re.IGNORECASE)
# 命令の中の変数とワイルドカードは、 どの物かを指さない
SHELL_PATTERN = re.compile(r"[*$?]")
MAX_ARTIFACTS = 12
# 取り込みの 1 頁で、本文に並べる文言の直しの数の上限 (= 残りは前後の版を開けば読める)
MAX_REVIEW_WORDS = 10


def _joined_text(content: object) -> str | None:
    """本文の文字。 道具の返りを持つ行は None。"""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return None
    if any(isinstance(block, dict) and block.get("type") == "tool_result" for block in content):
        return None
    return "\n".join(block.get("text", "") for block in content if isinstance(block, dict) and block.get("type") == "text")


def utterance_text(row: dict, client_openings: tuple[str, ...] = ()) -> str | None:
    """行が操作者の発話ならその文字、 そうでなければ None。 `client_openings` は client が打つ発話の 1 行目。"""
    kind = row.get("type")
    if kind == "user":
        if row.get("isMeta") or row.get("isCompactSummary") or row.get("isSidechain"):
            return None
        raw = _joined_text((row.get("message") or {}).get("content"))
    elif kind == "attachment":
        attachment = row.get("attachment")
        if not isinstance(attachment, dict) or attachment.get("type") != "queued_command" \
                or attachment.get("commandMode") != "prompt":
            return None
        raw = _joined_text(attachment.get("prompt"))
    else:
        return None
    if raw is None:
        return None
    text = PASTED_TAG.sub("", raw).strip()
    if not text or text.startswith("<") or text.startswith(NOT_OPERATOR_PREFIXES + tuple(client_openings)):
        return None
    return text


def _strings(value: object) -> Iterator[str]:
    """入れ子の値に出る文字を全部、 出た順に。"""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from _strings(item)


def artifact_paths(row: dict) -> list[str]:
    """アシスタントの行の文と道具の入力に出た、 作った物の path (= 出た順、 重ねない)。 他の行は空。"""
    if row.get("type") != "assistant":
        return []
    found: list[str] = []
    for block in (row.get("message") or {}).get("content") or []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            texts: Iterable[str] = [block.get("text", "")]
        elif block.get("type") == "tool_use":
            texts = _strings(block.get("input"))
        else:
            continue
        for text in texts:
            for path in ARTIFACT.findall(text):
                if "/" in path and "://" not in path and not SHELL_PATTERN.search(path) and path not in found:
                    found.append(path)
    return found


def operator_words(rows: Iterable[dict], session: str, tier: str,
                   client_openings: tuple[str, ...] = ()) -> Iterator[dict]:
    """1 session の行から、 操作者の発話ごとに `{ts, session, tier, text, artifacts}` を出す。

    `artifacts` は直前の操作者の発話からこの発話までに出た作った物の path で、 最後の `MAX_ARTIFACTS` 件。"""
    since_last: list[str] = []
    for row in rows:
        text = utterance_text(row, client_openings)
        if text is None:
            for path in artifact_paths(row):
                if path in since_last:
                    since_last.remove(path)
                since_last.append(path)
            continue
        timestamp = row.get("timestamp")
        if timestamp:
            yield {"ts": timestamp, "session": session, "tier": tier, "text": text,
                   "artifacts": since_last[-MAX_ARTIFACTS:]}
        since_last = []


def deck_folders(entries: Iterable[dict], root: Path, home: Path) -> list[Path]:
    """発話の行に添えた path のうち、スライドの file の folder (= 資料の folder)。`~` は home、相対は root から読む。"""
    folders: list[Path] = []
    for entry in entries:
        for path in entry.get("artifacts", []):
            if not path.lower().endswith(".pptx"):
                continue
            file = Path(path.replace("~", str(home), 1)) if path.startswith("~") else Path(path)
            folder = (file if file.is_absolute() else root / file).parent
            if folder not in folders:
                folders.append(folder)
    return folders


def review_entries(review_rows: Iterable[dict], session: str, tier: str, since: datetime) -> Iterator[dict]:
    """資料の道具の取り込みの記録の行のうち、`since` より後の物を、発話と同じ形の行にする。

    本文は「PowerPoint で直した (<取り込み方>) <資料> の <刷られた番号> 頁: 「前」→「後」…」、
    `artifacts` は直す前と後の版。同じ session の発話と重ならないよう、ts に頁の番号を足す。"""
    for row in review_rows:
        at = row.get("at")
        try:
            when = datetime.fromisoformat(at) if isinstance(at, str) else None
        except ValueError:
            continue
        if when is None or when <= since:
            continue
        page = row.get("printed") or row.get("page") or row.get("built_printed") or row.get("built_page")
        changes = " / ".join(f"「{before}」→「{after}」" for before, after in row.get("words", [])[:MAX_REVIEW_WORDS])
        text = f"PowerPoint で直した ({row.get('how', '?')}) {row.get('deck', '?')} の {page} 頁" + (f": {changes}" if changes else "")
        artifacts = [path for path in (row.get("before"), row.get("after")) if isinstance(path, str)]
        yield {"ts": f"{at}#p{page}", "session": session, "tier": tier, "text": text, "artifacts": artifacts, "source": "review"}


def first_time(rows: Iterable[dict]) -> datetime | None:
    """会話の記録の最初の時刻 (= この session が始まった時)。"""
    for row in rows:
        timestamp = row.get("timestamp")
        if isinstance(timestamp, str):
            try:
                return datetime.fromisoformat(timestamp)
            except ValueError:
                continue
    return None


def working_folders(rows: Iterable[dict]) -> set[str]:
    """行が持つ作業 folder (`cwd`) の全部。"""
    return {row["cwd"] for row in rows if isinstance(row.get("cwd"), str)}


def parse_rows(lines: Iterable[str]) -> Iterator[dict]:
    """会話の記録の行 (= 1 行 1 JSON) を読む。 読めない行は飛ばす。"""
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            yield row
