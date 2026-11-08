#!/usr/bin/env python3
"""client が打つ発話の 1 行目の表を、番人から取る部品。

client は、別のタブの連絡・client 自身の知らせ・自動の入れ替え・立てたタブの封筒を、操作者の発話と同じ口へ打つ。
その 1 行目の真値は番人で、番人の口 `order.py --openings` が 1 行に 1 つ返す。頭が `>>` なら別の機械からの連絡、
`>` ならこの機械の client が打った物。番人が答えない間 (口の無い古い番人) は、番人の `orders.txt` の `>` の行を読む。

呼ぶのは、締めで操作者の言葉を拾う `session-end/extract-operator-words.py`。届いた発話の読み方を出す hook のように、
操作者が打った物かどうかを決める物は、同じ表を使う。
試験は `GUARD_ORDER_PY` で作り物の口を、`GUARD_CONFIG_DIR` で作り物の `orders.txt` の folder を渡す。
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

DEFAULT_ORDER_PY = Path.home() / "agent-platform/tools/guard-dispatcher/agent-hooks/claude-code/order.py"
GUARD_PLACES = Path.home() / ".git-hooks/scanners/guard_places.py"
ASK_SECONDS = 5


def _ask(command: list[str]) -> str:
    """番人の部品を呼んだ標準出力。呼べなければ空。"""
    try:
        return subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=ASK_SECONDS).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def orders_file() -> Path:
    """番人の `orders.txt` の在処。在処の真値は番人の部品で、無い時は番人が根の無い時に使う置き場。"""
    if "GUARD_CONFIG_DIR" not in os.environ and GUARD_PLACES.is_file():
        place = _ask([sys.executable, str(GUARD_PLACES), "orders.txt"]).strip()
        if place:
            return Path(place)
    return Path(os.environ.get("GUARD_CONFIG_DIR") or Path.home() / ".config/guard") / "orders.txt"


def opening_lines() -> list[str]:
    """`>` か `>>` で始まる行の一覧。番人の口が何も返さなければ orders.txt から。どちらも読めなければ空。"""
    order_py = os.environ.get("GUARD_ORDER_PY") or str(DEFAULT_ORDER_PY)
    got = [line.strip() for line in _ask([sys.executable, order_py, "--openings"]).splitlines()
           if line.strip().startswith(">")]
    if got:
        return got
    try:
        text = orders_file().read_text(encoding="utf-8")
    except OSError:
        return []
    return [line.strip() for line in text.splitlines() if line.strip().startswith(">")]


def split_openings(lines: list[str]) -> tuple[list[str], list[str]]:
    """(別の機械からの 1 行目, この機械の client が打つ 1 行目)。記号を外した文で返す。"""
    far = [line[2:].strip() for line in lines if line.startswith(">>") and line[2:].strip()]
    near = [line[1:].strip() for line in lines if line.startswith(">") and not line.startswith(">>") and line[1:].strip()]
    return far, near


def all_openings() -> tuple[str, ...]:
    """client が打つ発話の 1 行目の全部 (別の機械から・この機械から)。"""
    far, near = split_openings(opening_lines())
    return tuple(far + near)
