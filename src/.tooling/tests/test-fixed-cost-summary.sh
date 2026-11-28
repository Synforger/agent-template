#!/bin/bash
# .tooling/startup/fixed_cost_summary.py の test。 記録を書く hook (= hooks/fixed_cost.py) を持たない派生でも流れるように、
# 記録の行を直に置き、 記録が無い時に no record yet を出す事、 起動の検査の 1 行がこの階層と全体を出し子を数えない事、
# 階層ごとの表が出る事を確かめる。 hook と通しで確かめるのは tests/test-fixed-cost.sh。
#
#   bash .tooling/tests/test-fixed-cost-summary.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUMMARY="${HERE}/startup/fixed_cost_summary.py"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export AGENT_PLATFORM_ROOT="${T}/platform"
LOG="${AGENT_PLATFORM_ROOT}/state/token-usage/fixed.jsonl"
pass=0
fail=0
ok() { if [ "$1" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $3: got [$1] want [$2]"; fi; }

ok "$(python3 "${SUMMARY}")" "fixed_cost: no record yet" "記録が無い"

# hook が書く形の行: 階層 normal の起動と締め、 子の起動 (数えない)、 別の階層の起動 (全体にだけ入る)
mkdir -p "$(dirname "${LOG}")"
NOW="$(date +%Y-%m-%dT%H:%M:%S%z)"
row() { # <phase> <kind> <tier> <child> <weighted>
    printf '{"ts":"%s","phase":"%s","session":"s","agent_dir":"alpha","tier":"%s","tab":"","child":%s,"kind":"%s","answers":1,"context_tokens":%s,"used_tokens":%s,"used_weighted":%s}\n' \
        "${NOW}" "$1" "$3" "$4" "$2" "$5" "$5" "$5" >> "${LOG}"
}
row startup rollover normal false 2065
row close rollover normal false 500
row startup child normal true 11256
row startup rollover projects/P false 3000
ok "$(AGENT_TIER=normal python3 "${SUMMARY}")" \
   "fixed_cost: 直近 7 日 (重みつき) 起動: この階層 1 回・中央値 2k・計 2k / 全体 2 回・中央値 3k・計 5k | 締め: この階層 1 回・中央値 0k・計 0k / 全体 1 回・中央値 0k・計 0k" "1 行"
ok "$(python3 "${SUMMARY}" --by-tier | grep '| projects/P |')" "alpha | projects/P | 1 回・中央値 3k・計 3k | 0 回" "階層ごとの表"

echo "fixed-cost-summary: pass=${pass} fail=${fail}"
[ "${fail}" -eq 0 ]
