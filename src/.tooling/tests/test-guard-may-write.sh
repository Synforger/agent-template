#!/bin/bash
# test-guard-may-write.sh - 引数や走査で決まる階層へ書く script が、 書く前に入口の番人へ訊いて止まる。
# 作り物の HOME に、 親 (= 番人の対象外) / 勤め先の階層 / その中の案件の階層を置き、 案件を読んだ印の付いた
# session で、 訊く口 (= lib/guard-may-write.py) と、 それを呼ぶ 2 本 (= extract-artifact-index.sh /
# build-rule-registry.py) を本物の番人に対して通す。 FAIL 1 行ずつ。
set -u
TOOLING="$(cd "$(dirname "$0")/.." && pwd)"
REAL_HOOK="${HOME}/.git-hooks/agent-hooks/claude-code/area-guard.py"   # 本物の番人 (= 在る機械でだけ通す)
WORK="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "${WORK}"' EXIT
fails=0
cases=0
check() {   # check <名前> <条件の終了コード>
    cases=$((cases + 1))
    [ "$2" -eq 0 ] || { echo "FAIL $1"; fails=$((fails + 1)); }
}

if [ ! -f "${REAL_HOOK}" ] || ! python3 "${REAL_HOOK}" may-write </dev/null 2>&1 | grep -q "usage:"; then
    echo "skip: no entry guard that answers may-write on this machine (${REAL_HOOK})"
    exit 0
fi

export HOME="${WORK}/home"
export GUARD_CONFIG_DIR="${HOME}/.config/guard"
export GUARD_CORPUS_CACHE="${HOME}/.cache/guard-corpus"
export AREA_GUARD_STATE="${HOME}/state"
export AREA_GUARD_HOOK="${REAL_HOOK}"
unset GIT_CONFIG_GLOBAL
AGENT="${HOME}/agent"
COMPANY="${AGENT}/projects/work"
CLIENT="${COMPANY}/subprojects/acme"
mkdir -p "${GUARD_CONFIG_DIR}" "${AREA_GUARD_STATE}" "${AGENT}/.tooling/lib" "${AGENT}/.tooling/session-end" "${AGENT}/.tooling/rules" "${AGENT}/rules" "${AGENT}/journal" \
         "${COMPANY}/rules" "${COMPANY}/journal" "${CLIENT}/rules" "${CLIENT}/journal"
cat > "${GUARD_CONFIG_DIR}/areas.txt" <<'AREAS'
_exempt ~/agent
company ~/agent/projects/work
client  ~/agent/projects/work/subprojects/acme
AREAS
cp "${TOOLING}/session-end/extract-artifact-index.sh" "${AGENT}/.tooling/session-end/"
cp "${TOOLING}/rules/build-rule-registry.py" "${AGENT}/.tooling/rules/"
cp "${TOOLING}/lib/guard-may-write.py" "${AGENT}/.tooling/lib/"
for repo in "${AGENT}" "${COMPANY}" "${CLIENT}"; do
    git init -q "${repo}"
    git -C "${repo}" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
done
printf '# rules\n\n## one\n\nbody\n' > "${AGENT}/rules/always.md"
printf '# rules\n\n## work one\n\nbody\n' > "${COMPANY}/rules/always.md"
printf '# rules\n\n## acme one\n\nbody\n' > "${CLIENT}/rules/always.md"
# 案件を読んだ session と、 何も読んでいない session
printf '{"areas": ["client"], "tabs": {}}' > "${AREA_GUARD_STATE}/marked.json"
ASK="${AGENT}/.tooling/lib/guard-may-write.py"
today="$(date +%Y-%m-%d)"
cd "${AGENT}" || exit 2

# --- 訊く口 ---
export CLAUDE_CODE_SESSION_ID=marked
python3 "${ASK}" "${CLIENT}/journal/x.jsonl" 2>/dev/null
check "案件を読んだ session は、 案件の階層へ書ける" "$?"
python3 "${ASK}" "${AGENT}/journal/x.jsonl" 2>/dev/null
check "案件を読んだ session は、 親 (= 番人の対象外) へ書ける" "$?"
err="$(python3 "${ASK}" "${COMPANY}/journal/x.jsonl" 2>&1 >/dev/null)"; code=$?
check "案件を読んだ session は、 勤め先の階層へ書けない (exit ${code})" "$([ "${code}" -eq 1 ]; echo $?)"
check "拒んだ理由は番人の 1 行: ${err}" "$([[ "${err}" == area-guard:*"cannot write ${COMPANY}/journal/x.jsonl"* ]]; echo $?)"
err="$(python3 "${ASK}" "${CLIENT}/journal/x.jsonl" "${COMPANY}/journal/x.jsonl" 2>&1 >/dev/null)"; code=$?
check "1 つでも書けない path が在れば拒む" "$([ "${code}" -eq 1 ] && [ "$(printf '%s\n' "${err}" | wc -l | tr -d ' ')" = 1 ]; echo $?)"
(cd "${COMPANY}" && python3 "${ASK}" journal/x.jsonl 2>/dev/null); code=$?
check "相対 path は、 呼んだ script の居る場所で解決される" "$([ "${code}" -eq 1 ]; echo $?)"
CLAUDE_CODE_SESSION_ID=unmarked python3 "${ASK}" "${COMPANY}/journal/x.jsonl" 2>/dev/null
check "何も読んでいない session は、 勤め先の階層へ書ける" "$?"
env -u CLAUDE_CODE_SESSION_ID python3 "${ASK}" "${COMPANY}/journal/x.jsonl" 2>/dev/null
check "session の外 (= 人が流した時) は訊かずに通す" "$?"
AREA_GUARD_HOOK="${WORK}/no-guard.py" python3 "${ASK}" "${COMPANY}/journal/x.jsonl" 2>/dev/null
check "番人が入っていない機械では通す" "$?"
printf 'import json, sys\njson.load(sys.stdin)\n' > "${WORK}/old-guard.py"
err="$(AREA_GUARD_HOOK="${WORK}/old-guard.py" python3 "${ASK}" "${COMPANY}/journal/x.jsonl" 2>&1 >/dev/null)"; code=$?
check "訊く口の無い古い番人では通し、 そう名乗る: ${err}" "$([ "${code}" -eq 0 ] && [[ "${err}" == *"could not answer"* ]]; echo $?)"
python3 "${ASK}" >/dev/null 2>&1
check "path を渡さない呼び出しは使い方の誤り" "$([ $? -eq 2 ]; echo $?)"
check "訊いても印は増えない" "$([ "$(cat "${AREA_GUARD_STATE}/marked.json")" = '{"areas": ["client"], "tabs": {}}' ] && [ ! -e "${AREA_GUARD_STATE}/unmarked.json" ]; echo $?)"

