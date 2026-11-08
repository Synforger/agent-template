#!/bin/bash
# test-pr-land.sh - pr-land.sh は、 検査が通るまで merge せず、 merge されるまで tag を打たない。
# 作り物の gh (= 場面ごとに返す物を file から読む) と、 作り物の origin を持つ repo で通す。 FAIL 1 行ずつ。
set -u
LAND="$(cd "$(dirname "$0")/.." && pwd)/work/pr-land.sh"
WORK="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "${WORK}"' EXIT
fails=0
cases=0
check() {   # check <名前> <条件の終了コード>
    cases=$((cases + 1))
    [ "$2" -eq 0 ] || { echo "FAIL $1"; fails=$((fails + 1)); }
}

# --- 作り物の origin と repo ---
# ⚠ この機械の git 設定から切り離す (= 番人の test と同じ)。 切り離さないと、 作り物の commit が機械の
#    commit の検査で止まり、 「古い main」 と「merge の commit」 が同じ物になる (= tag の位置を見分けられない)
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "${GIT_CONFIG_GLOBAL}"
git init -q --bare "${WORK}/origin.git"
git init -q "${WORK}/repo"
cd "${WORK}/repo" || exit 2
git -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "old main"
git branch -M main
git remote add origin "${WORK}/origin.git"
git push -q origin main
OLD="$(git rev-parse HEAD)"
# merge の commit は別の clone から origin へ入る (= GitHub の上で merge された形。 手元はそれをまだ持っていない)
git clone -q -b main "${WORK}/origin.git" "${WORK}/elsewhere"
git -C "${WORK}/elsewhere" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "the merge"
git -C "${WORK}/elsewhere" push -q origin main
MERGE="$(git -C "${WORK}/elsewhere" rev-parse HEAD)"
check "fixture: 古い main と merge の commit は別物で、 手元は古い側に居て merge の commit をまだ持っていない" \
    "$([ "${#OLD}" = 40 ] && [ "${#MERGE}" = 40 ] && [ "${OLD}" != "${MERGE}" ] && [ "$(git rev-parse HEAD)" = "${OLD}" ] \
        && ! git cat-file -e "${MERGE}^{commit}" 2>/dev/null \
        && [ "$(git ls-remote origin refs/heads/main | cut -f1)" = "${MERGE}" ]; echo $?)"

# --- 作り物の gh: checks は呼ばれるたびに次の 1 行、 merge は記録、 view は state の file ---
cat > "${WORK}/gh" <<'GH'
#!/bin/bash
S="${FAKE_GH}"
echo "$*" >> "${S}/calls"
case "$1 $2" in
    "pr checks")
        n=$(cat "${S}/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "${n}" > "${S}/n"
        line="$(sed -n "${n}p" "${S}/checks")"; [ -n "${line}" ] || line="$(tail -n 1 "${S}/checks")"
        echo "${line}" ;;
    "pr merge") [ -f "${S}/merges" ] && cp "${S}/state.after" "${S}/state"; exit 0 ;;
    "pr view") cat "${S}/state" ;;
esac
GH
chmod +x "${WORK}/gh"
scene() {   # scene <名前> <merge が通るか: yes|no> <checks の行...>
    export FAKE_GH="${WORK}/$1"; mkdir -p "${FAKE_GH}"; shift
    local merges="$1"; shift
    printf '%s\n' "$@" > "${FAKE_GH}/checks"
    # PR の元の branch (= topic) は、 PR の先頭 (= HEAD_AT、 既定は OLD) を指して origin に在る
    git push -q -f origin "${OLD}:refs/heads/topic"
    echo "OPEN main - ${HEAD_AT:-${OLD}} topic" > "${FAKE_GH}/state"
    if [ "${merges}" = yes ]; then touch "${FAKE_GH}/merges"; echo "MERGED main ${MERGE} ${HEAD_AT:-${OLD}} topic" > "${FAKE_GH}/state.after"; fi
    : > "${FAKE_GH}/calls"
}
land() { PR_LAND_GH="${WORK}/gh" PR_LAND_INTERVAL=0 PR_LAND_TIMEOUT="${TIMEOUT:-30}" bash "${LAND}" "$@" 2>&1; }
merged() { grep -c "^pr merge" "${FAKE_GH}/calls"; }
PASS='[{"bucket":"pass","name":"gates"}]'
PENDING='[{"bucket":"pending","name":"gates"}]'

# --- 検査がまだ登録されていない → 走っている → 通った: 通ってから 1 回だけ merge する ---
scene late yes '[]' '[]' "${PENDING}" "${PASS}"
out="$(land 7)"; code=$?
check "検査が後から登録されても、 通るまで待ってから merge する (exit ${code}): ${out}" "$([ "${code}" -eq 0 ] && [ "$(merged)" = 1 ]; echo $?)"
check "merge の前に検査を 4 回見ている" "$([ "$(sed -n '1,4p' "${FAKE_GH}/calls" | grep -c '^pr checks')" = 4 ] && [ "$(sed -n '5p' "${FAKE_GH}/calls" | grep -c '^pr merge 7 --squash --delete-branch')" = 1 ]; echo $?)"
check "着地した PR と commit を言う" "$([[ "${out}" == *"#7 merged into main (${MERGE:0:7})"* ]]; echo $?)"

