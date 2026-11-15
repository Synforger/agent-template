#!/bin/bash
# .tooling/docs-check/check-declarations.py の test。 作り物の木に置き場の宣言と約束の表を置き、
# 揃っていれば緑で、 宣言に無い file・行の無い folder・当たる物の無い宣言・表に無い道具とテスト・
# 実物の無い行が、 それぞれ 1 行で出ることを確かめる。 git の中では、 無視される file を見ず、
# まだ追っていない file は見ることも確かめる。 FAIL 1 行ずつ。
#
#   bash .tooling/tests/test-check-declarations.sh
set -u

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs-check/check-declarations.py"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

# 揃った木: 根に 1 file、 道具 1 本とそのテスト、 中を宣言しない置き場、 同じ形の階層 2 つ
build() {
    rm -rf "${T:?}/tree"
    R="${T}/tree"
    mkdir -p "${R}/.tooling/work" "${R}/.tooling/tests" "${R}/.tooling/_output/any/deep" "${R}/tiers/a/notes" "${R}/tiers/b"
    printf 'x\n' > "${R}/README.md"
    printf 'x\n' > "${R}/.tooling/work/tool.sh"
    printf 'x\n' > "${R}/.tooling/tests/test-tool.sh"
    printf 'x\n' > "${R}/.tooling/_output/any/deep/scratch.txt"
    printf 'x\n' > "${R}/tiers/a/_README.md"
    printf 'x\n' > "${R}/tiers/a/notes/free.txt"
    printf 'x\n' > "${R}/tiers/b/_README.md"
    cat > "${R}/.tooling/layout.txt" <<'TXT'
# comment
. : README.md .tooling/ tiers/
.tooling : layout.txt contracts.txt _output/** work/ tests/
.tooling/work : *.sh
.tooling/tests : test-*.sh
tiers : */
tiers/* : _README.md notes/**
TXT
    printf '%s\n' '# comment' 'work/tool.sh | tests/test-tool.sh | 道具の約束' > "${R}/.tooling/contracts.txt"
}

# 宣言の 1 行を書き換える: <file> <元の文字列> <替える文字列> (= sed の -i は macOS と Linux で書式が違う)
swap() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if old not in text:
    sys.exit(f"swap: {old!r} is not in {path}")
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
}

# <説明> <期待する行の正規表現。 空なら「件が 0 で exit 0」>
expect() {
    local out rc
    out="$(python3 "${SRC}" --root "${R}" 2>&1)"; rc=$?
    if [ -z "$2" ]; then
        if [ "${rc}" -eq 0 ] && grep -qE '^layout: .* 0 problems$' <<< "${out}" && grep -qE '^contracts: .* 0 problems$' <<< "${out}"; then
            pass=$((pass + 1)); return
        fi
    elif [ "${rc}" -eq 1 ] && grep -qE -- "$2" <<< "${out}"; then
        pass=$((pass + 1)); return
    fi
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want: %s\n  got (exit %s): %s\n' "$1" "${2:-clean}" "${rc}" "${out//$'\n'/ | }"
}

build; expect "揃った木は緑 (= 中を宣言しない置き場の下は見ない、 同じ形の階層は 1 行で足りる)" ""
build; printf 'x\n' > "${R}/stray.txt"
expect "宣言に無い file は、 どの行に足すかつきで出る" '^layout: undeclared stray\.txt \(add it to the line of \./'
build; mkdir -p "${R}/tiers/b/tmp"
expect "階層の 1 つにだけ在る、 形に無い folder が出る" '^layout: undeclared tiers/b/tmp/ '
build; mkdir -p "${R}/.tooling/work/sub"; swap "${R}/.tooling/layout.txt" '.tooling/work : *.sh' '.tooling/work : *.sh sub/'
expect "folder と書かれて自分の行が無い物が出る" '^layout: no line for \.tooling/work/sub/ '
build; swap "${R}/.tooling/layout.txt" '. : README.md' '. : README.md GONE.md'
expect "当たる実物の無い名前が出る (= 消し忘れ)" '^layout: nothing matches GONE\.md in the line of \. '
build; printf 'gone : *.md\n' >> "${R}/.tooling/layout.txt"
expect "当たる folder の無い行が出る" '^layout: nothing matches the line of gone '
# git が運ばない物を名指す宣言は、 それを持たない機械でも緑 (= 階層が 1 つも無い機械、 その機械にだけ在る folder)
build; rm -rf "${R}/tiers/a" "${R}/tiers/b"
expect "形の決まりの行と名前は、 当たる実物が 0 個でも消し忘れに数えない" ""
build; swap "${R}/.tooling/layout.txt" '. : README.md' '. : README.md ?only-here/**'
expect "? の付いた名前は、 無い機械でも緑" ""
build; mkdir -p "${R}/only-here/x"; swap "${R}/.tooling/layout.txt" '. : README.md' '. : README.md ?only-here/**'
expect "? の付いた名前は、 在る機械では宣言として効く" ""
build; printf 'x\n' > "${R}/.tooling/work/other.py"; swap "${R}/.tooling/layout.txt" '.tooling/work : *.sh' '.tooling/work : *.sh *.py'
expect "約束の表に載っていない道具が出る" '^contracts: no promise names \.tooling/work/other\.py '
build; printf 'x\n' > "${R}/.tooling/tests/test-extra.sh"
expect "約束の表に載っていないテストが出る" '^contracts: no promise names the test \.tooling/tests/test-extra\.sh '
build; printf '%s\n' 'work/absent.sh | - | 無い道具の約束' >> "${R}/.tooling/contracts.txt"
expect "表の行が指す道具が無ければ出る" '^contracts: missing \.tooling/work/absent\.sh '
build; printf '%s\n' 'work/tool.sh | tests/test-absent.sh | 無いテストが守る約束' >> "${R}/.tooling/contracts.txt"
expect "表の行が指すテストが無ければ出る" '^contracts: missing test \.tooling/tests/test-absent\.sh '

# 入れ子の階層: folder の側の ** の段は 1 段以上のどんな段にも当たる (= 何段続いても 1 行で足りる)
deep_build() {
    build
    mkdir -p "${R}/tiers/a/sub/b/sub/c/sub/d"
    for t in a/sub/b a/sub/b/sub/c a/sub/b/sub/c/sub/d; do printf 'x\n' > "${R}/tiers/${t}/_README.md"; done
    swap "${R}/.tooling/layout.txt" 'tiers/* : _README.md notes/**' 'tiers/* : _README.md notes/** sub/'
    printf '%s\n' 'tiers/**/sub : */' 'tiers/**/sub/* : _README.md ?notes/** ?sub/' >> "${R}/.tooling/layout.txt"
}
deep_build; expect "入れ子の階層は何段続いても、 ** の 1 行で足りる" ""
deep_build; printf 'x\n' > "${R}/tiers/a/sub/b/sub/c/sub/d/stray.txt"
expect "深い段の宣言に無い file も出る" '^layout: undeclared tiers/a/sub/b/sub/c/sub/d/stray\.txt '
deep_build; mkdir -p "${R}/tiers/a/sub/b/sub/c/tmp"
expect "深い段の形に無い folder が出る" '^layout: undeclared tiers/a/sub/b/sub/c/tmp/ '
deep_build; printf 'tiers/**/gone : *.md\n' >> "${R}/.tooling/layout.txt"
expect "** の行も、 当たる folder が無ければ出ない (= 形の決まり)" ""

# git の中: 無視される file は見ない、 まだ追っていない file は見る、 無視される folder は行が要る
build
git -C "${R}" init -q
printf 'secret.local\ncache/\n' > "${R}/.gitignore"
swap "${R}/.tooling/layout.txt" '. : README.md' '. : README.md .gitignore'
git -C "${R}" add -A >/dev/null 2>&1
printf 'x\n' > "${R}/secret.local"
expect "git が無視する file は宣言の対象にしない" ""
printf 'x\n' > "${R}/new.txt"
expect "まだ追っていない file は、 commit の前から出る" '^layout: undeclared new\.txt '
rm "${R}/new.txt"; mkdir -p "${R}/cache"; printf 'x\n' > "${R}/cache/a.bin"
expect "git が無視する folder も、 何が溜まるかの宣言が無ければ出る" '^layout: undeclared cache/ '

# 型が配る 2 枚 (= layout.base.txt・contracts.base.txt) と、 派生の 2 枚を足して読む
# 型だけの木: 派生の 2 枚を持たない。 型の 2 枚は自分の名前を宣言し、 派生の 2 枚は無くてよい名前として宣言する
base_build() {
    build
    rm -f "${R}/.tooling/layout.txt" "${R}/.tooling/contracts.txt"
    cat > "${R}/.tooling/layout.base.txt" <<'TXT'
# base
. : README.md .tooling/ tiers/
.tooling : layout.base.txt contracts.base.txt ?layout.txt ?contracts.txt _output/** work/ tests/
.tooling/work : *.sh
.tooling/tests : test-*.sh
tiers : */
tiers/* : _README.md notes/**
TXT
    printf '%s\n' '# base' 'work/tool.sh | tests/test-tool.sh | 道具の約束' > "${R}/.tooling/contracts.base.txt"
}
# 派生の 2 枚を足す (= 型の 2 枚に無い物だけ)
own_files() {
    printf '%s\n' '. : own/' 'own : *.txt' > "${R}/.tooling/layout.txt"
    mkdir -p "${R}/own"; printf 'x\n' > "${R}/own/a.txt"
    printf '%s\n' '# own' > "${R}/.tooling/contracts.txt"
}

base_build; expect "型の 2 枚だけで、 派生の 2 枚が無くても緑" ""
base_build; own_files; expect "型の 2 枚に派生の 2 枚を足しても緑 (= 派生は自分の物だけを書く)" ""
base_build; printf 'x\n' > "${R}/stray.txt"
expect "型だけの木でも、 宣言に無い file は赤" '^layout: undeclared stray\.txt '
base_build; rm "${R}/.tooling/contracts.base.txt"
expect "約束の 2 枚が両方無ければ、 無いと出る" '^contracts: \.tooling/contracts\.txt not found'

# 二重の真値: 同じ宣言が型と派生の両方に在れば、 両方の file と行を名指して赤
base_build; own_files; printf '%s\n' 'tiers : */' >> "${R}/.tooling/layout.txt"
expect "置き場の同じ名前が型と派生に在れば、 二重として両方の行を名指す" '^layout: duplicate tiers : \*/ .*\[layout\.base\.txt:[0-9]+, layout\.txt:[0-9]+\]$'
base_build; own_files; printf '%s\n' 'work/tool.sh | tests/test-tool.sh | 道具の約束' >> "${R}/.tooling/contracts.txt"
expect "約束の同じ行が型と派生に在れば、 二重として両方の行を名指す" '^contracts: duplicate work/tool\.sh .*\[contracts\.base\.txt:[0-9]+, contracts\.txt:[0-9]+\]$'
base_build; printf '%s\n' 'work/tool.sh | tests/test-tool.sh | ABC   def' >> "${R}/.tooling/contracts.base.txt"
own_files; printf '%s\n' 'work/tool.sh | tests/test-tool.sh | ＡＢＣ def' >> "${R}/.tooling/contracts.txt"
expect "約束の文の空白と全角半角の差は二重として数える" '^contracts: duplicate work/tool\.sh '
base_build; own_files; printf '%s\n' 'work/tool.sh | tests/test-tool.sh | 別の約束' >> "${R}/.tooling/contracts.txt"
expect "同じ道具に派生が別の約束を足すのは二重でない" ""
base_build; own_files; printf '%s\n' '.tooling/work : *.sh' >> "${R}/.tooling/layout.txt"
expect "行の頭に ./ や末尾の / が違っても同じ folder の同じ名前は二重" '^layout: duplicate \.tooling/work : \*\.sh '

# 外す口: 派生は型の行を理由つきで外せる
base_build; rm -rf "${R}/tiers/a/notes"; printf '%s\n' '!tiers/* : notes/**  # these tiers keep no notes' > "${R}/.tooling/layout.txt"
expect "置き場の型の名前を理由つきで外せる" ""
base_build; printf '%s\n' '!tiers/* : notes/**  # these tiers keep no notes' > "${R}/.tooling/layout.txt"
expect "外した名前の物が在れば、 宣言に無いと出る" '^layout: undeclared tiers/a/notes/ '
base_build; rm -rf "${R}/tiers/a/notes"; printf '%s\n' '!tiers/* : notes/**' > "${R}/.tooling/layout.txt"
expect "理由の無い外す行 (置き場) は赤" '^layout: drop without a reason tiers/\* : notes/\*\* .*\[layout\.txt:1\]$'
base_build; printf '%s\n' '!tiers/* : nothing/**  # no such name' > "${R}/.tooling/layout.txt"
expect "型に無い名前を外す行 (置き場) は赤" '^layout: nothing to drop tiers/\* : nothing/\*\* .*\[layout\.txt:1\]$'
base_build; printf '%s\n' '!tiers/* : notes/**  # in the wrong file' >> "${R}/.tooling/layout.base.txt"
expect "型の file に書いた外す行は赤" '^layout: drop line in a base file tiers/\* .*\[layout\.base\.txt:[0-9]+\]$'
base_build; rm "${R}/.tooling/work/tool.sh" "${R}/.tooling/tests/test-tool.sh"; printf '%s\n' '!work/tool.sh  # this agent keeps no tool' > "${R}/.tooling/contracts.txt"
expect "約束の型の行を理由つきで外せる" ""
base_build; rm "${R}/.tooling/work/tool.sh" "${R}/.tooling/tests/test-tool.sh"; printf '%s\n' '!work/tool.sh' > "${R}/.tooling/contracts.txt"
expect "理由の無い外す行 (約束) は赤" '^contracts: drop without a reason work/tool\.sh .*\[contracts\.txt:1\]$'
base_build; printf '%s\n' '!work/none.sh  # not a base row' > "${R}/.tooling/contracts.txt"
expect "型に無い対象を外す行 (約束) は赤" '^contracts: nothing to drop work/none\.sh .*\[contracts\.txt:1\]$'

# 名指し: 宣言から来た赤は、 型と派生のどちらの file の何行目かを出す
base_build; swap "${R}/.tooling/layout.base.txt" '. : README.md' '. : README.md GONE.md'
expect "型の宣言に実物が無ければ、 型の file の行を名指す" '^layout: nothing matches GONE\.md in the line of \. .*\[layout\.base\.txt:[0-9]+\]$'
base_build; own_files; printf '%s\n' '. : GONE.md' >> "${R}/.tooling/layout.txt"
expect "派生の宣言に実物が無ければ、 派生の file の行を名指す" '^layout: nothing matches GONE\.md in the line of \. .*\[layout\.txt:[0-9]+\]$'
base_build; printf '%s\n' 'work/absent.sh | - | 無い道具の約束' >> "${R}/.tooling/contracts.base.txt"
expect "型の約束の行が指す道具が無ければ、 型の file の行を名指す" '^contracts: missing \.tooling/work/absent\.sh .*\[contracts\.base\.txt:[0-9]+\]$'
base_build; own_files; printf '%s\n' 'work/absent.sh | - | 無い道具の約束' >> "${R}/.tooling/contracts.txt"
expect "派生の約束の行が指す道具が無ければ、 派生の file の行を名指す" '^contracts: missing \.tooling/work/absent\.sh .*\[contracts\.txt:[0-9]+\]$'
base_build; mkdir -p "${R}/tiers/b/sub"; printf '%s\n' 'tiers/* : sub/' > "${R}/.tooling/layout.txt"
expect "folder の行が無い名前は、 その名前を書いた行を名指す" '^layout: no line for tiers/b/sub/ .*\[layout\.txt:1\]$'

# 同じ folder の行で、 名前の形が重なっても偽の赤にしない
base_build; printf 'x\n' > "${R}/.tooling/work/other.sh"; printf '%s\n' '.tooling/work : other.sh' > "${R}/.tooling/layout.txt"
printf '%s\n' 'work/other.sh | - | 別の道具の約束' > "${R}/.tooling/contracts.txt"
expect "型の *.sh に当たる名前を派生が足しても、 当たる実物は在る (= 偽の赤にしない)" ""

# 約束の `?`: 持たない派生もある道具の行 (= 機械全体の hook)
base_build; printf '%s\n' '?work/optional.sh | tests/test-optional.sh | 持たない派生もある道具の約束' >> "${R}/.tooling/contracts.base.txt"
expect "? の行は、 道具もテストも無い派生では見ない" ""
base_build; printf '%s\n' '?work/optional.sh | tests/test-optional.sh | 持たない派生もある道具の約束' >> "${R}/.tooling/contracts.base.txt"
printf 'x\n' > "${R}/.tooling/work/optional.sh"
expect "? の行は、 道具が在って試験が無ければ普通の行として見る" '^contracts: missing test \.tooling/tests/test-optional\.sh '
base_build; printf '%s\n' '?work/optional.sh | tests/test-optional.sh | 持たない派生もある道具の約束' >> "${R}/.tooling/contracts.base.txt"
printf 'x\n' > "${R}/.tooling/work/optional.sh"; printf 'x\n' > "${R}/.tooling/tests/test-optional.sh"
expect "? の行は、 道具もテストも在る派生では普通の行として見る" ""
base_build; printf '%s\n' '?work/optional.sh | tests/test-optional.sh | 持たない派生もある道具の約束' >> "${R}/.tooling/contracts.base.txt"
printf 'x\n' > "${R}/.tooling/tests/test-optional.sh"
expect "? の行は、 試験だけ在って道具が無ければ道具が無いと出る" '^contracts: missing \.tooling/work/optional\.sh '

# 型の checkout の中だけ: init で作った新しい派生が、 派生の 2 枚を何も書かずに緑 (= 型の宣言が init の実物を全部覆う)。
# init の入口は型の checkout にだけ在るので、 派生に降りたこの試験では回さない
TEMPLATE_ROOT="$(cd "$(dirname "${SRC}")/../../.." && pwd)"
INIT="${TEMPLATE_ROOT}/.tooling/init-new-agent.sh"
if [ -f "${INIT}" ]; then
    R="${T}/fresh"; rm -rf "${R}"
    if GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
        bash "${INIT}" "${R}" > "${T}/init.log" 2>&1; then
        expect "init で作った新しい派生は、 派生の 2 枚を書かずに緑 (= 型の 2 枚が init の実物を全部覆う)" ""
    else
        fail=$((fail + 1)); printf 'FAIL: init-new-agent.sh が失敗した: %s\n' "$(tail -3 "${T}/init.log" | tr '\n' ' ')"
    fi
else
    echo "(skip: init で作った派生の検査は型の checkout でだけ回す)"
fi

echo "check-declarations: ${pass} ok, ${fail} FAIL"
[ "${fail}" -eq 0 ]
