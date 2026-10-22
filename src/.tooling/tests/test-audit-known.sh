#!/bin/bash
# .tooling/startup/audit-known.sh の test。 作り物の監査 log と台帳 (= 作り物の folder の中) で、
# 台帳に無い組は全部のタブへ NEW として出る事、 既知だけなら normal のタブにだけ 1 行出て案件の階層は黙る事、
# 同じ repo に新しい語が入れば NEW、 同じ語の件数が台帳より増えれば NEW、 forget した組が次の監査で出れば NEW、 を確かめる。
#
#   bash .tooling/tests/test-audit-known.sh
set -uo pipefail

KNOWN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/startup/audit-known.sh"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

AUDIT_DIR="${T}/audit"
export AUDIT_LOG_DIR="${AUDIT_DIR}" AUDIT_KNOWN_FILE="${T}/ledger/known-findings.tsv"
mkdir -p "${AUDIT_DIR}"

# 出力 (= status) を tier 別に取る。 tier "-" は AGENT_TIER を立てない
status() {
    if [ "$1" = "-" ]; then env -u AGENT_TIER bash "${KNOWN}" status
    else AGENT_TIER="$1" bash "${KNOWN}" status; fi
}

ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n  got: %s\n' "$1" "${2//$'\n'/ | }"; }

# <説明> <tier> <期待する行の正規表現> : 出力のどこかの行が一致すれば緑
expect() {
    local what="$1" tier="$2" pattern="$3" out
    out="$(status "${tier}")"
    if grep -qE -- "${pattern}" <<< "${out}"; then ok; else bad "${what} (want: ${pattern})" "${out}"; fi
}
# <説明> <tier> <出てはいけない正規表現>
expect_not() {
    local what="$1" tier="$2" pattern="$3" out
    out="$(status "${tier}")"
    if grep -qE -- "${pattern}" <<< "${out}"; then bad "${what} (must not match: ${pattern})" "${out}"; else ok; fi
}
# <説明> <tier> : 出力が 1 行も無ければ緑
expect_silent() {
    local what="$1" tier="$2" out
    out="$(status "${tier}")"
    if [ -z "${out}" ]; then ok; else bad "${what} (want no output)" "${out}"; fi
}
# <説明> <コマンドの終了コード> <期待>
expect_rc() { if [ "$2" -eq "$3" ]; then ok; else bad "$1 (want rc $3)" "rc=$2"; fi; }

# --- 作り物の log を組む ---
# repo ごとの塊 (= 本物の log と同じ区切り)。 clean_block <repo> / finding_block <repo> <fail 行>...
clean_block() { printf '\n--- %s (2026-01-01T00:00:00Z) ---\n\n=== source 1/11: tracked files (= anon-scan.sh) ===\nok:   tracked files: clean\n--- %s: clean ---\n' "$1" "$1"; }
finding_block() {
    local repo="$1"; shift
    printf '\n--- %s (full) ---\n\n=== source 2/11: git history blob (all diffs of all commits) ===\n' "${repo}"
    printf '%s\n' "$@"
    printf 'fail: deep audit: 9 leak(s) in total\n--- %s: FINDINGS ---\n' "${repo}"
}
# mklog <日付> <done の数> <塊を書く関数を呼ぶ command...> : weekly-audit-<日付>.log
mklog() {
    local day="$1" count="$2"; shift 2
    { printf '=== weekly anon audit: %s (00:00:01) ===\n' "${day}"; "$@"; printf '\n=== done: %s repo(s) with findings ===\n' "${count}"; } > "${AUDIT_DIR}/weekly-audit-${day}.log"
}
# age_log <日付> <何日前> : log の更新時刻を決める (= 呼ぶ順に 1 分ずつ新しくし、 同じ日でも新旧が決まる)
seq=0
age_log() { seq=$((seq + 1)); touch -t "$(date -v-"$2"d -v+"${seq}"M +%Y%m%d%H%M)" "${AUDIT_DIR}/weekly-audit-$1.log"; }

R1=/work/area-a/repo-one
R2=/work/area-b/repo-two
R3=/work/area-b/repo-three