# --- 検査が 1 つも登録されないまま: merge しない ---
scene never yes '[]'
out="$(TIMEOUT=2 land 7)"; code=$?
check "検査が 1 つも無いままなら merge しない (exit ${code}): ${out}" "$([ "${code}" -eq 1 ] && [ "$(merged)" = 0 ] && [[ "${out}" == *"no check was ever reported"* ]]; echo $?)"

# --- 検査が終わらない: merge しない ---
scene slow yes "${PENDING}"
out="$(TIMEOUT=2 land 7)"; code=$?
check "検査が終わらないなら merge しない (exit ${code})" "$([ "${code}" -eq 1 ] && [ "$(merged)" = 0 ] && [[ "${out}" == *"did not finish"* ]]; echo $?)"

# --- 検査が落ちた: merge しない ---
for bucket in fail cancel; do
    scene "red-${bucket}" yes "[{\"bucket\":\"pass\",\"name\":\"lint\"},{\"bucket\":\"${bucket}\",\"name\":\"gates\"}]"
    out="$(land 7 --tag v9.9.9)"; code=$?
    check "検査が ${bucket} なら merge も tag もしない (exit ${code}): ${out}" "$([ "${code}" -eq 1 ] && [ "$(merged)" = 0 ] && [[ "${out}" == *"a check failed on #7: gates"* ]] && [ -z "$(git tag -l v9.9.9)" ]; echo $?)"
done

# --- 検査は通ったが merge が通らなかった (= 衝突): tag を打たない ---
scene conflict no "${PASS}"
out="$(land 7 --merge --tag v1.0.0)"; code=$?
check "merge されなかったら止まる (exit ${code}): ${out}" "$([ "${code}" -eq 1 ] && [[ "${out}" == *"#7 is OPEN after the merge was asked for"* ]]; echo $?)"
check "merge されなかったら tag を打たない (= 手元にも origin にも無い)" "$([ -z "$(git tag -l v1.0.0)" ] && [ -z "$(git ls-remote --tags origin v1.0.0)" ]; echo $?)"
check "頼んだ merge の仕方で打っている" "$(grep -q '^pr merge 7 --merge --delete-branch' "${FAKE_GH}/calls"; echo $?)"

# --- 着地して tag: merge の commit に付く (= 手元の古い main ではない) ---
scene tagged yes "${PASS}"
out="$(land 7 --tag v1.0.0)"; code=$?
check "着地したら tag を打って push する (exit ${code}): ${out}" "$([ "${code}" -eq 0 ] && [[ "${out}" == *"v1.0.0 placed on ${MERGE:0:7} and pushed"* ]]; echo $?)"
check "tag は merge の commit に付く (= 古い main ではない)" "$([ "$(git rev-parse v1.0.0)" = "${MERGE}" ] && [ "$(git rev-parse v1.0.0)" != "${OLD}" ]; echo $?)"
check "tag は origin にも在る" "$([ "$(git ls-remote --tags origin v1.0.0 | cut -f1)" = "${MERGE}" ]; echo $?)"

check "着地したら、 origin に残っていた元の branch を消す" "$([ -z "$(git ls-remote --heads origin topic)" ] && [[ "${out}" == *"removed the merged branch topic"* ]]; echo $?)"

# --- 元の branch: 残す指定 / PR の後に動いていたら触らない / merge されなかったら触らない ---
scene keep yes "${PASS}"
land 7 --keep-branch >/dev/null
check "--keep-branch では branch を消す指定を付けない" "$(grep -q '^pr merge 7 --squash$' "${FAKE_GH}/calls"; echo $?)"
check "--keep-branch では origin の branch も残す" "$([ -n "$(git ls-remote --heads origin topic)" ]; echo $?)"
HEAD_AT="${MERGE}" scene moved yes "${PASS}"
out="$(land 7)"; code=$?
check "PR の後に動いた branch は消さない (exit ${code}): ${out}" "$([ "${code}" -eq 0 ] && [ -n "$(git ls-remote --heads origin topic)" ] && [[ "${out}" == *"has moved since the PR (left alone)"* ]]; echo $?)"
scene unmerged no "${PASS}"
land 7 >/dev/null
check "merge されなかった PR の branch は消さない" "$([ -n "$(git ls-remote --heads origin topic)" ]; echo $?)"

# --- 使い方の誤り ---
scene usage yes "${PASS}"
for args in "" "--squash" "seven" "7 --rebase" "7 --tag"; do
    # shellcheck disable=SC2086
    land ${args} >/dev/null; code=$?
    check "使い方の誤りは何もせずに返す: '${args}' (exit ${code})" "$([ "${code}" -eq 2 ] && [ "$(merged)" = 0 ]; echo $?)"
done

if [ "${fails}" -eq 0 ]; then
    echo "PASS: ${cases} cases"
else
    echo "FAIL: ${fails}/${cases}"
    exit 1
fi
