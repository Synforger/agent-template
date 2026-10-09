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
build; mkdir -p "${R}/.tooling/work/sub"; sed -i '' 's#^.tooling/work : \*.sh$#.tooling/work : *.sh sub/#' "${R}/.tooling/layout.txt"
expect "folder と書かれて自分の行が無い物が出る" '^layout: no line for \.tooling/work/sub/ '
build; sed -i '' 's#^\. : README.md#. : README.md GONE.md#' "${R}/.tooling/layout.txt"
expect "当たる実物の無い名前が出る (= 消し忘れ)" '^layout: nothing matches GONE\.md in the line of \. '
build; printf 'gone : *.md\n' >> "${R}/.tooling/layout.txt"
expect "当たる folder の無い行が出る" '^layout: nothing matches the line of gone '
build; printf 'x\n' > "${R}/.tooling/work/other.py"; sed -i '' 's#^.tooling/work : \*.sh$#.tooling/work : *.sh *.py#' "${R}/.tooling/layout.txt"
expect "約束の表に載っていない道具が出る" '^contracts: no promise names \.tooling/work/other\.py '
build; printf 'x\n' > "${R}/.tooling/tests/test-extra.sh"
expect "約束の表に載っていないテストが出る" '^contracts: no promise names the test \.tooling/tests/test-extra\.sh '
build; printf '%s\n' 'work/absent.sh | - | 無い道具の約束' >> "${R}/.tooling/contracts.txt"
expect "表の行が指す道具が無ければ出る" '^contracts: missing \.tooling/work/absent\.sh '
build; printf '%s\n' 'work/tool.sh | tests/test-absent.sh | 無いテストが守る約束' >> "${R}/.tooling/contracts.txt"
expect "表の行が指すテストが無ければ出る" '^contracts: missing test \.tooling/tests/test-absent\.sh '

# git の中: 無視される file は見ない、 まだ追っていない file は見る、 無視される folder は行が要る
build
git -C "${R}" init -q
printf 'secret.local\ncache/\n' > "${R}/.gitignore"
sed -i '' 's#^\. : README.md#. : README.md .gitignore#' "${R}/.tooling/layout.txt"
git -C "${R}" add -A >/dev/null 2>&1
printf 'x\n' > "${R}/secret.local"
expect "git が無視する file は宣言の対象にしない" ""
printf 'x\n' > "${R}/new.txt"
expect "まだ追っていない file は、 commit の前から出る" '^layout: undeclared new\.txt '
rm "${R}/new.txt"; mkdir -p "${R}/cache"; printf 'x\n' > "${R}/cache/a.bin"
expect "git が無視する folder も、 何が溜まるかの宣言が無ければ出る" '^layout: undeclared cache/ '

echo "check-declarations: ${pass} ok, ${fail} FAIL"
[ "${fail}" -eq 0 ]
