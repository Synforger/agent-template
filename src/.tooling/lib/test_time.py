#!/usr/bin/env python3
"""試験の時間の判定 (= file・状態・外の命令に触らない計算)。

呼ぶのは `hooks/test_time_gate.py` (= 試験の時間を測って鳴らす hook) と `work/test-time.py` (= 受け入れの命令)。
命令の見分け・鳴る線の計算・基準の更新・pytest の遅い所の行の読み・鳴らす文を作る。 状態の読み書きは `test_time_store.py`。
段の割り方は `shell_segments.py`。 読まない形 = 文字列や置換の中で動く命令 (`bash -c`・`eval`・`$(…)`) と、 割れない命令 (= 通す)。
試験 = tests/test-test-time-gate.sh
"""

from __future__ import annotations

import json
import math
import os
import re
import shlex
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from shell_segments import segments, without_text

#: 受け入れの命令。 hook は 1 本の写しが機械の全部のタブで走るので、 打つ folder によらない path で名指す
ACCEPT_COMMAND = f"python3 {shlex.quote(str(Path(__file__).resolve().parents[1] / 'work' / 'test-time.py'))}"
#: 鳴る線の倍率と増え幅。 `elapsed > max(base × RING_RATIO, base + RING_EXTRA_SECONDS)` の時だけ鳴る
RING_RATIO = 1.25
RING_EXTRA_SECONDS = 5.0
#: 試験がぶつかったと数える、 別の session の終わっていない記録の長さの上限 (これを越えた記録は捨てる)
COLLISION_WINDOW_SECONDS = 30 * 60
SLOWEST_COUNT = 10

#: 命令の前に立つ shell の語 (= その後ろが命令)
SHELL_LEADS = ("do", "then", "else", "elif", "if", "while", "until", "!", "{", "(")
#: 後ろの命令をそのまま走らせる包み → (値を取る旗, 命令の前に置く値の数)
WRAPPERS = {
    "env": (("-u", "--unset"), 0),
    "timeout": (("-k", "--kill-after", "-s", "--signal"), 1),
    "gtimeout": (("-k", "--kill-after", "-s", "--signal"), 1),
    "nohup": ((), 0),
    "time": ((), 0),
    "command": ((), 0),
    "exec": ((), 0),
}
#: 出力と入力の向け先の字句 (= `2>&1`・`>log`・`&>/dev/null`・`<in`)。 向け先を次の字句に持つ形 (= `>`・`2>>`) は ALONE
REDIRECTION = re.compile(r"^(\d*|&)(>>?|<)(&\d+|\S*)$")
REDIRECTION_ALONE = re.compile(r"^(\d*|&)(>>?|<)$")
#: 鳴りが消えるまで止める「閉じる手」 (= 命令の頭の字句の並び)
CLOSING_HEADS = (
    ("git", "commit"),
    ("gh", "pr", "create"),
    ("gh", "pr", "merge"),
    ("tabs", "report"),
    ("tabs", "ticket", "close"),
    ("tabs", "ticket", "pass"),
    ("tabs", "rollover"),
)
#: 前の段の folder を変える旗 (= 値を 1 つ取る)
FOLDER_FLAGS = ("-C", "-d", "--dir", "--directory", "--prefix")
GIT_OPTIONS_WITH_VALUE = ("-c", "--git-dir", "--work-tree", "--namespace", "--exec-path")
#: `<runner> <単語>` の形で試験になる runner の頭の字句 (= 値の旗を飛ばした後の並び)
TEST_HEADS = (
    ("pytest",),
    ("python", "-m", "pytest"),
    ("python3", "-m", "pytest"),
    ("uv", "run", "pytest"),
    ("uv", "run", "python", "-m", "pytest"),
    ("task", "test"),
    ("task", "ci"),
    ("npm", "test"),
    ("pnpm", "test"),
    ("yarn", "test"),
    ("vitest",),
    ("npx", "vitest"),
    ("bats",),
    ("go", "test"),
    ("cargo", "test"),
)
#: 遅い所の 1 行 = pytest の `12.34s call tests/x.py::test_y` か、 vitest の報告の `   1234 ms  src/x.test.js > 名前`
DURATION_LINE = re.compile(
    r"^\s*(\d+(?:\.\d+)?s\s+(?:call|setup|teardown)\s+\S+.*?|\d+\s+ms\s+\S+.*?)\s*$", re.MULTILINE)
