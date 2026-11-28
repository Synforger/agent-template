#!/bin/bash
# .tooling/hooks/fixed_cost.py と .tooling/startup/fixed_cost_summary.py の test。 作り物の会話の記録を渡し、
# 起動は session の最初の Stop で 1 回だけ記録され (= 2 回目は増えない)、 封筒の種類・context・重みつきの量が正しい事、
# 締めは締めの封筒が来た時の長さから後だけを数える事、 起動の検査の 1 行がこの階層と全体を出し子を数えない事、
# 階層ごとの表が出る事、 記録が無い時に no record yet を出す事を確かめる。
#
#   bash .tooling/tests/test-fixed-cost.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HERE}/hooks/fixed_cost.py"
SUMMARY="${HERE}/startup/fixed_cost_summary.py"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export AGENT_PLATFORM_ROOT="${T}/platform"
LOG="${AGENT_PLATFORM_ROOT}/state/token-usage/fixed.jsonl"
pass=0
fail=0
ok() { if [ "$1" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $3: got [$1] want [$2]"; fi; }
hook() { # <event> <session> <transcript> [prompt]
    printf '{"hook_event_name":"%s","session_id":"%s","transcript_path":"%s","cwd":"/x/alpha","prompt":"%s"}' "$1" "$2" "$3" "${4:-}" \
        | AGENT_TIER="${TIER:-normal}" python3 "${HOOK}"
}
field() { python3 -c 'import json,sys;r=[json.loads(l) for l in open(sys.argv[1])][int(sys.argv[2])];print(" ".join(str(r[k]) for k in sys.argv[3:]))' "${LOG}" "$@"; }

ok "$(python3 "${SUMMARY}")" "fixed_cost: no record yet" "記録が無い"

# 入れ替えの封筒で始まり、 同じ id の応答が 2 行に分かれる会話
cat > "${T}/a.jsonl" <<'EOF'
{"type":"user","message":{"content":"Automatic session rollover, sent by the client\n<session-rollover phase=\"start\">"}}
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":20}}}
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":20}}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}
{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":2000,"output_tokens":100}}}
EOF
hook Stop s-a "${T}/a.jsonl"
hook Stop s-a "${T}/a.jsonl"
ok "$(wc -l < "${LOG}" | tr -d ' ')" "1" "2 回目の Stop は起動を書かない"
ok "$(field 0 phase kind answers context_tokens used_weighted tier)" "startup rollover 2 2005 2065 normal" "起動の行"

# 締めの封筒が来た後の量だけが締めに入る
hook UserPromptSubmit s-a "${T}/a.jsonl" 'Automatic session rollover <session-rollover phase=\"close\" reason=\"idle\">'
cat >> "${T}/a.jsonl" <<'EOF'
{"type":"user","message":{"content":"<session-rollover phase=\"close\">"}}
{"type":"assistant","message":{"id":"m3","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":3000,"output_tokens":40}}}
EOF
hook Stop s-a "${T}/a.jsonl"
hook Stop s-a "${T}/a.jsonl"
ok "$(wc -l < "${LOG}" | tr -d ' ')" "2" "締めは 1 回だけ"
ok "$(field 1 phase answers context_tokens used_weighted)" "close 1 3000 500" "締めの行"

# 子のタブは記録するが、 起動の数には入れない。 別の階層の起動は全体にだけ入る
cat > "${T}/b.jsonl" <<'EOF'
{"type":"user","message":{"content":"<child-start>\ntier=normal\n</child-start>\nやる事"}}
{"type":"assistant","message":{"id":"c1","usage":{"input_tokens":1,"cache_creation_input_tokens":9000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
hook Stop s-b "${T}/b.jsonl"
TIER=projects/P hook Stop s-c "${T}/a.jsonl"
ok "$(AGENT_TIER=normal python3 "${SUMMARY}")" \
   "fixed_cost: 直近 7 日 (重みつき) 起動: この階層 1 回・中央値 2k・計 2k / 全体 2 回・中央値 2k・計 5k | 締め: この階層 1 回・中央値 0k・計 0k / 全体 1 回・中央値 0k・計 0k" "1 行"
ok "$(python3 "${SUMMARY}" --by-tier | grep '| projects/P |')" "alpha | projects/P | 1 回・中央値 3k・計 3k | 0 回" "階層ごとの表"

echo "fixed-cost: pass=${pass} fail=${fail}"
[ "${fail}" -eq 0 ]
