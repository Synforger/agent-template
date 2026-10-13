#!/bin/bash
# .tooling/rules/rule-hits-summary.py の test。 作り物の階層 (= 親と project 1 つ、 それぞれ台帳・rule file・記録) で、
# 記録の 4 通りの書き方 (= ID 直書き / 見出し / 本文の抜粋 / 文中の ID) が正しい ID に寄り、
# 寄らない物が unresolved に残り、 同じ綴りの記録が階層ごとに別の rule へ寄ることを確かめる。
# ID は頭の文字 (= 親 R- / project P- / subproject S-) が指す台帳へ、 記録の書かれた階層から
# 親までの系列の中で寄る。 文字を分ける前に書かれ、 同じ番号が系列の台帳 2 つ以上に在る記録は数えない。
# 見出しの前半だけを書いた記録は、 寄せ先が 1 つに決まる時だけ寄り、 退役した見出しで書かれた
# 記録は台帳に残る退役の行へ寄る。 階層が日を宣言していれば、 その日より前の寄らない記録は
# 数から外れ、 その日以後の物は数に残る。
# 加えて、 届かない相手を省く照合 (= `_closer`) が省かない照合と同じ答えを出すことを、
# 全組み合わせで突き合わせる。
#
#   bash .tooling/tests/test-rule-hits-summary.sh
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rules/rule-hits-summary.py"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

# script は自分の置き場から階層の根を決めるので、 作り物の階層の中へ写して走らせる
mkdir -p "${T}/.tooling/rules" "${T}/rules" "${T}/journal/2026-01-01"
mkdir -p "${T}/projects/demo/rules" "${T}/projects/demo/journal/2026-01-01"
cp "${SRC}" "${T}/.tooling/rules/rule-hits-summary.py"
RUN="${T}/.tooling/rules/rule-hits-summary.py"

cat > "${T}/rules/always.md" <<'MD'
# rules

## § git

### 基本

- commit message は英語で書く
- こまめに commit する (= 1 つの変更で 1 つ)

## § quality

### 緑と言う前に

- 通る道を最後まで静的に読み、 落ちる箇所を全部出してから直す

### 検出機構の整備 = 構造的に全カテゴリ網羅

- 直接対象を書いたら、 同種の全カテゴリを列挙する

### 番人の運用と配備の手順を機械にする

- 配備は script 1 本で行う

### 番人の運用と点検の手順を機械にする

- 点検は起動時に行う
MD
cat > "${T}/rules/registry.jsonl" <<'JSONL'
{"id": "R-0001", "file": "rules/always.md", "heading": "基本", "path": "§ git > 基本", "retired": false}
{"id": "R-0002", "file": "rules/always.md", "heading": "緑と言う前に", "path": "§ quality > 緑と言う前に", "retired": false}
{"id": "R-0003", "file": "rules/always.md", "heading": "検出機構の整備 = 構造的に全カテゴリ網羅", "path": "§ quality > 検出機構の整備 = 構造的に全カテゴリ網羅", "retired": false}
{"id": "R-0004", "file": "rules/always.md", "heading": "番人の運用と配備の手順を機械にする", "path": "§ quality > 番人の運用と配備の手順を機械にする", "retired": false}
{"id": "R-0005", "file": "rules/always.md", "heading": "番人の運用と点検の手順を機械にする", "path": "§ quality > 番人の運用と点検の手順を機械にする", "retired": false}
{"id": "R-0009", "file": "rules/always.md", "heading": "数字は公式ソースなし = 書かない", "path": "§ style > 数字は公式ソースなし = 書かない", "retired": true}
JSONL
cat > "${T}/journal/2026-01-01/session-01-rule-hits.jsonl" <<'JSONL'
{"session": "2026-01-01-01", "fired": ["R-0001"], "violated": [{"id": "R-0002", "by": "user"}]}
{"session": "2026-01-01-01", "rule": "git/基本", "kind": "hit"}
{"session": "2026-01-01-01", "rule": "always/こまめに commit する", "kind": "hit"}
{"session": "2026-01-01-01", "rule": "quality: 通る道を最後まで静的に読み", "kind": "violation", "by": "self"}
{"session": "2026-01-01-01", "rule": "R-0002 の件", "kind": "hit"}
{"session": "2026-01-01-01", "rule": "まったく関係のない別の話題について", "kind": "hit"}
{"session": "2026-01-01-01", "rule": "まったく関係のない別の話題について", "kind": "hit"}
{"session": "2026-01-01-01", "rule": "git/どこにも書かれていない決まりごと", "kind": "hit"}
{"session": "2026-01-01-01", "rule": "always/基本", "kind": "hit"}
{"session": "2026-01-01-01", "rule": "quality/検出機構の整備", "kind": "hit"}
{"session": "2026-01-01-01", "rule": "quality/番人の運用と", "kind": "hit"}
{"session": "2026-01-01-01", "rule": "style: 数字は公式ソースなし = 書かない", "kind": "hit"}
JSONL

