#!/usr/bin/env python3
"""check-declarations.py - 宣言と実物を両方向で突き合わせる (= LLM 不使用)。

置き場とテストは、 足す側の判断に任せると増える一方になる (= 足す理由は毎回在り、 足さない理由と
置いてよい場所はどこにも書かれていない)。 ここは宣言を真値にして、 実物をそれに合わせる。
宣言は 2 種類 (置き場・約束) で、 どちらも型が配る file と、 その派生だけの file の 2 枚を足して読む:

  .tooling/layout.base.txt     型が配る物の置き場     (= 型が配り、 派生は書かない)
  .tooling/layout.txt          その派生だけの置き場
  .tooling/contracts.base.txt  型が配る道具の約束     (= 型が配り、 派生は書かない)
  .tooling/contracts.txt       その派生だけの約束

派生の 2 枚は無くてもよい (= 型の物だけの派生は何も書かずに通る)。 同じ種類の 2 枚が両方無い時だけ
`not found` になる。

置き場 (= layout) の書式: `<folder> : <直下に置いてよい名前> ...`
  - 名前は 1 段ぶんの fnmatch (= `*.sh` / `session-[0-9][0-9].md`)
  - `x/`   = その名前の folder (= その folder 自身の行が要る)
  - `x/**` = その名前の folder と、 その下の全部 (= 中は宣言しない。 日付で増える記録、 残す前提の無い出力、 別の道具の持ち物)
  - folder の側も段ごとの fnmatch で書ける (= `projects/*` は project のどれにも当たる。 入れ子の決まりはこの形で書く)
  - folder の側の `**` の段は、 1 段以上のどんな段にも当たる (= `projects/**/subprojects/*` は、 サブプロが何段続いても
    そのどれにも当たる)
  - 同じ folder の行は 2 枚のどちらにも、 何本でも書ける (= 全部足して読む)
  - `?x` = 機械によっては無い物 (= git が運ばない folder や file。 無くても消し忘れに数えない)
  - 「当たる実物が無い」 と数えるのは、 そのままの綴りで書かれた folder の行と名前だけ。 `*` などを含む
    綴りは、 繰り返される物の形の決まりで、 今 0 個でも明日 1 つ出来る (= git が運ばない階層を名指す行は、
    それを持たない機械では必ず 0 個になる)
  - 見るのは、 git が追う file と、 まだ追っていないが無視もしていない file、 それに実物の folder
    (= git が無視する file は対象外。 無視される folder は、 中に何が溜まるかを言う行が要る)。
    git から見える file が 1 つも無い folder (= 自分の repo を持つ project の中) は、 実物の名前を全部見る

約束 (= contracts) の書式: `<対象の script> | <守るテスト。 無ければ -> | <約束 1 文>`
  - 対象とテストは `.tooling/` からの相対 path
  - 対象の頭の `?` = 機械全体の hook のように、 持たない派生もある道具の行。 対象もテストも無い派生では
    その行を見ず、 どちらかが在れば普通の行として見る

派生が型の行を外す口 (= 派生の file にだけ書ける。 理由の `#` が要る):
  - layout:    `!<folder> : <名前> ...  # <理由>`   型の同じ folder の行から、 その名前を外す
  - contracts: `!<対象>  # <理由>`                  型のその対象の行を全部外す
  理由の無い外す行、 当たる物の無い外す行、 型の file に書かれた外す行は赤になる

型と派生に同じ宣言があれば赤 (= 二重の真値)。 同じとは、 layout は folder の綴りと名前、 contracts は対象
(= `?` を除く)・テスト・約束の文 (= 空白を畳む)。

出る物 (= 1 行 1 件、 無ければ要約の 2 行だけ。 件が在れば exit 1)。 宣言から来た物の末尾には、 その宣言の
`[<file>:<行>]` が付く (= 型の file か派生の file かが読める。 二重の真値は両方を出す):
  layout: undeclared ...       宣言に無い file / folder が在る
  layout: no line for ...      `x/` と書かれた folder に、 その folder 自身の行が無い
  layout: nothing matches ...  宣言の行か名前に、 当たる実物が 1 つも無い (= 消し忘れ)
  layout: duplicate ...        型と派生に同じ名前が在る
  layout: nothing to drop ...  外す行が、 型の何にも当たらない
  layout: drop without a reason ... / layout: drop line in a base file ...
  contracts: no promise ...    約束の表に載っていない道具 / テストが在る
  contracts: missing ...       表の行が指す対象 / テストが無い
  contracts: duplicate ... / nothing to drop ... / drop without a reason ... / drop line in a base file ...

走らせ方: python3 .tooling/docs-check/check-declarations.py [--root <dir>]
"""
from __future__ import annotations

