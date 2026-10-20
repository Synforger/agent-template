#!/bin/bash
# .tooling/session-end/extract-artifact-index.sh の test。 作り物のエージェントの repo で、 索引の file の番号を確かめる
# (= 渡した番号で書く / 渡さなければその日の journal の次の番号 / 誤った番号は書かずに止まる)。
#
#   bash .tooling/tests/test-artifact-index-number.sh
set -uo pipefail

TOOLING="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

check() { # <説明> <コマンド...>
    local what="$1"
    shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}

# 作り物のエージェントの repo (= script と、 書く前に訊く口だけを写す。 番人の無い機械として通る)
AGENT="${T}/agent"
mkdir -p "${AGENT}/.tooling/session-end" "${AGENT}/.tooling/lib" "${T}/home"
cp "${TOOLING}/session-end/extract-artifact-index.sh" "${AGENT}/.tooling/session-end/"
cp "${TOOLING}/lib/guard-may-write.py" "${AGENT}/.tooling/lib/"
git -C "${AGENT}" init -q
today="$(date '+%Y-%m-%d')"
DAY="${AGENT}/journal/${today}"
mkdir -p "${DAY}"
: > "${DAY}/session-01.md"
: > "${DAY}/session-02.md"   # 例えば別の機械の session が書いて、 後から取り込まれた journal

run() { # <引数...> (= 番人の無い HOME で、 その session の記録も無い形で走らせる)
    (cd "${AGENT}" && HOME="${T}/home" CLAUDE_CODE_SESSION_ID="" \
        AREA_GUARD_HOOK="${T}/home/no-guard.py" bash .tooling/session-end/extract-artifact-index.sh "$@")
}

run journal >/dev/null 2>&1
check "without a number, the next one after the day's journals" [ -f "${DAY}/session-03-auto-index.jsonl" ]

run journal --nn 02 >/dev/null 2>&1
check "the number given is the one written" [ -f "${DAY}/session-02-auto-index.jsonl" ]

run journal --nn 4 >/dev/null 2>&1
check "a one-digit number is written with two" [ -f "${DAY}/session-04-auto-index.jsonl" ]

for bad in 0 100 x ""; do
    out="$(run journal --nn "${bad}" 2>&1)"
    code=$?
    check "--nn '${bad}' stops with a usage error" [ "${code}" -eq 2 ]
    check "--nn '${bad}' says what --nn takes" grep -q -- "--nn takes" <<<"${out}"
done
out="$(run journal --number 3 2>&1)"
check "an unknown argument stops" [ $? -eq 2 ]

check "nothing else was written" [ "$(ls "${DAY}" | grep -c auto-index)" -eq 3 ]

echo "test-artifact-index-number: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
