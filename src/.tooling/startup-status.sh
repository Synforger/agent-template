#!/usr/bin/env bash
# startup-status.sh - セッション起動時の状態スナップショット (= LLM 不使用、 token ゼロ)
# 用途: Phase B-共通 で実行、 各 utility を summary モードで呼んで結果を 1 ブロックで出力
# エージェント は出力を Read して「打診すべき項目があれば 1 行打診」 を Phase C で判断
# 走らせ方: bash <agent-repo-root>/.tooling/startup-status.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "ROOT not found: $ROOT"; exit 2; }

echo "===== エージェント startup status (= $(date '+%Y-%m-%d %H:%M:%S')) ====="

# 0. PC 識別 (= 自宅 / 会社、 LocalHostName → label mapping)
PC_LABELS_FILE="$ROOT/.tooling/pc-labels.txt"
local_host=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
pc_label=""
if [ -f "$PC_LABELS_FILE" ]; then
    pc_label=$(grep -v '^#' "$PC_LABELS_FILE" | grep -v '^$' | awk -v h="$local_host" '$1 == h { print $2; exit }')
fi
if [ -n "$pc_label" ]; then
    echo "PC: $pc_label ($local_host)"
else
    echo "PC: unknown ($local_host) ← .tooling/pc-labels.txt に追記してください"
fi

# 1. rule 形骸化検出 (= 7 日無更新 = 退役候補)
if [ -x .tooling/detect-stale-rules.sh ]; then
    bash .tooling/detect-stale-rules.sh --summary 2>/dev/null
else
    echo "stale_rules: (skipped, script not found)"
fi

# 2. rule file 間重複検出
if [ -x .tooling/detect-duplicates.py ]; then
    python3 .tooling/detect-duplicates.py --summary 2>/dev/null
else
    echo "duplicates: (skipped, script not found)"
fi

# 3. docs-check (= 最後の 1 行 summary)
if [ -x .tooling/docs-check.sh ]; then
    docs_summary=$(bash .tooling/docs-check.sh 2>&1 | sed $'s/\033\[[0-9;]*m//g' | grep -E "^(PASS|WARN|FAIL):" | tr '\n' ' ')
    echo "docs-check: $docs_summary"
else
    echo "docs-check: (script not found)"
fi

echo "============================================"
echo ""
echo "行動指針:"
echo "  - stale_rules / dup_pairs は起動時無視 (= 終了時 Step 2 でエージェントが走り切る)"
echo "  - docs-check FAIL >= 1 → 同セッション内 fix 必須"
