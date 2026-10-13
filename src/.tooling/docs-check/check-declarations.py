#!/usr/bin/env python3
"""check-declarations.py - 宣言と実物を両方向で突き合わせる (= LLM 不使用)。

置き場とテストは、 足す側の判断に任せると増える一方になる (= 足す理由は毎回在り、 足さない理由と
置いてよい場所はどこにも書かれていない)。 ここは 2 枚の宣言を真値にして、 実物をそれに合わせる:

  .tooling/layout.txt     どの folder の直下に何を置いてよいか
  .tooling/contracts.txt  道具が外に対して守る約束 1 行 ↔ それを試すテスト 1 本

宣言は人が読む 1 枚で、 検査が読むのも同じ 1 枚 (= 足す時は、 その 1 枚の差分に並ぶ)。

置き場 (= layout.txt) の書式: `<folder> : <直下に置いてよい名前> ...`
  - 名前は 1 段ぶんの fnmatch (= `*.sh` / `session-[0-9][0-9].md`)
  - `x/`   = その名前の folder (= その folder 自身の行が要る)
  - `x/**` = その名前の folder と、 その下の全部 (= 中は宣言しない。 日付で増える記録、 残す前提の無い出力、 別の道具の持ち物)
  - folder の側も段ごとの fnmatch で書ける (= `projects/*` は project のどれにも当たる。 入れ子の決まりはこの形で書く)
  - `?x` = 機械によっては無い物 (= git が運ばない folder や file。 無くても消し忘れとは数えない)
  - 「当たる実物が無い」 と数えるのは、 そのままの綴りで書かれた folder の行と名前だけ。 `*` などを含む
    綴りは、 繰り返される物の形の決まりで、 今 0 個でも明日 1 つ出来る (= git が運ばない階層を名指す行は、
    それを持たない機械では必ず 0 個になる)
  - 見るのは、 git が追う file と、 まだ追っていないが無視もしていない file、 それに実物の folder
    (= git が無視する file は対象外。 無視される folder は、 中に何が溜まるかを言う行が要る)。
    git から見える file が 1 つも無い folder (= 自分の repo を持つ project の中) は、 実物の名前を全部見る

約束 (= contracts.txt) の書式: `<対象の script> | <守るテスト。 無ければ -> | <約束 1 文>`
  - 対象とテストは `.tooling/` からの相対 path

出る物 (= 1 行 1 件、 無ければ要約の 2 行だけ。 件が在れば exit 1):
  layout: undeclared ...       宣言に無い file / folder が在る
  layout: no line for ...      `x/` と書かれた folder に、 その folder 自身の行が無い
  layout: nothing matches ...  宣言の行か名前に、 当たる実物が 1 つも無い (= 消し忘れ)
  contracts: no promise ...    約束の表に載っていない道具 / テストが在る
  contracts: missing ...       表の行が指す対象 / テストが無い

走らせ方: python3 .tooling/docs-check/check-declarations.py [--root <dir>]
"""
import fnmatch
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if "--root" in sys.argv:
    ROOT = os.path.abspath(sys.argv[sys.argv.index("--root") + 1])
LAYOUT = ".tooling/layout.txt"
CONTRACTS = ".tooling/contracts.txt"
# 道具が自分で置く物 (= OS と git と実行の副産物。 宣言の対象にしない)
NOISE = {".DS_Store", "__pycache__", ".git"}
SHAPE = re.compile(r"[*?\[]")   # fnmatch の記号を含む綴り = 形の決まり
# 約束の表が対象にする道具の置き場 (= 役割の folder の直下) と、 道具として数える拡張子
TOOL_SUFFIXES = (".sh", ".py")
TEST_DIR = "tests"


def read_lines(rel):
    try:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
            return [ln.split("#", 1)[0].rstrip() for ln in f]
    except OSError:
        return None


def seg_match(path, pattern):
    """段の数が同じで、 段ごとに fnmatch が通る。"""
    a, b = path.split("/"), pattern.split("/")
    return len(a) == len(b) and all(fnmatch.fnmatchcase(x, y) for x, y in zip(a, b))