import fnmatch
import os
import re
import subprocess
import sys
import unicodedata
from dataclasses import dataclass, field

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if "--root" in sys.argv:
    ROOT = os.path.abspath(sys.argv[sys.argv.index("--root") + 1])
LAYOUT_BASE = ".tooling/layout.base.txt"
LAYOUT_OWN = ".tooling/layout.txt"
CONTRACTS_BASE = ".tooling/contracts.base.txt"
CONTRACTS_OWN = ".tooling/contracts.txt"
# 道具が自分で置く物 (= OS と git と実行の副産物。 宣言の対象にしない)
NOISE = {".DS_Store", "__pycache__", ".git"}
SHAPE = re.compile(r"[*?\[]")   # fnmatch の記号を含む綴り = 形の決まり
# 約束の表が対象にする道具の置き場 (= 役割の folder の直下) と、 道具として数える拡張子
TOOL_SUFFIXES = (".sh", ".py")
TEST_DIR = "tests"


@dataclass(frozen=True)
class Origin:
    """宣言が書かれた file と行 (= 赤の行が、 型と派生のどちらの宣言から来たかを名指す)。"""

    file: str
    line: int

    def __str__(self) -> str:
        return f"{self.file}:{self.line}"


@dataclass
class Entry:
    """置き場の行の名前 1 つ。"""

    token: str          # 書かれた綴りから `?` を除いた物 (= `x/`・`x/**`・`*.sh`)
    name: str           # fnmatch に渡す綴り
    kind: str           # file / dir / free
    optional: bool
    used: bool = False


@dataclass
class Rule:
    """置き場の 1 行: folder の綴りと、 直下に置いてよい名前。"""

    folder: str
    origin: Origin
    entries: list[Entry] = field(default_factory=list)


@dataclass
class Row:
    """約束の表の 1 行。"""

    target: str
    test: str
    promise: str
    optional: bool
    origin: Origin


@dataclass(frozen=True)
class Drop:
    """派生が型の行を外す宣言 (= `!` で始まる行)。"""

    target: str              # layout は folder の綴り、 contracts は対象
    tokens: tuple[str, ...]  # layout は外す名前 (= contracts では空)
    reason: str
    origin: Origin


def read_lines(rel: str) -> list[tuple[int, str]] | None:
    """宣言 file を (行番号, 生の行) で返す。 無ければ None。"""
    try:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
            return [(i, ln.rstrip("\n")) for i, ln in enumerate(f, 1)]
    except OSError:
        return None


def split_comment(raw: str) -> tuple[str, str]:
    """生の行を (本文, `#` の後ろの理由) に分ける。"""
    body, _, reason = raw.partition("#")
    return body.strip(), reason.strip()


def folder_key(folder: str) -> str:
    """folder の綴りを比べる形にする (= 末尾の `/` を除く)。"""
    return folder.strip().rstrip("/") or "."


def segs_match(path: list[str], pattern: list[str]) -> bool:
    """段ごとに fnmatch が通る。 pattern の `**` の段は path の 1 段以上に当たる。"""
    if not pattern:
        return not path
    if pattern[0] == "**":
        return any(segs_match(path[k:], pattern[1:]) for k in range(1, len(path) + 1))
    return bool(path) and fnmatch.fnmatchcase(path[0], pattern[0]) and segs_match(path[1:], pattern[1:])


def seg_match(path: str, pattern: str) -> bool:
    return segs_match(path.split("/"), pattern.split("/"))


