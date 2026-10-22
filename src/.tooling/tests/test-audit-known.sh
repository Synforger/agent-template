#!/bin/bash
# .tooling/startup/audit-known.sh (= 判定は audit_findings.py) の test。 作り物の監査の記録と番人の身代わりで、
# 新しい漏れがその repo の境界を読めるタブにだけ出る事、 番人に訊けない時は全部が出る事、 終わりの行の無い記録を
# clean と読まない事、 境界の無い記録を判定しない事、 clean / STALE / NO RUN を確かめる。
#
#   bash .tooling/tests/test-audit-known.sh
set -uo pipefail

KNOWN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/startup/audit-known.sh"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

AUDIT_DIR="${T}/audit"
export AUDIT_LOG_DIR="${AUDIT_DIR}"
mkdir -p "${AUDIT_DIR}"

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

ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n  got: %s\n' "$1" "${2//$'\n'/ | }"; }

# status <reach> : 起動の行。 reach が "none" なら番人が居ない
status() {
    if [ "$1" = none ]; then AREA_GUARD_HOOK="${T}/no-guard.py" bash "${KNOWN}" status
    else AREA_GUARD_HOOK="${HOOK}" FAKE_REACH="$1" bash "${KNOWN}" status; fi
}
# <説明> <reach> <期待する行の正規表現> / expect_not は出てはいけない行
expect() { local out; out="$(status "$2")"; if grep -qE -- "$3" <<< "${out}"; then ok; else bad "$1 (want: $3)" "${out}"; fi; }
expect_not() { local out; out="$(status "$2")"; if grep -qE -- "$3" <<< "${out}"; then bad "$1 (must not match: $3)" "${out}"; else ok; fi; }
expect_rc() { if [ "$2" -eq "$3" ]; then ok; else bad "$1 (want rc $3)" "rc=$2"; fi; }

# --- 作り物の記録を組む (= 本物の記録と同じ区切り) ---
clean_block() { # <repo> <境界>
    printf '\n--- %s (full, area %s) ---\n\n=== source 1/11: tracked files (= anon-scan.sh) ===\nok:   tracked files: clean\n--- %s: clean ---\n' "$1" "$2" "$1"
}
area_block() { # <repo> <境界> <fail 行>...
    local repo="$1" area="$2"; shift 2
    printf '\n--- %s (full, known findings accepted, area %s) ---\n' "${repo}" "${area}"
    printf '%s\n' "$@"
    printf 'fail: deep audit: 1 leak(s) in total\n--- %s: FINDINGS ---\n' "${repo}"
}
# mklog <日付> <done の数> <塊を書く関数を呼ぶ command...> : weekly-audit-<日付>.log
mklog() {
    local day="$1" count="$2"; shift 2
    { printf '=== weekly anon audit: %s (00:00:01) ===\n' "${day}"; "$@"; printf '\n=== done: %s repo(s) with findings ===\n' "${count}"; } > "${AUDIT_DIR}/weekly-audit-${day}.log"
}
# age_log <日付> <何日前> : 記録の更新時刻を決める (= 呼ぶ順に 1 分ずつ新しくし、 同じ日でも新旧が決まる)
seq=0
# stamp <何日前> <何分後> : touch -t の時刻 (= BSD の date の -v、 無ければ GNU の date の -d)
stamp() { date -v-"$1"d -v+"$2"M +%Y%m%d%H%M 2>/dev/null || date -d "$1 days ago $2 minutes" +%Y%m%d%H%M; }
age_log() { seq=$((seq + 1)); touch -t "$(stamp "$2" "${seq}")" "${AUDIT_DIR}/weekly-audit-$1.log"; }

body_areas() {
    clean_block /work/area-a/repo-clean client-x
    area_block /work/area-a/repo-x client-x 'fail: commit messages: 1 hit(s) = wordone'
    area_block /work/area-b/repo-y client-y 'fail: GitHub PR/Issue text: 2 hit(s) = wordtwo' 'fail: GitHub runs: UNREACHABLE (= counted as a finding, never clean)'
    area_block /work/own/repo-public - 'fail: git history blob: 1 hit(s) = wordthree'
}

# 1. 新しい漏れは、 その repo の境界を読めるタブにだけ出る
mklog 2026-03-08 3 body_areas
age_log 2026-03-08 1
expect 'a tab that reads no area gets the repos outside every area' '' '^weekly_audit: NEW in 1 repo\(s\).*2 other repo\(s\) with findings in areas this tab does not read'
expect 'the repo outside every area is named' '' 'new: /work/own/repo-public -> git history blob: wordthree$'
expect_not 'a tab that reads no area is not told an area repo' '' 'repo-x|repo-y'
expect 'a tab of one area gets its repo' client-x 'new: /work/area-a/repo-x -> commit messages: wordone$'
expect_not 'a tab of one area is not told the other areas' client-x 'repo-y|repo-public'
expect 'a tab that reads two areas gets both' 'client-x client-y' '^weekly_audit: NEW in 2 repo\(s\)'
expect 'every place of a repo is named' client-y 'new: /work/area-b/repo-y -> GitHub PR/Issue text: wordtwo; GitHub runs: \*$'
expect 'a tab whose areas have nothing is told it is for other tabs' client-z '^weekly_audit: nothing for this tab \(3 repo\(s\)'
expect_not 'a clean repo is never named' '' 'repo-clean'