# --- 締めの script (= 書き先は引数) ---
out="$(bash .tooling/session-end/extract-artifact-index.sh projects/work/journal 2>&1)"; code=$?
check "締めの script は、 書けない階層を渡されたら止まる (exit ${code})" "$([ "${code}" -eq 1 ]; echo $?)"
check "止まる時は番人の 1 行と、 どうすればよいかを出す: ${out}" "$([[ "${out}" == *"area-guard:"*"may not write under projects/work/journal"* ]]; echo $?)"
check "止まった時は folder も作らない" "$([ ! -e "${COMPANY}/journal/${today}" ]; echo $?)"
out="$(cd "${WORK}" && bash "${AGENT}/.tooling/session-end/extract-artifact-index.sh" projects/work/journal 2>&1)"; code=$?
check "別の場所から呼んでも同じ階層として止まる (exit ${code})" "$([ "${code}" -eq 1 ] && [ ! -e "${COMPANY}/journal/${today}" ]; echo $?)"
bash .tooling/session-end/extract-artifact-index.sh "${COMPANY}/journal" >/dev/null 2>&1
check "絶対 path で渡しても止まる" "$([ $? -eq 1 ] && [ ! -e "${COMPANY}/journal/${today}" ]; echo $?)"
bash .tooling/session-end/extract-artifact-index.sh projects/work/subprojects/acme/journal >/dev/null 2>&1
check "書ける階層 (= 案件) へは書く" "$([ $? -eq 0 ] && [ -f "${CLIENT}/journal/${today}/session-01-auto-index.jsonl" ]; echo $?)"
bash .tooling/session-end/extract-artifact-index.sh journal >/dev/null 2>&1
check "親へは書く" "$([ $? -eq 0 ] && [ -f "${AGENT}/journal/${today}/session-01-auto-index.jsonl" ]; echo $?)"
CLAUDE_CODE_SESSION_ID=unmarked bash .tooling/session-end/extract-artifact-index.sh projects/work/journal >/dev/null 2>&1
check "何も読んでいない session は、 勤め先の階層へ書く" "$([ $? -eq 0 ] && [ -f "${COMPANY}/journal/${today}/session-01-auto-index.jsonl" ]; echo $?)"

# --- 台帳の script (= 書き先は全階層の走査) ---
out="$(python3 .tooling/rules/build-rule-registry.py 2>&1)"; code=$?
check "台帳は、 書けない階層が在れば失敗で返す (exit ${code})" "$([ "${code}" -eq 1 ]; echo $?)"
check "書けなかった階層を名指す: ${out}" "$([[ "${out}" == *"not written"*"projects/work/rules/registry.jsonl"* ]]; echo $?)"
check "書けない階層の台帳は作らない" "$([ ! -e "${COMPANY}/rules/registry.jsonl" ]; echo $?)"
check "書ける階層 (= 親と案件) の台帳は作る" "$([ -s "${AGENT}/rules/registry.jsonl" ] && [ -s "${CLIENT}/rules/registry.jsonl" ]; echo $?)"
CLAUDE_CODE_SESSION_ID=unmarked python3 .tooling/rules/build-rule-registry.py >/dev/null 2>&1
check "何も読んでいない session は、 全階層の台帳を作る" "$([ $? -eq 0 ] && [ -s "${COMPANY}/rules/registry.jsonl" ]; echo $?)"
before="$(stat -f '%m %i' "${COMPANY}/rules/registry.jsonl" 2>/dev/null || stat -c '%Y %i' "${COMPANY}/rules/registry.jsonl")"
sleep 1
python3 .tooling/rules/build-rule-registry.py >/dev/null 2>&1; code=$?
after="$(stat -f '%m %i' "${COMPANY}/rules/registry.jsonl" 2>/dev/null || stat -c '%Y %i' "${COMPANY}/rules/registry.jsonl")"
check "中身が変わらない台帳は、 書けない階層でも失敗にしない (exit ${code})" "$([ "${code}" -eq 0 ]; echo $?)"
check "中身が変わらない台帳は書き直さない" "$([ "${before}" = "${after}" ]; echo $?)"
printf '\n## work two\n\nbody\n' >> "${COMPANY}/rules/always.md"
kept="$(cat "${COMPANY}/rules/registry.jsonl")"
python3 .tooling/rules/build-rule-registry.py >/dev/null 2>&1; code=$?
check "中身が変わる台帳は、 書けない階層なら書かずに失敗で返す (exit ${code})" "$([ "${code}" -eq 1 ] && [ "$(cat "${COMPANY}/rules/registry.jsonl")" = "${kept}" ]; echo $?)"

if [ "${fails}" -eq 0 ]; then
    echo "PASS: ${cases} cases"
else
    echo "FAIL: ${fails}/${cases}"
    exit 1
fi
