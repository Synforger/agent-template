#!/bin/bash
# test-peer-health.sh - peer_health.py が、 client の見張りの記録と置かれた連絡から、 機械ごとに
# ok / DOWN / WAITING / UNKNOWN の行を出し、 記録の無い機械では黙ることを、 作り物の記録と固定の時刻で確かめる。
#   bash .tooling/tests/test-peer-health.sh
set -u
TOOL="$(cd "$(dirname "$0")/.." && pwd)/startup/peer_health.py"
W="$(mktemp -d)"
trap 'rm -rf "${W}"' EXIT
export PEER_HEALTH_FILE="${W}/peer_health.json"
export PEER_OUTBOX_DIR="${W}/peer_outbox"
export PEER_HEALTH_NOW="2026-11-16T12:00:00+00:00"
pass=0
fail=0

expect() { # <説明> <期待の正規表現>
    local out; out="$(python3 "${TOOL}")"
    if grep -qE -- "$2" <<< "${out}"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (want: $2 / got: ${out})"; fi
}
record() { # <名前> <ok> <since> <checked_at> <tailnet の online>
    printf '{"%s": {"ok": %s, "since": "%s", "checked_at": "%s", "last_error": null, "tailnet": {"online": %s, "last_seen": null}}}\n' \
        "$1" "$2" "$3" "$4" "$5" > "${PEER_HEALTH_FILE}"
}
keep() { mkdir -p "${PEER_OUTBOX_DIR}"; printf '{"id": "%s", "peer": "%s", "kept_at": 0}\n' "$1" "$2" > "${PEER_OUTBOX_DIR}/$1.json"; }

out="$(python3 "${TOOL}")"
if [ -z "${out}" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: no record prints nothing (got: ${out})"; fi

record home true "2026-11-16T08:00:00+00:00" "2026-11-16T11:58:00+00:00" null
expect 'an answering machine is ok' '^peer\(home\): ok$'

record home false "2026-11-16T11:50:00+00:00" "2026-11-16T11:58:00+00:00" false
expect 'a short silence with nothing waiting stays ok' '^peer\(home\): ok$'

keep m1 home
expect 'a short silence with a message waiting is WAITING' '^peer\(home\): WAITING 1 message\(s\) \(not answering for 10m; off the tailnet'

record home false "2026-11-16T09:30:00+00:00" "2026-11-16T11:58:00+00:00" true
keep m2 home
expect '30 minutes or more is DOWN with how long and how many wait' '^peer\(home\): DOWN 2h 30m \(since .*; on the tailnet but not answering; 2 message\(s\) waiting\)$'

record home false "2026-11-16T09:30:00+00:00" "2026-11-16T11:00:00+00:00" true
expect 'an old record means the patrol may be stopped' '^peer\(home\): UNKNOWN \(last checked 1h 0m ago'

rm -rf "${PEER_OUTBOX_DIR}"
printf 'not json' > "${PEER_HEALTH_FILE}"
out="$(python3 "${TOOL}")"
if [ -z "${out}" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: an unreadable record prints nothing (got: ${out})"; fi

echo "test-peer-health: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
