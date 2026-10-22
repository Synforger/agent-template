#!/bin/bash
# test-guard-place.sh - エージェントの道具が読む番人の置き場が、 配備した番人の部品の答えと同じになる。
# 作り物の HOME に本物の番人の部品を置いた時と、 番人の無い HOME の時を確かめる。 FAIL 1 行ずつ。
set -u
TOOLING="$(cd "$(dirname "$0")/.." && pwd)"
PLACES_SOURCE="$(cd -P "${HOME}/.git-hooks/scanners" 2>/dev/null && pwd)/guard_places.py"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
fails=0
cases=0
check() {   # check <名前> <得た値> <望む値>
    cases=$((cases + 1))
    [ "$2" = "$3" ] || { echo "FAIL $1: got $2, want $3"; fails=$((fails + 1)); }
}

export HOME="${WORK}/home"
mkdir -p "${HOME}"
unset AGENT_PLATFORM_ROOT GUARD_CONFIG_DIR AREA_GUARD_STATE ANON_TRUTH_PATH
# shellcheck source=../lib/guard-place.sh
source "${TOOLING}/lib/guard-place.sh"

# 番人の無い HOME: 根の無い時の置き場
check "番人なし の禁止語" "$(guard_place master-words)" "${HOME}/.config/anon-words/master.txt"
check "番人なし の印" "$(guard_place marks)" "${HOME}/.cache/area-guard"
check "番人なし の設定" "$(guard_place orders.txt)" "${HOME}/.config/guard/orders.txt"

if [ -f "${PLACES_SOURCE}" ]; then
    mkdir -p "${HOME}/.git-hooks/scanners"
    cp "${PLACES_SOURCE}" "${HOME}/.git-hooks/scanners/"
    export AGENT_PLATFORM_ROOT="${WORK}/root"
    check "番人あり の禁止語" "$(guard_place master-words)" "${WORK}/root/config/guard/exit/words/master.txt"
    check "番人あり の境界" "$(guard_place areas.txt)" "${WORK}/root/config/guard/boundaries/areas.txt"
    check "番人あり の監査の記録" "$(guard_place audit-logs)" "${WORK}/root/state/guard/audit"
else
    echo "SKIP 番人の部品がこの機械に無い (= 番人ありの 3 件)"
fi

echo "cases=${cases} fails=${fails}"
[ "${fails}" -eq 0 ]