def tracked() -> list[str] | None:
    """git が追う file と、 追っていないが無視もしていない file (= ROOT 相対)。 git の外で回した時は None。"""
    try:
        r = subprocess.run(["git", "-C", ROOT, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                           capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return [p for p in r.stdout.decode("utf-8", "replace").split("\0") if p]


def children(folder: str, files: list[str] | None) -> dict[str, bool]:
    """その folder の直下の (名前, folder か) の一覧 (= 何を見るかは冒頭の説明のとおり)。"""
    prefix = "" if folder == "." else folder + "/"
    seen: dict[str, bool] = {}
    if files is not None:
        for p in files:
            if p.startswith(prefix):
                rest = p[len(prefix):]
                name = rest.split("/", 1)[0]
                seen[name] = seen.get(name, False) or "/" in rest
    from_git = bool(seen)
    try:
        with os.scandir(os.path.join(ROOT, folder)) as it:
            for e in it:
                is_dir = e.is_dir(follow_symlinks=False)
                if is_dir or not from_git:
                    seen.setdefault(e.name, is_dir)
    except OSError:
        pass
    return {n: d for n, d in seen.items() if n not in NOISE}


def make_entry(raw_token: str) -> Entry:
    optional = raw_token.startswith("?")
    token = raw_token[1:] if optional else raw_token
    if token.endswith("/**"):
        return Entry(token, token[:-3], "free", optional)
    if token.endswith("/"):
        return Entry(token, token[:-1], "dir", optional)
    return Entry(token, token, "file", optional)


def parse_layout(lines: list[tuple[int, str]], file: str) -> tuple[list[Rule], list[Drop]]:
    """置き場の宣言 1 枚を、 行と外す行に分ける。"""
    rules: list[Rule] = []
    drops: list[Drop] = []
    for number, raw in lines:
        body, reason = split_comment(raw)
        if ":" not in body:
            continue
        origin = Origin(file, number)
        if body.startswith("!"):
            folder, names = body[1:].split(":", 1)
            drops.append(Drop(folder_key(folder), tuple(n.lstrip("?") for n in names.split()), reason, origin))
            continue
        folder, names = body.split(":", 1)
        rules.append(Rule(folder.strip(), origin, [make_entry(n) for n in names.split()]))
    return rules, drops


def parse_contracts(lines: list[tuple[int, str]], file: str) -> tuple[list[Row], list[Drop]]:
    """約束の表 1 枚を、 行と外す行に分ける。"""
    rows: list[Row] = []
    drops: list[Drop] = []
    for number, raw in lines:
        body, reason = split_comment(raw)
        origin = Origin(file, number)
        if body.startswith("!"):
            drops.append(Drop(body[1:].split("|", 1)[0].strip().lstrip("?"), (), reason, origin))
            continue
        parts = [p.strip() for p in body.split("|")]
        if len(parts) == 3 and parts[0]:
            target = parts[0]
            optional = target.startswith("?")
            rows.append(Row(target.lstrip("?"), parts[1], parts[2], optional, origin))
    return rows, drops


def promise_key(text: str) -> str:
    """約束の文を比べる形にする (= 全角半角を揃え、 空白を畳む)。"""
    return " ".join(unicodedata.normalize("NFKC", text).split())


def apply_layout_drops(base: list[Rule], drops: list[Drop], base_file: str) -> list[str]:
    """派生の外す行を型の行へ当てる。 当たらない行と理由の無い行は問題で返す。"""
    problems: list[str] = []
    for d in drops:
        tag = f"[{d.origin}]"
        shown = f"{d.target} : {' '.join(d.tokens)}"
        if not d.reason:
            problems.append(f"layout: drop without a reason {shown} (write why after the line: '# <reason>') {tag}")
        hit = False
        for rule in base:
            if folder_key(rule.folder) != d.target:
                continue
            kept = [e for e in rule.entries if e.token not in d.tokens]
            if len(kept) != len(rule.entries):
                hit = True
                rule.entries = kept
        if not hit:
            problems.append(f"layout: nothing to drop {shown} (no line of {base_file} for that folder holds it) {tag}")
    return problems


def layout_duplicates(base: list[Rule], own: list[Rule]) -> list[str]:
    """型と派生に同じ folder の同じ名前が在れば問題で返す (= 二重の真値)。"""
    problems: list[str] = []
    seen = {(folder_key(r.folder), e.token): r.origin for r in base for e in r.entries}
    for r in own:
        for e in r.entries:
            was = seen.get((folder_key(r.folder), e.token))
            if was:
                problems.append(f"layout: duplicate {r.folder} : {e.token} (declared by the base too; keep it in "
                                f"{was.file} and drop it from {r.origin.file}) [{was}, {r.origin}]")
    return problems


def load_layout() -> tuple[list[Rule], list[str]] | None:
    """置き場の 2 枚を足した行の一覧と、 読む時に出た問題。 2 枚とも無ければ None。"""
    base_lines, own_lines = read_lines(LAYOUT_BASE), read_lines(LAYOUT_OWN)
    if base_lines is None and own_lines is None:
        return None
    base, base_drops = parse_layout(base_lines or [], os.path.basename(LAYOUT_BASE))
    own, own_drops = parse_layout(own_lines or [], os.path.basename(LAYOUT_OWN))
    problems = [f"layout: drop line in a base file {d.target} (a drop belongs to an agent's own file) [{d.origin}]"
                for d in base_drops]
    problems += layout_duplicates(base, own)
    problems += apply_layout_drops(base, own_drops, os.path.basename(LAYOUT_BASE))
    return base + own, problems


def check_layout(files: list[str] | None) -> tuple[list[str], int]:
    loaded = load_layout()
    if loaded is None:
        return [f"layout: {LAYOUT_OWN} not found"], 0
    rules, problems = loaded

    todo: list[tuple[str, Origin | None]] = [(".", None)]
    done: set[str] = set()
    while todo:
        folder, declared_at = todo.pop()
        if folder in done:
            continue
        done.add(folder)
        mine = [r for r in rules if seg_match(folder, r.folder)]
        if not mine:
            problems.append(f"layout: no line for {folder}/ (a line names it as a folder, none says what it may hold)"
                            + (f" [{declared_at}]" if declared_at else ""))
            continue
        for name, is_dir in sorted(children(folder, files).items()):
            hit: Entry | None = None
            hit_rule: Rule | None = None
            for r in mine:
                for e in r.entries:
                    if fnmatch.fnmatchcase(name, e.name) and (e.kind == "file") != is_dir:
                        e.used = True
                        if hit is None:
                            hit, hit_rule = e, r
            path = name if folder == "." else f"{folder}/{name}"
            if hit is None or hit_rule is None:
                problems.append(f"layout: undeclared {path}{'/' if is_dir else ''} "
                                f"(add it to the line of {folder}/ in {LAYOUT_OWN}, or move it)")
                continue
            if hit.kind == "dir":
                todo.append((path, hit_rule.origin))
    for rule in rules:
        reached = any(seg_match(f, rule.folder) for f in done)
        if not reached:
            if not SHAPE.search(rule.folder):
                problems.append(f"layout: nothing matches the line of {rule.folder} (drop the line) [{rule.origin}]")
            continue
        for e in rule.entries:
            if e.used or e.optional or SHAPE.search(e.name):
                continue
            problems.append(f"layout: nothing matches {e.name} in the line of {rule.folder} "
                            f"(drop the name, or write ?{e.name} if only some machines have it) [{rule.origin}]")
    return problems, len(done)


def scan_tooling() -> tuple[set[str], set[str]]:
    """`.tooling/` に在る道具とテストの一覧 (= `.tooling/` からの相対 path)。"""
    tools: set[str] = set()
    tests: set[str] = set()
    try:
        for e in os.scandir(os.path.join(ROOT, ".tooling")):
            if e.is_file() and e.name.endswith(TOOL_SUFFIXES):
                tools.add(e.name)
            elif e.is_dir() and not e.name.startswith(("_", ".")) and e.name not in NOISE:
                for f in os.scandir(e.path):
                    if f.is_file() and f.name.endswith(TOOL_SUFFIXES):
                        (tests if e.name == TEST_DIR else tools).add(f"{e.name}/{f.name}")
    except OSError:
        pass
    return tools, tests


def apply_contract_drops(base: list[Row], drops: list[Drop], base_file: str) -> tuple[list[Row], list[str]]:
    """派生の外す行を型の行へ当てる。 残った行と、 問題を返す。"""
    problems: list[str] = []
    rows = list(base)
    for d in drops:
        tag = f"[{d.origin}]"
        if not d.reason:
            problems.append(f"contracts: drop without a reason {d.target} (write why after the line: '# <reason>') {tag}")
        kept = [r for r in rows if r.target != d.target]
        if len(kept) == len(rows):
            problems.append(f"contracts: nothing to drop {d.target} (no row of {base_file} names it) {tag}")
        rows = kept
    return rows, problems


def load_contracts() -> tuple[list[Row], list[str]] | None:
    """約束の 2 枚を足した行の一覧と、 読む時に出た問題。 2 枚とも無ければ None。"""
    base_lines, own_lines = read_lines(CONTRACTS_BASE), read_lines(CONTRACTS_OWN)
    if base_lines is None and own_lines is None:
        return None
    base_name, own_name = os.path.basename(CONTRACTS_BASE), os.path.basename(CONTRACTS_OWN)
    base, base_drops = parse_contracts(base_lines or [], base_name)
    own, own_drops = parse_contracts(own_lines or [], own_name)
    problems = [f"contracts: drop line in a base file {d.target} (a drop belongs to an agent's own file) [{d.origin}]"
                for d in base_drops]
    seen = {(r.target, r.test, promise_key(r.promise)): r.origin for r in base}
    for r in own:
        was = seen.get((r.target, r.test, promise_key(r.promise)))
        if was:
            problems.append(f"contracts: duplicate {r.target} (declared by the base too; keep it in {was.file} and "
                            f"drop it from {r.origin.file}) [{was}, {r.origin}]")
    base, drop_problems = apply_contract_drops(base, own_drops, base_name)
    return base + own, problems + drop_problems


def check_contracts() -> tuple[list[str], tuple[int, int, int, int]]:
    loaded = load_contracts()
    if loaded is None:
        return [f"contracts: {CONTRACTS_OWN} not found"], (0, 0, 0, 0)
    all_rows, problems = loaded
    tools, tests = scan_tooling()
    # `?` の行は、 対象もテストも無い派生では見ない
    rows = [r for r in all_rows
            if not r.optional or r.target in tools or (r.test != "-" and r.test in tests)]
    named_tools = {r.target for r in rows}
    named_tests = {r.test for r in rows if r.test != "-"}
    origin_of = {r.target: r.origin for r in rows}
    test_origin = {r.test: r.origin for r in rows if r.test != "-"}
    for t in sorted(tools - named_tools):
        problems.append(f"contracts: no promise names .tooling/{t} (say in {CONTRACTS_OWN} what it keeps, or remove it)")
    for t in sorted(tests - named_tests):
        problems.append(f"contracts: no promise names the test .tooling/{t} "
                        f"(a test guards a promise of {CONTRACTS_OWN}, or goes)")
    for t in sorted(named_tools - tools):
        problems.append(f"contracts: missing .tooling/{t} (a row of the contracts files names it) [{origin_of[t]}]")
    for t in sorted(named_tests - tests):
        problems.append(f"contracts: missing test .tooling/{t} (a row of the contracts files names it) [{test_origin[t]}]")
    unguarded = sum(1 for r in rows if r.test == "-")
    return problems, (len(tools), len(rows), unguarded, len(tests))


def main() -> int:
    files = tracked()
    lp, folders = check_layout(files)
    cp, (tools, promises, unguarded, tests) = check_contracts()
    for line in lp + cp:
        print(line)
    print(f"layout: {folders} folders checked, {len(lp)} problems")
    print(f"contracts: {tools} tools, {promises} promises ({unguarded} with no test), {tests} tests, {len(cp)} problems")
    return 1 if lp or cp else 0


if __name__ == "__main__":
    sys.exit(main())
