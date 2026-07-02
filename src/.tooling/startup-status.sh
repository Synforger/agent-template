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

# 4. 静的 rule 容量監視 (= 階層別合計、 上限 = plans/rule-capacity-redesign 真値)
#    ARK 親 = CLAUDE + profile-core + always (= 40 KB)
#    project = _README + always (= 20 KB)
#    subproject = _README + always (= 10 KB)
#    形態 D 移行中: rules/always.md (新) + rules/always/*.md (旧) 両対応で合算
ARK_PARENT_LIMIT=40960
PROJECT_LIMIT=20480
SUBPROJECT_LIMIT=10240

sum_files() {
    local total=0 f
    for f in "$@"; do
        [ -f "$f" ] && total=$((total + $(wc -c < "$f")))
    done
    echo "$total"
}

overflows=()
parent_files=(CLAUDE.md profile/profile-core.md rules/always.md)
for f in rules/always/*.md; do [ -f "$f" ] && parent_files+=("$f"); done
parent_size=$(sum_files "${parent_files[@]}")
[ "$parent_size" -gt "$ARK_PARENT_LIMIT" ] && overflows+=("ARK 親: $((parent_size/1024))KB > 40KB")

for p_dir in projects/*/; do
    p_name=$(basename "$p_dir")
    case "$p_name" in _*) continue ;; esac
    proj_files=("$p_dir/_README.md" "$p_dir/rules/always.md")
    for f in "$p_dir"rules/always/*.md; do [ -f "$f" ] && proj_files+=("$f"); done
    proj_size=$(sum_files "${proj_files[@]}")
    [ "$proj_size" -gt "$PROJECT_LIMIT" ] && overflows+=("$p_name: $((proj_size/1024))KB > 20KB")

    for s_dir in "$p_dir"subprojects/*/; do
        [ -d "$s_dir" ] || continue
        s_name=$(basename "$s_dir")
        case "$s_name" in _*) continue ;; esac
        sub_files=("$s_dir/_README.md" "$s_dir/rules/always.md")
        for f in "$s_dir"rules/always/*.md; do [ -f "$f" ] && sub_files+=("$f"); done
        sub_size=$(sum_files "${sub_files[@]}")
        [ "$sub_size" -gt "$SUBPROJECT_LIMIT" ] && overflows+=("$p_name/$s_name: $((sub_size/1024))KB > 10KB")
    done
done

if [ "${#overflows[@]}" -gt 0 ]; then
    echo "static_capacity: ${#overflows[@]} 件 上限超過"
    for o in "${overflows[@]}"; do echo "  - $o"; done
else
    echo "static_capacity: OK (= 全階層上限内)"
fi

# 5. docs-check (= 最後の 1 行 summary)
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
