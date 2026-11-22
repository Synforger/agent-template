#!/usr/bin/env python3
"""起動の検査の出力に当たる反応の決まりだけを出す (= ok の行しか無い決まりは出さない)。

決まりの本文は `action-policy.txt` が持つ。 項目は `@ <行の頭> | <見せる正規表現>` の行で始まり、 次の `@` の行までが
本文。 検査の出力のうち、 頭が一致する行のどれかが正規表現に当たる項目だけを、 書いた順に出す。 本文の `{root}` は
エージェントの folder (= 家の下なら `~/` で始める形)。 呼ぶのは `startup-status.sh` で、 毎回全部の決まりを出すと、
起動のたびに同じ文を読ませることになるため、 出す物を絞る。

    action_policy.py <検査の出力の file> <エージェントの folder>

試験: .tooling/tests/test-action-policy.sh
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

POLICY_FILE = Path(__file__).resolve().parent / "action-policy.txt"
HEADER = "action policy:"
NOTHING = "action policy: nothing to act on (every line above is ok)"


def load_policy(text: str) -> list[tuple[str, re.Pattern[str], list[str]]]:
    """(行の頭, 見せる正規表現, 本文の行) の並び。 `#` の行と空の行は読まない。"""
    entries: list[tuple[str, re.Pattern[str], list[str]]] = []
    for line in text.splitlines():
        if line.startswith("@ "):
            prefix, _, pattern = line[2:].partition(" | ")
            entries.append((prefix.strip(), re.compile(pattern.strip()), []))
        elif entries and line.strip() and not line.startswith("#"):
            entries[-1][2].append(line)
    return entries


def wanted(entries: list[tuple[str, re.Pattern[str], list[str]]], status: list[str]) -> list[str]:
    """検査の行に当たる項目の本文の行。"""
    shown: list[str] = []
    for prefix, pattern, body in entries:
        if any(line.startswith(prefix) and pattern.search(line) for line in status):
            shown.extend(body)
    return shown


def root_shown(root: str) -> str:
    """エージェントの folder を、 家の下なら `~/` で始まる形で。"""
    home = str(Path.home())
    return "~" + root[len(home):] if root.startswith(home + "/") else root


def main(argv: list[str]) -> int:
    status = Path(argv[0]).read_text(encoding="utf-8").splitlines()
    shown = wanted(load_policy(POLICY_FILE.read_text(encoding="utf-8")), status)
    if not shown:
        print(NOTHING)
        return 0
    print(HEADER)
    root = root_shown(argv[1])
    for line in shown:
        print(line.replace("{root}", root))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
