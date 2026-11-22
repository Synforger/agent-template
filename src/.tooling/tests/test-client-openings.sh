#!/bin/bash
# .tooling/lib/client_openings.py の試験。 作り物の番人の口 (= order.py --openings) と orders.txt で、 client が打つ
# 発話の 1 行目の表をどこから読むかと、 別の機械・この機械への分け方を確かめる。
#
#   bash .tooling/tests/test-client-openings.sh
set -u
LIB="$(cd "$(dirname "$0")/.." && pwd)/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export GUARD_CONFIG_DIR="${WORK}"
pass=0
fail=0

check() { # <説明> <期待> <実際>
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: expected [$2] got [$3]"; fi
}
lines() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from client_openings import opening_lines; print("|".join(opening_lines()))' "${LIB}"; }
split() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from client_openings import opening_lines, split_openings; far, near = split_openings(opening_lines()); print("|".join(far) + " / " + "|".join(near))' "${LIB}"; }

printf '%s\n' '送信して' '>Message from another session' '>>Message from a session on another machine' > "${WORK}/orders.txt"

printf 'print(">From the guard")\nprint(">>Far from the guard")\n' > "${WORK}/order.py"
export GUARD_ORDER_PY="${WORK}/order.py"
check "番人の口が答える時は、 その答えを読む" ">From the guard|>>Far from the guard" "$(lines)"
check ">> は別の機械、 > はこの機械" "Far from the guard / From the guard" "$(split)"

printf 'pass\n' > "${WORK}/order.py"
check "古い番人 (= 口が何も出さない) なら orders.txt の > の行を読む" \
    ">Message from another session|>>Message from a session on another machine" "$(lines)"

export GUARD_ORDER_PY="${WORK}/no-order.py"
rm "${WORK}/orders.txt"
check "番人の口も orders.txt も無ければ空" "" "$(lines)"

echo "test-client-openings: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