def tracked():
    """git が追う file と、 追っていないが無視もしていない file (= ROOT 相対)。 git の外で回した時は None。"""
    try:
        r = subprocess.run(["git", "-C", ROOT, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                           capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return [p for p in r.stdout.decode("utf-8", "replace").split("\0") if p]


def children(folder, files):
    """その folder の直下の (名前, folder か) の一覧 (= 何を見るかは冒頭の説明のとおり)。"""
    prefix = "" if folder == "." else folder + "/"
    seen = {}
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


def check_layout(files):
    lines = read_lines(LAYOUT)
    if lines is None:
        return [f"layout: {LAYOUT} not found"], 0
    rules = []  # (folder の pattern, [(名前の pattern, 種類)])  種類 = file / dir / free
    optional = set()  # (行, 名前) = `?` の付いた、 機械によっては無い物
    for ln in lines:
        if ":" not in ln:
            continue
        folder, names = ln.split(":", 1)
        entries = []
        for n in names.split():
            if n.startswith("?"):
                n = n[1:]
                optional.add((len(rules), len(entries)))
            if n.endswith("/**"):
                entries.append((n[:-3], "free"))
            elif n.endswith("/"):
                entries.append((n[:-1], "dir"))
            else:
                entries.append((n, "file"))
        rules.append((folder.strip(), entries))

    problems = []
    used_rules, used_names = set(), set()
    todo, done = ["."], set()
    while todo:
        folder = todo.pop()
        if folder in done:
            continue
        done.add(folder)
        mine = [(i, r) for i, r in enumerate(rules) if seg_match(folder, r[0])]
        if not mine:
            problems.append(f"layout: no line for {folder}/ (a line names it as a folder, none says what it may hold)")
            continue
        for name, is_dir in sorted(children(folder, files).items()):
            hit = None
            for i, (_pat, entries) in mine:
                for j, (npat, kind) in enumerate(entries):
                    if fnmatch.fnmatchcase(name, npat) and (kind == "file") != is_dir:
                        hit = (i, j, kind)
                        break
                if hit:
                    break
            path = name if folder == "." else f"{folder}/{name}"
            if not hit:
                problems.append(f"layout: undeclared {path}{'/' if is_dir else ''} "
                                f"(add it to the line of {folder}/ in {LAYOUT}, or move it)")
                continue
            used_rules.add(hit[0])
            used_names.add(hit[:2])
            if hit[2] == "dir":
                todo.append(path)
    for i, (pat, entries) in enumerate(rules):
        reached = any(seg_match(f, pat) for f in done)
        if i not in used_rules and not reached:
            if not SHAPE.search(pat):
                problems.append(f"layout: nothing matches the line of {pat} (drop the line)")
            continue
        for j, (npat, _kind) in enumerate(entries):
            if (i, j) in used_names or (i, j) in optional or SHAPE.search(npat):
                continue
            if reached:
                problems.append(f"layout: nothing matches {npat} in the line of {pat} "
                                f"(drop the name, or write ?{npat} if only some machines have it)")
    return problems, len(done)


def check_contracts():
    lines = read_lines(CONTRACTS)
    if lines is None:
        return [f"contracts: {CONTRACTS} not found"], (0, 0, 0, 0)
    rows = []
    for ln in lines:
        parts = [p.strip() for p in ln.split("|")]
        if len(parts) == 3 and parts[0]:
            rows.append(parts)
    tooling = os.path.join(ROOT, ".tooling")
    tools, tests = set(), set()
    try:
        for e in os.scandir(tooling):
            if e.is_file() and e.name.endswith(TOOL_SUFFIXES):
                tools.add(e.name)
            elif e.is_dir() and not e.name.startswith(("_", ".")) and e.name not in NOISE:
                for f in os.scandir(e.path):
                    if f.is_file() and f.name.endswith(TOOL_SUFFIXES):
                        (tests if e.name == TEST_DIR else tools).add(f"{e.name}/{f.name}")
    except OSError:
        pass
    problems = []
    named_tools = {r[0] for r in rows}
    named_tests = {r[1] for r in rows if r[1] != "-"}
    for t in sorted(tools - named_tools):
        problems.append(f"contracts: no promise names .tooling/{t} (say in {CONTRACTS} what it keeps, or remove it)")
    for t in sorted(tests - named_tests):
        problems.append(f"contracts: no promise names the test .tooling/{t} (a test guards a promise of {CONTRACTS}, or goes)")
    for t in sorted(named_tools - tools):
        problems.append(f"contracts: missing .tooling/{t} (a row of {CONTRACTS} names it)")
    for t in sorted(named_tests - tests):
        problems.append(f"contracts: missing test .tooling/{t} (a row of {CONTRACTS} names it)")
    unguarded = sum(1 for r in rows if r[1] == "-")
    return problems, (len(tools), len(rows), unguarded, len(tests))


def main():
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