# project の階層: 見出しも番号も親と同じ綴りで、 指す rule は別 (= ID は頭の文字だけが違う)
printf '# demo\n\n## 基本\n\n- demo の中だけの決まり\n' > "${T}/projects/demo/rules/always.md"
printf '%s\n' '{"id": "P-0001", "file": "projects/demo/rules/always.md", "heading": "基本", "path": "基本", "retired": false}' \
    > "${T}/projects/demo/rules/registry.jsonl"
printf '%s\n' '{"session": "2026-01-01-01", "rule": "always/基本", "kind": "hit"}' \
    '{"session": "2026-01-01-01", "rule": "demo/宣言の日より前に造語で書いた記録", "kind": "hit"}' \
    > "${T}/projects/demo/journal/2026-01-01/session-01-rule-hits.jsonl"
# 宣言の日 (= 01-02) を挟んで、 同じく寄らない記録を前後に 1 件ずつ置く
mkdir -p "${T}/projects/demo/journal/2026-01-03"
printf '%s\n' '{"session": "2026-01-03-01", "rule": "demo/宣言の日より後に造語で書いた記録", "kind": "hit"}' \
    > "${T}/projects/demo/journal/2026-01-03/session-01-rule-hits.jsonl"
printf '%s\n' '{"by_id_since": "2026-01-02", "lettered_since": "2026-01-04T00:00:00+09:00", "why": "test"}' \
    > "${T}/projects/demo/rules/hits-since.json"
# 頭の文字を分けた時刻 (= 01-04) より前に、 project の journal へ R- で書かれた記録: 0001 は親と
# project の両方の台帳に在る番号 (= どちらを指したか決められない)、 0004 は親にしか無い番号
printf '%s\n' '{"session": "2026-01-03-01", "ts": "2026-01-03T10:00:00+09:00", "fired": ["R-0001", "R-0004"]}' \
    >> "${T}/projects/demo/journal/2026-01-03/session-01-rule-hits.jsonl"
# 分けた後: 同じ journal に親の番号と自階層の番号が並んでも、 文字で決まる
mkdir -p "${T}/projects/demo/journal/2026-01-05"
printf '%s\n' '{"session": "2026-01-05-01", "ts": "2026-01-05T10:00:00+09:00", "fired": ["R-0001", "P-0001"]}' \
    > "${T}/projects/demo/journal/2026-01-05/session-01-rule-hits.jsonl"
# subproject の階層: 記録は 親 / project / 自階層 の 3 つの台帳の番号を持つ
SUB="${T}/projects/demo/subprojects/sub"
mkdir -p "${SUB}/rules" "${SUB}/journal/2026-01-05"
printf '# sub\n\n## 基本\n\n- sub の中だけの決まり\n' > "${SUB}/rules/always.md"
printf '%s\n' '{"id": "S-0001", "file": "projects/demo/subprojects/sub/rules/always.md", "heading": "基本", "path": "基本", "retired": false}' \
    > "${SUB}/rules/registry.jsonl"
printf '%s\n' '{"session": "2026-01-05-01", "ts": "2026-01-05T11:00:00+09:00", "fired": ["S-0001", "P-0001", "R-0005"]}' \
    > "${SUB}/journal/2026-01-05/session-01-rule-hits.jsonl"

# <説明> <期待する行の正規表現> [引数] : 出力のどこかの行が一致すれば緑
expect() {
    local what="$1" pattern="$2" out
    out="$(python3 "${RUN}" ${3-} 2>&1)"
    if grep -qE -- "${pattern}" <<< "${out}"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "${what}" "${pattern}" "${out//$'\n'/ | }"
    fi
}

expect "1 行の集計: 生きた rule 7 (= 退役の行は数えない)、 session 5、 寄らなかった記録 5 件 (= 宣言の日より前の 1 件は外れる)" \
    '^rule_hits: 7 live rules, 5 sessions over 4d .*unresolved=5$'
expect "見出し 2 件・本文の抜粋・ID 直書きが同じ rule に寄り、 project の journal に書かれた R- も親へ寄る (= 発火 4 + 1)" \
    '^  R-0001  発火   5  違反   0  rules/always.md :: § git > 基本$' --detail
expect "同じ綴りの記録も P- の ID も、 project の階層の rule に寄る (= 見出し 1 + 自階層の journal 1 + subproject の journal 1)" \
    '^  P-0001  発火   3  違反   0  projects/demo/rules/always.md :: 基本$' --detail