#: 遅い所の見出し = pytest の `slowest 10 durations` か、 vitest の報告の `slowest 10 tests`
SLOWEST_MARK = re.compile(r"slowest\s+\d*\s*(?:durations|tests)", re.IGNORECASE)
#: 同じ命令の中の代入 (= `W=/path`) と、 その値を指す `$W`・`${W}`
ASSIGNMENT = re.compile(r"^([A-Za-z_]\w*)=(.*)$", re.DOTALL)
VARIABLE = re.compile(r"\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))")
TOOL_USE_ID = re.compile(r"<tool-use-id>\s*([^<\s]+)\s*</tool-use-id>")
OUTPUT_FILE = re.compile(r"<output-file>\s*([^<\n]+?)\s*</output-file>")
STATUS = re.compile(r"<status>\s*([^<\s]+)\s*</status>")


@dataclass(frozen=True)
class TaskNotification:
    """会話の記録に残った、 background の命令の終わりの知らせ。 ended_at は記録の行の時刻 (epoch 秒)。"""

    ended_at: float
    output_file: str
    status: str


def normalize(command: str) -> str:
    """空白を 1 つに詰めた命令の文字列 (= 基準の鍵の片方)。"""
    return " ".join(command.split())


def baseline_key(repo_root: str, command: str) -> str:
    """基準の鍵 = repo の根と、 空白を詰めた命令の文字列の組。"""
    return f"{repo_root}\t{normalize(command)}"


def ring_limit(base_seconds: float) -> float:
    """前回までの基準から、 鳴る線の秒数。"""
    return max(base_seconds * RING_RATIO, base_seconds + RING_EXTRA_SECONDS)


def rings(base_seconds: float | None, elapsed_seconds: float) -> bool:
    """基準があって、 今回が線を越えた時だけ真 (= 基準の無い初めての試験は鳴らない)。"""
    return base_seconds is not None and elapsed_seconds > ring_limit(base_seconds)


def next_base(base_seconds: float | None, elapsed_seconds: float) -> float:
    """線の内に収まった時の基準。 無ければ今回、 今回の方が短ければ今回に下げ、 長くても線の内なら動かさない。"""
    if base_seconds is None or elapsed_seconds < base_seconds:
        return elapsed_seconds
    return base_seconds


def is_seconds(value: float | None) -> bool:
    """打たれた秒数が、 正の有限の数か。"""
    return value is not None and math.isfinite(value) and value > 0


def accepted_base(elapsed_seconds: float, after_seconds: float) -> float:
    """受け入れた時の基準 = 測った秒と、 縮める手を試した後の秒の短い方。 流し直しは旗が違えば別の鍵になり測った秒を
    置き換えないので書かれた秒を読むが、 書かれた値で基準が測った秒より上がると鳴りを黙らせられるので、 下げる向きだけ。"""
    return min(elapsed_seconds, after_seconds)


def _segments(command: str) -> list[list[str]]:
    """命令を引用・heredoc・注釈の外の区切りで段に割り、 段ごとに実際に走る命令の字句にする (= 割れなければ空)。"""
    found = (_unwrapped(words) for words in segments(without_text(command)))
    return [words for words in found if words]


def _unwrapped(words: list[str]) -> list[str]:
    """段の頭の代入・shell の語・包みの命令 (= `direnv exec <dir>`・`env`・`timeout` など) を外した字句。"""
    rest = list(words)
    while rest:
        head = os.path.basename(rest[0])
        if rest[0] in SHELL_LEADS or ("=" in rest[0] and not rest[0].startswith("-")):
            rest = rest[1:]
        elif head == "direnv" and rest[1:2] == ["exec"]:
            rest = rest[3:]
        elif head in WRAPPERS:
            flags_with_value, value_count = WRAPPERS[head]
            rest = rest[1:]
            while rest and rest[0].startswith("-"):
                rest = rest[2 if rest[0] in flags_with_value else 1:]
            rest = rest[value_count:]
        else:
            break
    return rest


def _positional(words: list[str]) -> list[str]:
    """値を取る旗と、 runner の後ろの `-` で始まる旗を飛ばした字句の並び (= 先頭は command の名前だけにする)。
    `task test:<名前>` は `task test` として数える。"""
    positional: list[str] = []
    rest = list(words)
    while rest:
        word = rest.pop(0)
        if word in FOLDER_FLAGS or word in GIT_OPTIONS_WITH_VALUE:
            if rest:
                rest.pop(0)
            continue
        if word.startswith("-") and positional and positional[-1] not in ("python", "python3"):
            continue
        positional.append(word)
    if positional:
        positional[0] = os.path.basename(positional[0])
    if len(positional) > 1 and positional[0] == "task" and positional[1].startswith("test:"):
        positional[1] = "test"
    return positional


