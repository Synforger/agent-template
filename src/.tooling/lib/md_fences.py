"""Markdown の各行が code block の中かを決める部品。決まりの文を読む検査と台帳の script が使う。

code block は、開いた印 (``` か ~~~) と同じ字で、同じ本数以上の印だけの行で閉じる。
4 本の backtick で開いた block の中に ``` の行を書けるのはこのためで、印の字と本数を見ずに
``` の行ごとに開け閉めを入れ替えると、block の中の見出しや文を外の物として読む。
"""
import re

FENCE = re.compile(r"^\s*(`{3,}|~{3,})")


def fence_states(lines):
    """各行が code block の中か (囲みの行も中に数える) を、行ごとに True / False で返す。"""
    opened = None
    for line in lines:
        found = FENCE.match(line)
        if opened is None:
            if found:
                opened = found.group(1)
            yield found is not None
            continue
        if found and _closes(line, found.group(1), opened):
            opened = None
        yield True


def _closes(line: str, mark: str, opened: str) -> bool:
    """`mark` の行が、`opened` で開いた block を閉じるか (同じ字・同じ本数以上・印の後ろに何も無い)。"""
    return mark[0] == opened[0] and len(mark) >= len(opened) and not line.strip()[len(mark):].strip()