expect "subproject の journal の S- は自階層の rule に寄る" \
    '^  S-0001  発火   1  違反   0  projects/demo/subprojects/sub/rules/always.md :: 基本$' --detail
expect "subproject の journal の R- は、 間の project を越えて親の rule に寄る" \
    '^  R-0005  発火   1  違反   0  rules/always.md :: § quality > 番人の運用と点検の手順を機械にする$' --detail
expect "文字を分ける前の R- でも、 親にしか無い番号は親へ寄る" \
    '^  R-0004  発火   1  違反   0  rules/always.md :: § quality > 番人の運用と配備の手順を機械にする$' --detail
expect "文字を分ける前の R- で、 番号が親と project の両方に在る記録は数えず、 階層つきで出る" \
    '^# 数えない記録 1 件  \[projects/demo\]  \(= ID の頭の文字を階層で分ける前に書かれ' --unresolved
expect "内訳にも、 決められずに数えなかった記録の数が出る" \
    '^ +1 written before the tiers. ids took their own letter' --detail
expect "指摘された違反は 3 倍、 自分で気づいた違反は 1 倍 (= 3 + 1)、 文中の ID も寄る (= 発火 1)" \
    '^  R-0002  違反   4  発火   1  rules/always.md :: § quality > 緑と言う前に$' --detail
expect "見出しの前半だけを書いた記録は、 その見出しの rule に寄る" \
    '^  R-0003  発火   1  違反   0  rules/always.md :: § quality > 検出機構の整備 = 構造的に全カテゴリ網羅$' --detail
expect "退役した見出しで書かれた記録は、 台帳に残る退役の行に寄る" \
    '^  R-0009  発火   1  違反   0  rules/always.md :: § style > 数字は公式ソースなし = 書かない$' --detail
expect "前半が 2 つの見出しに含まれる記録は、 どちらにも寄せない" \
    '^    1  \[\.\]  quality/番人の運用と$' --unresolved
expect "寄らなかった記録は種類と件数で残る" '^# 台帳に寄せられなかった記録 4 種 / 5 件$' --unresolved
expect "宣言の日以後の寄らない記録は数に残る" \
    '^    1  \[projects/demo\]  demo/宣言の日より後に造語で書いた記録$' --unresolved
expect "宣言の日より前の寄らない記録は、 数えない記録として階層と日付つきで出る" \
    '^# 数えない記録 1 件  \[projects/demo\]  \(= 2026-01-02 より前。' --unresolved
expect "内訳にも数えない記録の数が出る" '^ +1 unresolved before a tier.s declared day' --detail
expect "頭が同じ別の記録に引きずられない (= git/基本 は寄り、 これは寄らない)" \
    '^    1  \[\.\]  git/どこにも書かれていない決まりごと$' --unresolved
expect "同じ記録は 1 行にまとまる" '^    2  \[\.\]  まったく関係のない別の話題について$' --unresolved

# 省く照合と省かない照合を、 rule file の全行 × 記録の全抜粋で突き合わせる。 抜粋には、 文字の数は
# 同じで並びだけ違う物を混ぜる (= 安い上限は満点、 本当の一致度は低い、 という差が出る組)
out="$(python3 - "${RUN}" "${T}" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("summary", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root = sys.argv[2]
cands = open(f"{root}/rules/always.md", encoding="utf-8").read().splitlines()
cands += ["", "基本", "§ git > 基本", "緑と言う前に", "こまめにcommitする"]
bodies = [json.loads(line).get("rule", "") for line in open(f"{root}/journal/2026-01-01/session-01-rule-hits.jsonl", encoding="utf-8")]
bodies += ["基本", "こまめに commit", "静的に読み、 落ちる箇所を全部出して", "commit message は英語", ""]
bodies += ["".join(reversed(m._norm(c))) for c in cands]
wrong = full = lower = 0
for body in bodies:
    nbody = m._norm(body.split("/")[-1])
    for cand in cands:
        plain = m.difflib.SequenceMatcher(None, nbody, m._norm(cand)).ratio()
        pruned = m._closer(nbody, cand)
        if pruned is None:
            wrong += plain >= m.ACCEPT     # 採られるはずの相手を省いた
        else:
            full += 1
            lower += plain < m.ACCEPT      # 上限は届いたが、 本当の一致度は届かない組
            wrong += pruned != plain       # 値が違う
print(f"wrong={wrong} full={full} lower={lower}")
PY
)"
if [[ "${out}" =~ ^wrong=0\ full=[1-9][0-9]*\ lower=[1-9] ]]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    printf 'FAIL: 省く照合が省かない照合と食い違う、 または上限と本当の一致度に差が出る組を 1 つも試していない\n  got: %s\n' "${out}"
fi

echo "rule-hits-summary: ${pass} ok, ${fail} FAIL"
[ "${fail}" -eq 0 ]