body_two() {
    clean_block /work/area-a/repo-clean
    finding_block "${R1}" 'fail: tracked files: leak found (run bash anon-scan.sh for details)' 'fail: git history blob: 3 hit(s) = wordone wordtwo' 'fail: commit messages: 1 hit(s) = wordone'
    finding_block "${R2}" 'fail: GitHub PR/Issue text: 2 hit(s) = ~/placeone wordtwo' 'fail: GitHub runs: UNREACHABLE (= counted as a finding, never clean)'
}
mklog 2026-01-04 2 body_two
age_log 2026-01-04 3

# 1. 台帳が無い間は全部が新規。 どの階層にも出て、 repo と見つかった物が読める
expect 'no ledger: NEW is announced' normal '^weekly_audit: NEW in 2 repo\(s\)'
expect 'no ledger: the repo and what was found are named' normal 'new: /work/area-a/repo-one -> .*git history blob: wordone wordtwo'
expect 'no ledger: a place without words is named as a whole' normal 'tracked files: \*'
expect 'no ledger: a project tab hears it too' projects/some-project '^weekly_audit: NEW in 2 repo\(s\)'
expect 'no ledger: a subproject tab hears it too' projects/some-project/subprojects/part '^weekly_audit: NEW in 2 repo\(s\)'
expect_not 'a clean repo is never named' normal 'repo-clean'

# 2. adopt の後は既知だけ。 normal にだけ 1 行、 案件の階層は黙る
out="$(bash "${KNOWN}" adopt "${AUDIT_DIR}/weekly-audit-2026-01-04.log")"; expect_rc 'adopt succeeds' $? 0
expect 'known only: normal gets one line' normal '^weekly_audit: known only \(2 repo\(s\)'
expect 'known only: an unset AGENT_TIER is read as normal' - '^weekly_audit: known only'
expect_not 'known only: the line does not say NEW' normal 'NEW'
expect_silent 'known only: a project tab hears nothing' projects/some-project
expect_silent 'known only: a subproject tab hears nothing' projects/some-project/subprojects/part
[ "$(wc -l < <(status normal))" -eq 1 ] && ok || bad 'known only is exactly one line' "$(status normal)"
[ -f "${AUDIT_KNOWN_FILE}" ] && ok || bad 'the ledger lives where AUDIT_KNOWN_FILE says' "$(ls -R "${T}")"

# 3. 同じ語の件数が台帳より増えたら新規 (= 履歴に書き足された)。 増えた場所だけを、 前と今の件数つきで読み上げる
body_more() {
    finding_block "${R1}" 'fail: tracked files: leak found (run bash anon-scan.sh for details)' 'fail: git history blob: 7 hit(s) = wordone wordtwo' 'fail: commit messages: 4 hit(s) = wordone'
    finding_block "${R2}" 'fail: GitHub PR/Issue text: 5 hit(s) = ~/placeone wordtwo' 'fail: GitHub runs: UNREACHABLE (= counted as a finding, never clean)'
}
mklog 2026-01-11 2 body_more
age_log 2026-01-11 2
expect 'more hits of known words are NEW' normal '^weekly_audit: NEW in 2 repo\(s\)'
expect 'the grown place is named with both counts' normal 'new: /work/area-a/repo-one -> commit messages: wordone \(hits 1 -> 4\); git history blob: wordone wordtwo \(hits 3 -> 7\)$'
expect 'a grown place of another repo is named too' normal 'new: /work/area-b/repo-two -> GitHub PR/Issue text: wordtwo ~/placeone \(hits 2 -> 5\)$'
expect_not 'a place without counts is not read out again' normal 'tracked files|GitHub runs'
expect 'a project tab hears grown counts' projects/some-project '^weekly_audit: NEW in 2 repo'
# 件数が減った・同じなら既知のまま (= 比べる相手は台帳の件数)
mklog 2026-01-11 2 body_two
age_log 2026-01-11 2
expect 'the same counts stay known' normal '^weekly_audit: known only'
cp "${AUDIT_KNOWN_FILE}" "${T}/ledger.counted"
# 件数の列が無い古い台帳の行は件数を比べず、 adopt し直すと件数が入る
cut -f1-3 "${T}/ledger.counted" > "${AUDIT_KNOWN_FILE}"
mklog 2026-01-11 2 body_more
age_log 2026-01-11 2
expect 'an old row without a count does not flag more hits' normal '^weekly_audit: known only'
bash "${KNOWN}" adopt "${AUDIT_DIR}/weekly-audit-2026-01-11.log" > /dev/null
[ "$(bash "${KNOWN}" list | awk -F'\t' 'NF != 4' | wc -l | tr -d ' ')" = 0 ] && ok || bad 'adopt again gives every row a count, no 3-column row is left' "$(bash "${KNOWN}" list)"
grep -qx $'/work/area-a/repo-one\tgit history blob\twordone\t7' "${AUDIT_KNOWN_FILE}" && ok || bad 'adopt keeps the newer count' "$(bash "${KNOWN}" list)"
expect 'after adopt the more hits are known' normal '^weekly_audit: known only'
cp "${T}/ledger.counted" "${AUDIT_KNOWN_FILE}"

