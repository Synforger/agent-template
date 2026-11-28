#!/bin/bash
# .tooling/work/plan_run.py の test。 作り物の HOME (会話の記録)・器の根 (7 日枠の行)・repo を置き、
# 起点の前と後の budget の行 (公式の % が頭・会話からの見当が内訳)、 古い値を持つ行に引かれない事、 別の口座の根の会話を
# 数えない事、 覚えた物差しを使う事、 2 つが離れた印、 単価の無い model を数えない事、 窓の途中で枠の大きさが変わった時に
# 物差しと公式の % を変わった後だけで読む事、 cost の並び、 leftovers が開いたままの物を拾う事、 status が単位の表を波ごとの木にする事を確かめる。
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
answer() { # <file> <id> <ISO の時刻> <出力 token> [model]
    echo "{\"type\": \"assistant\", \"timestamp\": \"$3\", \"message\": {\"id\": \"$2\", \"model\": \"${5:-m-test}\", \"usage\": {\"output_tokens\": $4}}}" >> "$1"
}
# 単価の見本: 出力 100 万 token = 5$ (= 出力 1.9M token は 9.5$)
printf '[cache_write]\nephemeral_5m = 1.25\n[models.m-test]\ninput = 1.0\noutput = 5.0\ncache_read = 0.1\n' > "${T}/prices.toml"
config() { # <起点の ISO>
    printf 'start = %s\n[caps]\npersonal = 40\n[plan]\nagents = ["alpha"]\n[leftovers]\nroots = ["%s"]\ngh = []\n' "$1" "${T}/repos" > "${T}/plan-run.toml"
    printf '[account_roots]\npersonal = "~/.claude"\nwork = "~/.claude-work"\n' >> "${T}/plan-run.toml"
    printf '[status]\nplan = "%s"\nunits_heading = "単位の表"\nwaves_heading = "波"\n' "${T}/plan.md" >> "${T}/plan-run.toml"
}
check() { # <名前> <期待の正規表現> <引数...>
    local name="$1" want="$2" out
    shift 2
    out="$("${PYTHON}" "${TOOL}" --config "${T}/plan-run.toml" --prices "${T}/prices.toml" "$@" 2>&1)"
    if [[ "${out}" =~ ${want} ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL ${name}: ${out}"; fi
}
check_not() { # <名前> <出てはいけない正規表現> <引数...>
    local name="$1" unwanted="$2" out
    shift 2
    out="$("${PYTHON}" "${TOOL}" --config "${T}/plan-run.toml" --prices "${T}/prices.toml" "$@" 2>&1)"
    if [[ "${out}" =~ ${unwanted} ]]; then fail=$((fail + 1)); echo "FAIL ${name}: ${out}"; else pass=$((pass + 1)); fi
}

EPOCH_A="1970-01-01T00:16:40+00:00" # 1000
EPOCH_B="1970-01-01T00:33:20+00:00" # 2000
row 1100 10 2000
row 1900 95 2000
row 1950 64 2000 # 古い値を持つ session の行
ALPHA="${HOME}/.claude/projects/-Users-x-agents-alpha/s1.jsonl"
BETA="${HOME}/.claude/projects/-Users-x-agents-beta/s2.jsonl"
answer "${ALPHA}" a1 "1970-01-01T00:20:00+00:00" 1900000   # 窓 A: 9.5$
answer "${ALPHA}" a1 "1970-01-01T00:20:00+00:00" 1900000   # 同じ id は 1 回だけ
touch -t 203001010000 "${ALPHA}" "${BETA}"

config "${EPOCH_B}"
check "before the start" 'plan_budget\(personal\): 起点 .* の前 \(今の窓 95%' budget

row 2100 5 3000
answer "${ALPHA}" b1 "1970-01-01T00:35:00+00:00" 40000    # 窓 B: alpha 0.2$
answer "${BETA}" b2 "1970-01-01T00:36:00+00:00" 60000   # 窓 B: beta 0.3$
answer "${BETA}" b3 "1970-01-01T00:36:30+00:00" 200000 m-unknown # 窓 B: 単価の無い model の 0.2M token (数えない)
WORK="${HOME}/.claude-work/projects/-Users-x-agents-alpha/s3.jsonl"
answer "${WORK}" w1 "1970-01-01T00:37:00+00:00" 1000000 # 窓 B: 会社の口座の根の alpha 5.0$ (個人の計画には数えない)
touch -t 203001010000 "${ALPHA}" "${BETA}" "${WORK}"
# 物差しは戻った窓 A の 9.5$ / 95% = 1% あたり 0.1$。 公式は窓 B の 5%、 会話からは alpha 0.2$ = 2.0%・この機械の計 5.0%
check "after the start" 'plan_budget\(personal\): 公式 5% / 上限 40% \(残り 35%\)・会話から 5\.0% \(計画 2\.0%\)・窓の戻り' budget
check_not "close enough" '離れている' budget
check "local share" 'この機械の会話の計 5\.0% \(beta 3\.0% / alpha 2\.0%\)・物差し 1% = 0\.1\$ \(.* に戻った窓の 95% の実績.*単価の無い model の 0\.2M token は数えていない' budget
check "cost order" '1 \| 0\.30 \| 3\.00% \| 2 \| beta .*2 \| 0\.20 \| 2\.00% \| 1 \| alpha' cost --since "${EPOCH_B}"
# 物差しは窓・測る間 (= 窓の戻りの 7 日前から。 作り物の窓なので負の時刻)・% ごとに覚える。 覚えた値を 0.2$ に書き換えると、 会話を読み直さずにその値で割る (alpha 0.2$ は 1.0%)。
# 会話からの見当 2.5% は公式の 5% (丸めの幅で 4〜6%) より 1.1 倍を越えて小さいので、 離れた印と model ごとの内訳が付く
STICK="${AGENT_PLATFORM_ROOT}/state/token-usage/yardstick.json"
if [ "$(cat "${STICK}" 2>/dev/null)" = '{"personal:2000:-602800:95:usd": 0.1}' ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL yardstick stored: $(cat "${STICK}" 2>&1)"; fi
echo '{"personal:2000:-602800:95:usd": 0.2}' > "${STICK}"
check "yardstick remembered" '公式 5% / 上限 40% .*会話から 2\.5% \(計画 1\.0%\)・公式と会話からの見当が 0\.50 倍 \(会話から / 公式\) 離れている.*物差し 1% = 0\.2\$' budget
check "model shares when apart" '  離れた時の内訳: model ごとの会話から m-test 2\.5%' budget
# 線は 1.1 倍: 会話からの見当 7.1% (= 0.5$ / 0.07$) は 6% × 1.1 = 6.6% を越えるので鳴る (1.25 倍の 7.5% なら鳴らなかった)
echo '{"personal:2000:-602800:95:usd": 0.07}' > "${STICK}"
check "the gap line is 1.1 times" '公式 5% / 上限 40% .*会話から 7\.1% .*離れている' budget

# 窓 D (9395200 に始まり 10000000 に戻る) は途中で枠の大きさが変わった: 1 時間ごとの最大が 50% → 2% に落ち、 その後 20%。
# 物差しは変わった後の 2.0$ / 20% = 0.1$ (前の 5.0$ は数えない)。 公式の % も変わった後の 20%
rm -f "${STICK}"
row 9395300 30 10000000
row 9398900 50 10000000
row 9402500 2 10000000
row 9406000 20 10000000
answer "${ALPHA}" d1 "1970-04-19T18:00:00+00:00" 1000000 # 変わる前: 5.0$
answer "${ALPHA}" d2 "1970-04-19T20:30:00+00:00" 400000  # 変わった後: 2.0$
touch -t 203001010000 "${ALPHA}" "${BETA}" "${WORK}"
config "1970-04-19T17:46:40+00:00"
check "resized official" 'plan_budget\(personal\): 公式 20% / 上限 40% \(残り 20%\).*に枠の大きさが変わった \(変わった後の値\)・口座の全部 50%' budget
check "resized yardstick" '物差し 1% = 0\.1\$ \(.* に戻った窓、枠の大きさが変わった後の 20% の実績' budget

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
