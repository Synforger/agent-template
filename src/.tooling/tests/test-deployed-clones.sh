#!/bin/bash
# .tooling/startup/check-deployed-clones.sh の test。 作り物の origin と、 そこから取った clone を組み、
# origin だけを先へ進めて「遅れている」 が出る事、 取り込むと緑へ戻る事、 分からない時にそう名乗る事を確かめる。
#
#   bash .tooling/tests/test-deployed-clones.sh
set -uo pipefail

CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/startup/check-deployed-clones.sh"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

# 作り物の repo は、 この機械の git の設定 (= hook や署名) に触れさせない
export GIT_CONFIG_GLOBAL="${T}/gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "${GIT_CONFIG_GLOBAL}"
tgit() { git -c user.name=t -c user.email=t@example.invalid "$@"; }

LIST="${T}/deployed-clones.txt"
run() { HOME="${T}/home" DEPLOYED_CLONES_FILE="${LIST}" bash "${CHECK}"; }

# <説明> <期待する行の正規表現> : 出力のどこかの行が一致すれば緑
expect() {
    local what="$1" pattern="$2" out
    out="$(run)"
    if grep -qE -- "${pattern}" <<< "${out}"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "${what}" "${pattern}" "${out//$'\n'/ | }"
    fi
}

# <説明> : 出力が 1 行も無ければ緑
expect_silent() {
    local what="$1" out
    out="$(run)"
    if [ -z "${out}" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  want: no output\n  got:  %s\n' "${what}" "${out//$'\n'/ | }"
    fi
}

# origin を n commit 先へ進める (= 別の機械が push した分の代わり)
advance_origin() {
    local n="$1" i
    for i in $(seq 1 "${n}"); do
        tgit -C "${T}/elsewhere" commit -q --allow-empty -m "landed elsewhere ${i}"
    done
    tgit -C "${T}/elsewhere" push -q origin develop
}

mkdir -p "${T}/home"
tgit init -q --bare -b develop "${T}/origin.git"
tgit clone -q "${T}/origin.git" "${T}/elsewhere" 2>/dev/null
tgit -C "${T}/elsewhere" checkout -q -b develop 2>/dev/null
tgit -C "${T}/elsewhere" commit -q --allow-empty -m "first"
tgit -C "${T}/elsewhere" push -q origin develop
tgit clone -q "${T}/origin.git" "${T}/home/app"

# --- 宣言が無い ---
rm -f "${LIST}"
expect_silent "no declaration file: nothing is printed"

printf '# only a comment\n\n' > "${LIST}"
expect_silent "a file with only comments and blank lines: nothing is printed"

# --- 揃っている ---
printf '# name  clone  branch\napp  %s  develop\n' "${T}/home/app" > "${LIST}"
expect "a clone at the tip of origin is ok" '^clone_deploy\(app\): ok \(HEAD has origin/develop [0-9a-f]+\)$'

# --- 遅れている (= この test が実証する本体) ---
advance_origin 2
expect "origin moved 2 commits ahead: the clone is behind by 2" \
    '^clone_deploy\(app\): BEHIND 2 commit\(s\) vs origin/develop \([0-9a-f]+ landed elsewhere 2\)$'

# 数えるだけで取り込まない (= clone の HEAD は動いていない)
head_before="$(tgit -C "${T}/home/app" rev-parse HEAD)"
run >/dev/null
if [ "$(tgit -C "${T}/home/app" rev-parse HEAD)" = "${head_before}" ] \
    && [ -z "$(tgit -C "${T}/home/app" status --porcelain)" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: the check moved the clone's HEAD or touched its working tree"
fi

# `~` で書いた場所も同じ clone を指す
printf 'app  ~/app  develop\n' > "${LIST}"
expect "a path written with ~ resolves under HOME" '^clone_deploy\(app\): BEHIND 2 commit'

# --- origin に届かない: 最後に知っている origin と比べ、 そう名乗る ---
mv "${T}/origin.git" "${T}/origin.away"
expect "origin unreachable: compares with the last known origin and says so" \
    '^clone_deploy\(app\): BEHIND 2 commit\(s\) vs origin/develop \(.*\) \(not fetched: compared with the last known origin/develop\)$'
mv "${T}/origin.away" "${T}/origin.git"

# --- 取り込むと緑へ戻る ---
tgit -C "${T}/home/app" pull -q --ff-only origin develop
expect "after pulling, the clone is ok again" '^clone_deploy\(app\): ok \(HEAD has origin/develop [0-9a-f]+\)$'

# 別の branch に居ても、 追う branch の先頭を含んでいれば遅れていない
tgit -C "${T}/home/app" checkout -q -b local-work
tgit -C "${T}/home/app" commit -q --allow-empty -m "local only"
expect "a clone on another branch that contains the tip is ok" '^clone_deploy\(app\): ok '
advance_origin 1
expect "a clone on another branch that lacks the new tip is behind" '^clone_deploy\(app\): BEHIND 1 commit'

# --- 分からない ---
printf 'gone  %s/home/nowhere  develop\n' "${T}" > "${LIST}"
expect "no clone at the declared place" '^clone_deploy\(gone\): UNKNOWN \(no clone at .*/nowhere\)$'

printf 'app  ~/app  no-such-branch\n' > "${LIST}"
expect "the declared branch does not exist on origin" \
    '^clone_deploy\(app\): UNKNOWN \(no origin/no-such-branch in ~/app\)$'

printf 'app  ~/app\n' > "${LIST}"
expect "a line with a missing field" '^clone_deploy\(app\): UNKNOWN \(the line needs <name> <clone path> <branch>\)$'

# --- 複数行: 1 clone 1 行、 宣言の順 ---
printf 'one  ~/app  develop\n# between\ngone  ~/nowhere  develop\ntwo  ~/app  develop' > "${LIST}"
lines="$(run | sed -E 's/^clone_deploy\(([a-z]+)\).*/\1/' | tr '\n' ' ')"
if [ "${lines}" = "one gone two " ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: one line per declared clone, in order (the last line has no newline): got '${lines}'"
fi

echo "test-deployed-clones: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