# 4. 同じ repo の同じ場所に新しい語が入れば新規。 既知の語と他の repo は読み上げない
body_newword() {
    finding_block "${R1}" 'fail: tracked files: leak found (run bash anon-scan.sh for details)' 'fail: git history blob: 4 hit(s) = wordone wordtwo wordnew' 'fail: commit messages: 1 hit(s) = wordone'
    finding_block "${R2}" 'fail: GitHub PR/Issue text: 2 hit(s) = ~/placeone wordtwo' 'fail: GitHub runs: UNREACHABLE (= counted as a finding, never clean)'
}
mklog 2026-01-18 2 body_newword
age_log 2026-01-18 1
expect 'a new word in a known repo is NEW' normal '^weekly_audit: NEW in 1 repo\(s\).*1 other repo\(s\) with only known'
expect 'only the new word is named, with the count of its place' normal 'new: /work/area-a/repo-one -> git history blob: wordnew \(hits 3 -> 4\)$'
expect_not 'known words of that repo are not read out' normal 'wordtwo'
expect_not 'the other repo is not read out' normal 'repo-two'
expect 'a project tab hears the new word' projects/some-project '^weekly_audit: NEW in 1 repo'

# 5. 同じ語でも別の場所なら新規
body_newplace() {
    finding_block "${R1}" 'fail: tracked files: leak found (run bash anon-scan.sh for details)' 'fail: git history blob: 3 hit(s) = wordone wordtwo' 'fail: commit messages: 1 hit(s) = wordone' 'fail: tags: 1 hit(s) = wordone'
    finding_block "${R2}" 'fail: GitHub PR/Issue text: 2 hit(s) = ~/placeone wordtwo' 'fail: GitHub runs: UNREACHABLE (= counted as a finding, never clean)'
}
mklog 2026-01-25 2 body_newplace
age_log 2026-01-25 1
expect 'a known word in a new place is NEW' normal 'new: /work/area-a/repo-one -> tags: wordone'

# 6. 新しい repo は新規
body_newrepo() {
    body_two
    finding_block "${R3}" 'fail: author/committer: 1 hit(s) = wordone'
}
mklog 2026-02-01 3 body_newrepo
age_log 2026-02-01 1
expect 'a new repo is NEW' normal '^weekly_audit: NEW in 1 repo\(s\)'
expect 'the new repo is named' projects/some-project 'new: /work/area-b/repo-three -> author/committer: wordone'

# 7. forget: 消した組が次の監査でまた出たら新規。 絞り方は repo / 場所 / 語、 repo は末尾の名前でも通る
mklog 2026-02-08 2 body_two
age_log 2026-02-08 1
expect 'back to known after the extra repo is gone' normal '^weekly_audit: known only'
bash "${KNOWN}" forget repo-two 'GitHub runs' > /dev/null; expect_rc 'forget by trailing name and place' $? 0
expect 'a forgotten place that shows up again is NEW' normal 'new: /work/area-b/repo-two -> GitHub runs: \*'
expect_not 'the other place of that repo stays known' normal 'GitHub PR/Issue text'
bash "${KNOWN}" forget "${R1}" 'git history blob' wordtwo > /dev/null; expect_rc 'forget one word' $? 0
expect 'only the forgotten word is NEW' normal 'new: /work/area-a/repo-one -> git history blob: wordtwo$'
before="$(bash "${KNOWN}" list)"
bash "${KNOWN}" forget /work/nowhere > /dev/null 2>&1; expect_rc 'forget of something not held fails' $? 1
[ "$(bash "${KNOWN}" list)" = "${before}" ] && ok || bad 'a failed forget leaves the ledger as it was' "$(bash "${KNOWN}" list)"
bash "${KNOWN}" adopt "${AUDIT_DIR}/weekly-audit-2026-02-08.log" > /dev/null
expect 'adopt puts the forgotten findings back' normal '^weekly_audit: known only'

