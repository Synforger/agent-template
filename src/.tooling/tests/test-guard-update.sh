#!/bin/bash
# .tooling/distribute/guard-update.sh の test。 作り物の番人の clone (= 導入の script は身代わり) とエージェントの
# repo を組み、 追う branch の無い repo では pull を飛ばして番人の導入まで進む事、 追う branch が在れば pull する事、
# pull が止まれば導入へ進まずに止まる事、 1 回断られた fetch は打ち直して通る事を確かめる。
#
#   bash .tooling/tests/test-guard-update.sh
set -uo pipefail

UPDATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/distribute/guard-update.sh"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

# 作り物の repo は、 この機械の git の設定 (= hook や署名) に触れさせない
export GIT_CONFIG_GLOBAL="${T}/gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "${GIT_CONFIG_GLOBAL}"
tgit() { git -c user.name=t -c user.email=t@example.invalid "$@"; }

check() { # <説明> <コマンド...>
    local what="$1"
    shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; cat "${T}/out"; fi
}

# 番人の clone: origin の develop に、 呼ばれたら印を残す導入の script を置く
tgit init -q --bare -b develop "${T}/guard.git"
tgit clone -q "${T}/guard.git" "${T}/guard-src" 2>/dev/null
mkdir -p "${T}/guard-src/scripts"
printf '#!/bin/bash\ntouch "%s/bootstrapped"\n' "${T}" > "${T}/guard-src/scripts/bootstrap-machine.sh"
tgit -C "${T}/guard-src" add -A
tgit -C "${T}/guard-src" commit -q -m "guard"
tgit -C "${T}/guard-src" push -q origin HEAD:develop
tgit clone -q -b develop "${T}/guard.git" "${T}/guard"

# エージェントの repo: 配備の script の写しを持つ (= 自分の置き場からエージェントを決める)
new_agent() {
    rm -rf "${T}/agent" "${T}/bootstrapped"
    mkdir -p "${T}/agent/.tooling/distribute"
    cp "${UPDATE}" "${T}/agent/.tooling/distribute/"
    tgit -C "${T}/agent" init -q
    tgit -C "${T}/agent" add -A
    tgit -C "${T}/agent" commit -q -m first
}

update() {
    GUARD_CLONE="${T}/guard" TMPDIR="${T}" GUARD_UPDATE_FETCH_WAIT_S=0 \
        bash "${T}/agent/.tooling/distribute/guard-update.sh" > "${T}/out" 2>&1
}

# 最初の fetch を 1 回だけ断る git (= GitHub が時々 publickey で断る形の身代わり)
REAL_GIT="$(command -v git)"
mkdir -p "${T}/flaky"
cat > "${T}/flaky/git" <<FLAKY
#!/bin/bash
if [[ " \$* " == *" fetch "* ]] && [ ! -e "${T}/refused-once" ]; then
    touch "${T}/refused-once"
    echo "git@github.com: Permission denied (publickey)." >&2
    exit 128
fi
exec "${REAL_GIT}" "\$@"
FLAKY
chmod +x "${T}/flaky/git"
flaky_update() {
    rm -f "${T}/refused-once"
    PATH="${T}/flaky:${PATH}" update
}

# --- 追う branch の無い repo (= この test が実証する本体) ----------------------------------
new_agent
update
check "追う branch が無くても exit 0" [ $? -eq 0 ]
check "pull を飛ばしたと名乗る" grep -qF "(skipped, no upstream branch)" "${T}/out"
check "番人の導入まで進む" [ -e "${T}/bootstrapped" ]

# --- 追う branch の在る repo は pull する ----------------------------------------------
new_agent
tgit init -q --bare "${T}/agent.git"
tgit -C "${T}/agent" remote add origin "${T}/agent.git"
tgit -C "${T}/agent" push -q -u origin HEAD:master 2>/dev/null
rm -rf "${T}/other"
tgit clone -q "${T}/agent.git" "${T}/other"
tgit -C "${T}/other" commit -q --allow-empty -m "from the other machine"
tgit -C "${T}/other" push -q origin HEAD:master
update
check "追う branch が在れば pull する" [ "$(tgit -C "${T}/agent" log -1 --format=%s)" = "from the other machine" ]
check "pull の後に番人の導入へ進む" [ -e "${T}/bootstrapped" ]

# --- 1 回断られた fetch は打ち直して通る ---------------------------------------------------
rm -f "${T}/bootstrapped"
tgit -C "${T}/other" commit -q --allow-empty -m "after a refused fetch"
tgit -C "${T}/other" push -q origin HEAD:master
flaky_update
check "エージェントの fetch が 1 回断られても exit 0" [ $? -eq 0 ]
check "断られた後の打ち直しで取り込む" [ "$(tgit -C "${T}/agent" log -1 --format=%s)" = "after a refused fetch" ]
check "打ち直した後に番人の導入へ進む" [ -e "${T}/bootstrapped" ]
new_agent
flaky_update
check "番人の fetch が 1 回断られても導入まで進む" [ -e "${T}/bootstrapped" ]
check "断られた事は log に残る" grep -qF "Permission denied" "${T}/guard-update.log"

# --- pull が止まれば導入へ進まない -------------------------------------------------------
new_agent
tgit -C "${T}/agent" remote add origin "${T}/agent.git"
tgit -C "${T}/agent" fetch -q origin
tgit -C "${T}/agent" branch -q -u origin/master 2>/dev/null || tgit -C "${T}/agent" branch -q --set-upstream-to=origin/master
rm -f "${T}/bootstrapped"
mv "${T}/agent.git" "${T}/agent.away"
update
check "pull が止まれば exit 1" [ $? -eq 1 ]
check "pull が止まったと言う" grep -qF "pull が止まりました" "${T}/out"
check "打ち直しの数を言う" grep -qF "fetch が 5 回とも落ちました" "${T}/out"
check "pull が止まれば番人の導入へ進まない" [ ! -e "${T}/bootstrapped" ]

echo "test-guard-update: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