def _matches_head(words: list[str], heads: tuple[tuple[str, ...], ...]) -> bool:
    """字句の頭が、 heads のどれかに当たれば真。"""
    positional = _positional(words)
    return any(tuple(positional[: len(head)]) == head for head in heads)


def _folder_after(words: list[str], current: Path) -> Path:
    """段の中の `-C <dir>` などの旗が指す folder (= 旗が無ければ今の folder)。"""
    folder = current
    rest = list(words)
    while rest:
        word = rest.pop(0)
        if word in FOLDER_FLAGS and rest:
            folder = (current / os.path.expanduser(rest.pop(0))).resolve()
        else:
            for flag in FOLDER_FLAGS:
                if word.startswith(flag + "=") and flag.startswith("--"):
                    folder = (current / os.path.expanduser(word.split("=", 1)[1])).resolve()
    return folder


def test_runs(command: str, cwd: Path) -> list[tuple[Path, str]]:
    """命令の中で試験を流す段ごとに、 その作業の folder と、 その段だけの命令 (= 空白を詰めた物) を返す (= 無ければ空)。
    前の段の `cd` と、 段の中の `-C`・`-d`・`--dir` も folder に数え、 その値の変数は同じ命令の前の代入で展開する。 前後の段 (`cd`・`| tail` など) は段の命令に入れない。"""
    runs: list[tuple[Path, str]] = []
    current = cwd
    variables = {"HOME": os.path.expanduser("~")}
    for step in segments(without_text(command)):
        variables.update(_assignments(step, variables))
        words = _unwrapped(step)
        if len(words) >= 2 and words[0] == "cd":
            current = (current / os.path.expanduser(_expanded(words[1], variables))).resolve()
            continue
        if _matches_head(words, TEST_HEADS):
            folder = _folder_after([_expanded(word, variables) for word in words], current)
            runs.append((folder, normalize(shlex.join(_without_redirections(words)))))
    return runs


def _assignments(step: list[str], variables: dict[str, str]) -> dict[str, str]:
    """段の頭の代入 (= `W=/path`・`export W=/path`) の名前と値。 値の中の前の代入は展開する。"""
    found: dict[str, str] = {}
    for word in step[1:] if step[:1] == ["export"] else step:
        match = ASSIGNMENT.match(word)
        if not match:
            break
        found[match[1]] = _expanded(match[2], {**variables, **found})
    return found


def _expanded(word: str, variables: dict[str, str]) -> str:
    """字句の中の `$名前`・`${名前}` を、 分かっている値に置く (= 知らない名前はそのまま)。"""
    return VARIABLE.sub(lambda match: variables.get(match[1] or match[2], match[0]), word)


def _without_redirections(words: list[str]) -> list[str]:
    """段の字句から出力と入力の向け先 (= `2>&1`・`> log`・`2>/dev/null`) を外す (= 向け先の違いで別の試験にしない)。"""
    kept: list[str] = []
    rest = list(words)
    while rest:
        word = rest.pop(0)
        if REDIRECTION.match(word):
            if REDIRECTION_ALONE.match(word) and rest:
                rest.pop(0)
            continue
        kept.append(word)
    return kept


def test_label(repo_root: str, folder: Path, test_command: str) -> str:
    """基準の鍵と鳴らす文に使う試験の名前 = repo の根からの folder と、 段の命令 (= 根で流した時は命令だけ)。"""
    relative = os.path.relpath(Path(folder).resolve(), Path(repo_root).resolve())
    return test_command if relative == "." else f"{relative}: {test_command}"


def runs_label(repo_root: str, runs: list[tuple[Path, str]]) -> str:
    """命令 1 つが流す試験の名前。 測れる秒は命令の全体なので、 試験が複数なら束で 1 つの名前にする。"""
    return "; ".join(test_label(repo_root, folder, test_command) for folder, test_command in runs)


def is_closing_hand(command: str) -> bool:
    """命令の中に、 作業を閉じる手 (= commit・PR の作成と merge・`pr-land.sh`・`tabs report` ほか) が 1 つでも在れば真。"""
    for words in _segments(command):
        if os.path.basename(words[0]) == "pr-land.sh" or (
            words[0] in ("bash", "sh") and len(words) > 1 and os.path.basename(words[1]) == "pr-land.sh"
        ):
            return True
        if _matches_head(words, CLOSING_HEADS):
            return True
    return False