# 8. 読み解けない log は既知で黙らせない
body_unparsed() {
    printf '\n--- %s (full) ---\nsomething the reader has never seen\n--- %s: FINDINGS ---\n' "${R1}" "${R1}"
}
mklog 2026-02-15 1 body_unparsed
age_log 2026-02-15 1
expect 'a findings block without a readable line is NEW' projects/some-project 'new: /work/area-a/repo-one -> \?: \*'
body_miscount() { finding_block "${R1}" 'fail: commit messages: 1 hit(s) = wordone'; }
mklog 2026-02-22 3 body_miscount
age_log 2026-02-22 1
expect 'a repo count that does not match is NEW, not known' projects/some-project '^weekly_audit: NEW in 3 repo\(s\).*log not parsed'

# 9. 今までどおりの 3 つ: clean / STALE / NO RUN
body_clean() { clean_block /work/area-a/repo-clean; }
rm -f "${AUDIT_DIR}"/weekly-audit-*.log
mklog 2026-03-01 0 body_clean
age_log 2026-03-01 1
expect 'clean' normal '^weekly_audit: clean \(weekly-audit-2026-03-01.log'
expect 'clean reaches a project tab too' projects/some-project '^weekly_audit: clean'
age_log 2026-03-01 10
expect 'older than 7 days is STALE' projects/some-project '^weekly_audit: STALE \(last run [0-9]+d ago'
rm -f "${AUDIT_DIR}"/weekly-audit-*.log
expect 'no log is NO RUN' projects/some-project '^weekly_audit: NO RUN'

# 10. 使い方の誤りは 2 で止まり、 台帳を書かない
bash "${KNOWN}" adopt "${T}/no-such.log" > /dev/null 2>&1; expect_rc 'adopt of a missing log fails' $? 2
bash "${KNOWN}" bogus > /dev/null 2>&1; expect_rc 'an unknown command fails' $? 2

# 11. 起動の検査はこの script の status を呼ぶ (= 件数だけ読む旧い形に戻らない)
START="$(cd "$(dirname "${KNOWN}")" && pwd)/startup-status.sh"
if grep -q 'audit-known.sh status' "${START}" && ! grep -q 'FINDINGS in' "${START}"; then ok; else bad 'startup-status.sh calls audit-known.sh status' "$(grep -n 'weekly_audit' "${START}" | head -3)"; fi

# 12. 見出しに境界が書かれた log: 台帳と比べず、 その境界を読めるタブにだけ出す (= audit_findings.py)
# 番人の身代わり: `reach` に FAKE_REACH (= 空白区切り) の名前を 1 行ずつ返す。 FAKE_REACH_RC で失敗させる
HOOK="${T}/area-guard.py"
cat > "${HOOK}" <<'PY'
import os, sys
if sys.argv[1:] != ["reach"]:
    sys.exit(2)
for name in os.environ.get("FAKE_REACH", "").split():
    print(name)