# 2. 番人に訊けない時は全部を出す
expect 'with no guard every repo is shown' none '^weekly_audit: NEW in 3 repo\(s\).*areas unknown'
out="$(AREA_GUARD_HOOK="${HOOK}" FAKE_REACH_RC=2 bash "${KNOWN}" status)"
grep -qE '^weekly_audit: NEW in 3 repo\(s\).*areas unknown' <<< "${out}" && ok || bad 'a guard without reach shows every repo' "${out}"

# 3. 読み解けない記録は黙らせない
body_unparsed() { printf '\n--- /work/area-a/repo-x (full, area client-x) ---\nsomething the reader has never seen\n--- /work/area-a/repo-x: FINDINGS ---\n'; }
mklog 2026-03-15 1 body_unparsed
age_log 2026-03-15 1
expect 'a findings block without a readable line is named as unknown' client-x 'new: /work/area-a/repo-x -> \?: \*$'
body_miscount() { area_block /work/area-a/repo-x client-x 'fail: commit messages: 1 hit(s) = wordone'; }
mklog 2026-03-22 2 body_miscount
age_log 2026-03-22 1
expect 'a repo count that does not match is shown as not parsed' client-z '^weekly_audit: NEW in 2 repo\(s\).*log not parsed'

# 4. 終わりの行の無い記録 (= 走っている最中・途中で止まった) は clean と読まず、 一つ前の終わった記録で判定する
rm -f "${AUDIT_DIR}"/weekly-audit-*.log
mklog 2026-04-05 3 body_areas
age_log 2026-04-05 3
{ printf '=== weekly anon audit: 2026-04-08 (00:00:01) ===\n'; clean_block /work/area-a/repo-clean client-x; } > "${AUDIT_DIR}/weekly-audit-2026-04-08.log"
age_log 2026-04-08 0
expect 'a log without its end line is named' '' '^weekly_audit: INCOMPLETE \(weekly-audit-2026-04-08.log has no end line'
expect_not 'a log without its end line is not read as clean' '' 'clean'
expect 'the last finished log still decides' client-x '^weekly_audit: NEW in 1 repo\(s\) \(weekly-audit-2026-04-05.log'
rm -f "${AUDIT_DIR}/weekly-audit-2026-04-05.log"
expect 'with no finished log it is NO RUN' '' '^weekly_audit: NO RUN \(no finished log'

# 5. 見出しに境界の無い記録 (= 古い番人が書いた) は判定せず、 番人の配備を言う
body_old() { printf '\n--- /work/area-a/repo-x (full) ---\nfail: commit messages: 1 hit(s) = wordone\n--- /work/area-a/repo-x: FINDINGS ---\n'; }
rm -f "${AUDIT_DIR}"/weekly-audit-*.log
mklog 2026-04-12 1 body_old
age_log 2026-04-12 1
expect 'a log without areas is not judged' client-x '^weekly_audit: OLD LOG \(weekly-audit-2026-04-12.log.*guard-update.sh'
expect_not 'a log without areas names no finding' '' 'new:|repo-x'

# 6. clean / STALE / NO RUN
body_clean() { clean_block /work/area-a/repo-clean client-x; }
rm -f "${AUDIT_DIR}"/weekly-audit-*.log
mklog 2026-05-03 0 body_clean
age_log 2026-05-03 1
expect 'clean' '' '^weekly_audit: clean \(weekly-audit-2026-05-03.log, [0-9]+d ago\)'
expect 'clean reaches an area tab too' client-x '^weekly_audit: clean'
age_log 2026-05-03 10
expect 'older than 7 days is STALE' client-x '^weekly_audit: STALE \(last run [0-9]+d ago'
rm -f "${AUDIT_DIR}"/weekly-audit-*.log
expect 'no log is NO RUN' '' '^weekly_audit: NO RUN \(no log'

# 7. 使い方の誤りは 2 で止まる (= 台帳の口は退役した)
bash "${KNOWN}" adopt "${T}/x.log" > /dev/null 2>&1; expect_rc 'the retired adopt is an unknown command' $? 2
bash "${KNOWN}" > /dev/null 2>&1; expect_rc 'no command fails' $? 2

# 8. 起動の検査はこの script の status を呼ぶ
START="$(cd "$(dirname "${KNOWN}")" && pwd)/startup-status.sh"
if grep -q 'audit-known.sh status' "${START}"; then ok; else bad 'startup-status.sh calls audit-known.sh status' "$(grep -n 'weekly_audit' "${START}" | head -3)"; fi

printf 'audit-known: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
