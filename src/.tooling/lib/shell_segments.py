"""Bash の命令を段に割る部品 (= file・状態・外の命令に触らない判定)。

引用の中の区切りの字と向け先の `&` (= `2>&1`・`&>log`) で段を割らず、 注釈と heredoc の中身を落とす口を持つ。
呼ぶのは `hooks/commit_paths_guard.py`・`hooks/ci_duplicate_guard.py`・`lib/test_time.py`。
試験は呼ぶ側の試験が持つ。
"""
import re
import shlex

SEGMENT_TOKENS = {";", "&&", "||", "|", "&", "\n"}
#: heredoc を値にする形 (= `--body "$(cat <<'EOF' … EOF)"`)。 本文の引用符で段の読みが崩れないよう、 先に 1 語へ畳む
HEREDOC_VALUE = re.compile(
    r"""\$\([ \t]*cat[ \t]+<<-?[ \t]*(?P<quote>['"]?)(?P<end>[A-Za-z_][\w.-]*)(?P=quote)[ \t]*\n"""
    r"(?:.*?\n)??[ \t]*(?P=end)[ \t]*\n?[ \t]*\)",
    re.DOTALL,
)
HEREDOC_VALUE_WORD = "_text_"
#: 命令の中の引用・逃がした字・注釈・heredoc・裸の `#` (= 前から順に 1 つずつ当たる)
SHELL_TEXT = re.compile(
    r"""'[^']*'|"(?:\\.|[^"\\])*"|\\."""
    r"|(?P<comment>(?<![^\s;&|()])\#[^\n]*)"
    r"""|(?<!<)<<(?!<)-?[ \t]*(?P<quote>['"]?)(?P<end>[A-Za-z_][\w.-]*)(?P=quote)(?P<rest>[^\n]*)"""
    r"\n(?:.*?\n)??[ \t]*(?P=end)(?=\n|$)"
    r"|(?P<hash>\#)",
    re.DOTALL,
)


def segments(command: str) -> list[list[str]]:
    """命令を引用符ごと字句に割り、 区切りの記号と改行で段に分ける (= 割れない時は空)。"""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    try:
        tokens = _with_whole_redirections(list(lexer))
    except ValueError:
        return []
    found: list[list[str]] = [[]]
    for token in tokens:
        if token in SEGMENT_TOKENS or set(token) <= set(";&|\n"):
            found.append([])
        else:
            found[-1].append(token)
    return [words for words in found if words]


def _with_whole_redirections(tokens: list[str]) -> list[str]:
    """区切りの字として割れた向け先の `&` (= `2>&1`・`>&2`・`&>log`) を 1 つの字句に戻す。"""
    whole: list[str] = []
    rest = list(tokens)
    while rest:
        token = rest.pop(0)
        if token == "&" and rest:
            if whole and whole[-1].endswith((">", "<")):
                whole[-1] += token + rest.pop(0)
                continue
            if rest[0].startswith(">"):
                token += rest.pop(0)
        whole.append(token)
    return whole


def without_text(command: str) -> str:
    """注釈と heredoc の中身を落とし、 行の継ぎをつないだ命令 (= `segments` が段を読み違えない形)。"""
    def kept(match: re.Match[str]) -> str:
        if match["comment"] is not None or match.group(0) == "\\\n":
            return ""
        if match["end"] is not None:
            return without_text(match["rest"])
        if match["hash"] is not None:
            return "\\#"
        return match.group(0)

    return SHELL_TEXT.sub(kept, HEREDOC_VALUE.sub(HEREDOC_VALUE_WORD, command))