sys.exit(int(os.environ.get("FAKE_REACH_RC", "0")))
PY
# <説明> <reach (= "none" は番人が居ない)> <期待する行の正規表現> / expect_area_not は出てはいけない行
area_out() {
    if [ "$1" = none ]; then AREA_GUARD_HOOK="${T}/no-guard.py" bash "${KNOWN}" status
    else AREA_GUARD_HOOK="${HOOK}" FAKE_REACH="$1" bash "${KNOWN}" status; fi
}
expect_area() { local out; out="$(area_out "$2")"; if grep -qE -- "$3" <<< "${out}"; then ok; else bad "$1 (want: $3)" "${out}"; fi; }
expect_area_not() { local out; out="$(area_out "$2")"; if grep -qE -- "$3" <<< "${out}"; then bad "$1 (must not match: $3)" "${out}"; else ok; fi; }
area_block() { # <repo> <境界> <fail 行>...
    local repo="$1" area="$2"; shift 2
    printf '\n--- %s (full, known findings accepted, area %s) ---\n' "${repo}" "${area}"
    printf '%s\n' "$@"
    printf 'fail: deep audit: 1 leak(s) in total\n--- %s: FINDINGS ---\n' "${repo}"
}
body_areas() {
    printf '\n--- /work/area-a/repo-clean (full, area client-x) ---\nok:   tracked files: clean\n--- /work/area-a/repo-clean: clean ---\n'
    area_block /work/area-a/repo-x client-x 'fail: commit messages: 1 hit(s) = wordone'
    area_block /work/area-b/repo-y client-y 'fail: GitHub PR/Issue text: 2 hit(s) = wordtwo' 'fail: GitHub runs: UNREACHABLE (= counted as a finding, never clean)'
    area_block /work/own/repo-public - 'fail: git history blob: 1 hit(s) = wordthree'
}
rm -f "${AUDIT_DIR}"/weekly-audit-*.log
mklog 2026-03-08 3 body_areas
age_log 2026-03-08 1
bash "${KNOWN}" adopt "${AUDIT_DIR}/weekly-audit-2026-03-08.log" > /dev/null
expect_area 'areas: a tab that reads no area gets the repos outside every area' '' '^weekly_audit: NEW in 1 repo\(s\).*2 other repo\(s\) with findings in areas this tab does not read'
expect_area 'areas: the repo outside every area is named' '' 'new: /work/own/repo-public -> git history blob: wordthree$'
expect_area_not 'areas: a tab that reads no area is not told an area repo' '' 'repo-x|repo-y'
expect_area 'areas: a tab of one area gets its repo' client-x 'new: /work/area-a/repo-x -> commit messages: wordone$'
expect_area_not 'areas: a tab of one area is not told the other areas' client-x 'repo-y|repo-public'
expect_area 'areas: a tab that reads two areas gets both' 'client-x client-y' '^weekly_audit: NEW in 2 repo\(s\)'
expect_area 'areas: every place of a repo is named' client-y 'new: /work/area-b/repo-y -> GitHub PR/Issue text: wordtwo; GitHub runs: \*$'
expect_area 'areas: a tab whose areas have nothing is told it is for other tabs' client-z '^weekly_audit: nothing for this tab \(3 repo\(s\)'
expect_area_not 'areas: the ledger is not read (an adopted finding is still NEW)' client-x 'known only'
expect_area 'areas: with no guard every repo is shown' none '^weekly_audit: NEW in 3 repo\(s\).*areas unknown'
out="$(AREA_GUARD_HOOK="${HOOK}" FAKE_REACH_RC=2 bash "${KNOWN}" status)"
grep -qE '^weekly_audit: NEW in 3 repo\(s\).*areas unknown' <<< "${out}" && ok || bad 'areas: a guard without reach shows every repo' "${out}"
expect_area_not 'areas: a clean repo is never named' '' 'repo-clean'
body_areas_miscount() { area_block /work/area-a/repo-x client-x 'fail: commit messages: 1 hit(s) = wordone'; }
mklog 2026-03-15 2 body_areas_miscount
age_log 2026-03-15 1
expect_area 'areas: a repo count that does not match is shown as not parsed' client-z '^weekly_audit: NEW in 2 repo\(s\).*log not parsed'
body_areas_clean() { printf '\n--- /work/area-a/repo-x (full, area client-x) ---\nok:   tracked files: clean\n--- /work/area-a/repo-x: clean ---\n'; }
mklog 2026-03-22 0 body_areas_clean
age_log 2026-03-22 1
expect_area 'areas: a clean log is clean' client-x '^weekly_audit: clean \(weekly-audit-2026-03-22.log'

printf 'audit-known: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
