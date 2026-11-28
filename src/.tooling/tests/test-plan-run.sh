#!/bin/bash
# .tooling/work/plan_run.py の test。 作り物の HOME (会話の記録)・器の根 (7 日枠の行)・repo を置き、
# 起点の前と後の budget の行、 古い値を持つ行に引かれない事、 別の口座の根の会話を数えない事、 覚えた物差しを使う事、
# cost の並び、 leftovers が開いたままの物を拾う事、 status が単位の表を波ごとの木にする事を確かめる。
#
#   bash .tooling/tests/test-plan-run.sh
set -uo pipefail

TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/work/plan_run.py"
PYTHON="$(command -v python3)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0
export HOME="${T}/home"
export AGENT_PLATFORM_ROOT="${T}/platform"
LOG="${AGENT_PLATFORM_ROOT}/state/statusline/rate-limits.jsonl"
mkdir -p "$(dirname "${LOG}")" "${HOME}/.claude/projects/-Users-x-agents-alpha" "${HOME}/.claude/projects/-Users-x-agents-beta" "${T}/repos"
mkdir -p "${HOME}/.claude-work/projects/-Users-x-agents-alpha"

# 窓 A は 1000 に始まり 2000 に戻る (95% まで進んだ)。 窓 B は 2000 に始まり 3000 に戻る
row() { echo "{\"timestamp\": $1, \"account_id\": \"personal\", \"seven_day_pct\": $2, \"seven_day_resets_at\": $3}" >> "${LOG}"; }
answer() { # <file> <id> <ISO の時刻> <出力 token>
    echo "{\"type\": \"assistant\", \"timestamp\": \"$3\", \"message\": {\"id\": \"$2\", \"usage\": {\"output_tokens\": $4}}}" >> "$1"
}
config() { # <起点の ISO>
    printf 'start = %s\n[caps]\npersonal = 40\n[plan]\nagents = ["alpha"]\n[leftovers]\nroots = ["%s"]\ngh = []\n' "$1" "${T}/repos" > "${T}/plan-run.toml"
    printf '[account_roots]\npersonal = "~/.claude"\nwork = "~/.claude-work"\n' >> "${T}/plan-run.toml"
    printf '[status]\nplan = "%s"\nunits_heading = "単位の表"\nwaves_heading = "波"\n' "${T}/plan.md" >> "${T}/plan-run.toml"
}
check() { # <名前> <期待の正規表現> <引数...>
    local name="$1" want="$2" out
    shift 2
    out="$("${PYTHON}" "${TOOL}" --config "${T}/plan-run.toml" "$@" 2>&1)"
    if [[ "${out}" =~ ${want} ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL ${name}: ${out}"; fi
}

EPOCH_A="1970-01-01T00:16:40+00:00" # 1000
EPOCH_B="1970-01-01T00:33:20+00:00" # 2000
row 1100 10 2000
row 1900 95 2000
row 1950 64 2000 # 古い値を持つ session の行
ALPHA="${HOME}/.claude/projects/-Users-x-agents-alpha/s1.jsonl"
BETA="${HOME}/.claude/projects/-Users-x-agents-beta/s2.jsonl"
answer "${ALPHA}" a1 "1970-01-01T00:20:00+00:00" 1900000   # 窓 A: 重み 9.5M
answer "${ALPHA}" a1 "1970-01-01T00:20:00+00:00" 1900000   # 同じ id は 1 回だけ
touch -t 203001010000 "${ALPHA}" "${BETA}"

config "${EPOCH_B}"
check "before the start" 'plan_budget\(personal\): 起点 .* の前 \(今の窓 95%' budget

row 2100 5 3000
answer "${ALPHA}" b1 "1970-01-01T00:35:00+00:00" 40000    # 窓 B: alpha 0.2M
answer "${BETA}" b2 "1970-01-01T00:36:00+00:00" 60000   # 窓 B: beta 0.3M
WORK="${HOME}/.claude-work/projects/-Users-x-agents-alpha/s3.jsonl"
answer "${WORK}" w1 "1970-01-01T00:37:00+00:00" 1000000 # 窓 B: 会社の口座の根の alpha 5.0M (個人の計画には数えない)
touch -t 203001010000 "${ALPHA}" "${BETA}" "${WORK}"
# 物差しは窓 A の 9.5M / 95% = 1% あたり 0.1M。 alpha 0.2M は 2.0%、 この機械の計は 5.0%
check "after the start" '計画 2\.0% / 上限 40% \(残り 38\.0%\)・口座の全部 5%' budget
check "local share" 'この機械の会話の計 5\.0% \(beta 3\.0% / alpha 2\.0%\)・物差し 1% = 0\.1M' budget
check "cost order" '1 \| 0\.30M \| 3\.00% \| 1 \| beta .*2 \| 0\.20M \| 2\.00% \| 1 \| alpha' cost --since "${EPOCH_B}"
# 物差しは窓と % ごとに覚える。 覚えた値を 0.2M に書き換えると、 会話を読み直さずにその値で割る (alpha 0.2M は 1.0%)
STICK="${AGENT_PLATFORM_ROOT}/state/token-usage/yardstick.json"
if [ "$(cat "${STICK}" 2>/dev/null)" = '{"personal:2000:95": 100000.0}' ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL yardstick stored: $(cat "${STICK}" 2>&1)"; fi
echo '{"personal:2000:95": 200000.0}' > "${STICK}"
check "yardstick remembered" '計画 1\.0% / 上限 40% .*物差し 1% = 0\.2M' budget

cat > "${T}/plan.md" <<'PLAN'
## 設計
### 波 (波の順に進む)
| 波 | 中身 |
|---|---|
| W0 片付け | 棚卸し |
| W1 固定費 | 入れ替え |
## 単位の表 (進行の単位)
| 単位 | 中身 | 持つタブ | 何の後か | 見積もり | 状態 |
|---|---|---|---|---|---|
| W0-1 | 棚卸し: 全行に印 | normal | - | 0.5% | ✅ 済み |
| W0-2 | 物差し (測り直す) | normal | W0-1 | 0.5% | ⬜ |
| W1-1 | 入れ替え。階層ごと | client | W0-1 | 1% | 票は渡し済み |
PLAN
check "status count" 'plan_status: ✅ 1 / ⬜ 2 \(単位 3・残りの見積もり 1\.5%\)' status
check "status tree" '⬜ W0 片付け 1/2.*  ✅ W0-1 棚卸し.*  ⬜ W0-2 物差し \[normal・0\.5%・W0-1 の後\].*⬜ W1 固定費 0/1.*  ⬜ W1-1 入れ替え \[client・1%・W0-1 の後・票は渡し済み\]' status

REPO="${T}/repos/tool"
git init -q -b develop "${REPO}"
git -C "${REPO}" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base
git -C "${REPO}" branch feature/left
git -C "${REPO}" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m more
echo x > "${REPO}/draft.txt"
check "leftover branch" 'tool \| branch \| feature/left \| develop より 0 commit 先' leftovers
check "leftover dirty" 'tool \| dirty \| 1 \|' leftovers
check "leftover count" 'leftovers: repo 1 本・branch 1 / dirty 1' leftovers

echo "pass=${pass} fail=${fail}"
[ "${fail}" -eq 0 ]