def slowest_lines(output: str, count: int = SLOWEST_COUNT) -> list[str]:
    """pytest の `slowest durations` の行 (例 `12.34s call tests/x.py::test_y`) を上から count 本。 無ければ空。"""
    mark = SLOWEST_MARK.search(output)
    if not mark:
        return []
    return [match.group(1) for match in DURATION_LINE.finditer(output, mark.end())][:count]


def find_task_notification(transcript_text: str, tool_use_id: str) -> TaskNotification | None:
    """会話の記録の末尾から、 tool_use_id の `<task-notification>` を持つ `queue-operation` の `enqueue` の行を探す (= 無ければ None)。
    途中で切れた行・別の形の行は飛ばす。"""
    for line in transcript_text.splitlines():
        if tool_use_id not in line or "queue-operation" not in line:
            continue
        try:
            row = json.loads(line)
            content = row["content"]
            notified_id = TOOL_USE_ID.search(content)
            ended_at = datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00")).timestamp()
        except (ValueError, KeyError, TypeError, AttributeError):
            continue
        if row.get("type") != "queue-operation" or row.get("operation") != "enqueue":
            continue
        if "<task-notification>" not in content or not notified_id or notified_id.group(1) != tool_use_id:
            continue
        output_file, status = OUTPUT_FILE.search(content), STATUS.search(content)
        return TaskNotification(ended_at, output_file.group(1) if output_file else "", status.group(1) if status else "")
    return None


def format_duration(seconds: float) -> str:
    """経過の秒数を人が読む形にする (= 90 秒未満は秒、 以上は分と秒)。"""
    if seconds < 90:
        return f"{seconds:.0f}秒"
    minutes, rest = divmod(int(seconds), 60)
    return f"{minutes}分{rest}秒"


def ring_message(repo_name: str, command: str, base_seconds: float, elapsed_seconds: float, slowest: list[str]) -> str:
    """試験が線を越えた時に、 流した本人へ出す文 (= いつもの秒数・今回の秒数・遅い所・鳴りが消える 2 つの道)。"""
    if slowest:
        names = "遅い所 (上から " + str(len(slowest)) + " 本):\n" + "\n".join(f"  {line}" for line in slowest)
    else:
        names = "遅い所の名前が出力に無い。 試験の設定に `--durations=10` を足すと名前が出る。"
    return (
        f"[test-time] {repo_name} の試験 `{normalize(command)[:100]}` が、 いつもの {base_seconds:.1f}秒 を越えた"
        f" (今回 {elapsed_seconds:.1f}秒、 鳴る線 {ring_limit(base_seconds):.1f}秒)。\n"
        f"{names}\n"
        "鳴りが消えるまで、 commit・PR の作成と merge・`pr-land.sh`・`tabs report`・票の close と pass・`tabs rollover` は止まる。"
        " 読む・直す・試験を流し直す手は止まらない。 消える道は 2 つ:\n"
        "  (a) 既定は縮める (並列・時計の待ち・重い準備の使い回し)。 縮めて同じ命令を流し直し、 線の内に収まれば消える\n"
        "  (b) 縮める手を試しても縮まらなかった時だけ、 試した手を書いて受け入れる:"
        f' `{ACCEPT_COMMAND} accept --tried "<試した手>" --before <いつもの秒> --after <縮める手を試した後の秒>`'
    )


def closing_deny_message(ringing: list[dict]) -> str:
    """鳴りが残っている間に閉じる手を打った時の止める文。 受け入れの命令が次に受ける 1 件 (= 一番新しい鳴り) を名指す。"""
    lines = "\n".join(
        f"  {Path(ring['repo']).name}: `{ring['command'][:80]}` いつも {ring['base']:.1f}秒 → 今回 {ring['elapsed']:.1f}秒"
        for ring in ringing
    )
    return (
        "試験の時間が、 いつもの時間を越えたまま閉じられません (commit・PR・報告・票の close と pass・rollover):\n"
        f"{lines}\n"
        "縮めて同じ命令を流し直し線の内に収める (既定)。 縮める手を試しても縮まらなかった時だけ、"
        f' `{ACCEPT_COMMAND} accept --tried "<試した手>" --before <いつもの秒> --after <縮める手を試した後の秒>` で受け入れる'
        " (最後に載った 1 件ずつ受ける)。"
    )


def collision_message(repo_name: str, running_seconds: float) -> str:
    """同じ repo の試験が別の session で流れている時に、 後から流す側を止める文。"""
    return (
        f"{repo_name} の試験が {format_duration(running_seconds)} 前から別の session で流れている。"
        "終わってから流すか、 触った所の試験だけを流す。"
    )
