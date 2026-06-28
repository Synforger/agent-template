#!/usr/bin/env bash
# detect-stale-rules.sh - 7 日無更新 rule file = 退役候補検出 (= LLM 不使用)
# 用途: startup-status.sh から呼ばれる、 または 月次手動起動
# 入力: 各 rule file の git log 最終 commit 日
# 出力: 7 日 0 commit = 退役候補一覧
# 走らせ方:
#   bash <agent-repo-root>/.tooling/detect-stale-rules.sh             # 全件表
#   bash <agent-repo-root>/.tooling/detect-stale-rules.sh --summary   # 1 行集約

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "ROOT not found: $ROOT"; exit 2; }

SUMMARY_MODE=0
case "${1:-}" in
  --summary) SUMMARY_MODE=1 ;;
esac

# 対象 file = rule + profile + CLAUDE + 各プロジェクト rule (= glob で自動編入、 ハードコード廃止)
# 除外 = _template.md (= 雛形) / dev-env/* (= 環境別、 触らないのが正常) / _archive/* (= 履歴)
TARGETS=$(find . \
  -path "./.git" -prune -o \
  -path "./.claude/worktrees" -prune -o \
  -path "*/_archive" -prune -o \
  -path "*/dev-env" -prune -o \
  \( \
    -path "./CLAUDE.md" -o \
    -path "./profile/*.md" -o \
    -path "./rules/always/*.md" -o \
    -path "./rules/lazy/*.md" -o \
    -path "./rules/_README.md" -o \
    -path "./projects/_README.md" -o \
    -path "./projects/*/_README.md" -o \
    -path "./projects/*/rules/always/*.md" -o \
    -path "./projects/*/rules/lazy/*.md" -o \
    -path "./projects/*/subprojects/*/_README.md" -o \
    -path "./projects/*/subprojects/*/rules/always/*.md" -o \
    -path "./projects/*/subprojects/*/rules/lazy/*.md" \
  \) -print 2>/dev/null | grep -v '_template\.md$' | sort)

now_ts=$(date +%s)
cutoff_7d=$(( now_ts - 7 * 86400 ))

stale_list=()
total=0
for f in $TARGETS; do
    [ -f "$f" ] || continue
    # 除外 1: frontmatter `stable: true` 宣言 = 永続原則 file (= 触らないのが正常)
    if awk '/^---$/{c++; if(c==2) exit; next} c==1 && /^stable:[[:space:]]*true/' "$f" | grep -q true; then
        continue
    fi
    # 除外 2: _README.md = 構造/仕様説明 file (= 仕様改修時のみ触る性質、 単独 stale 判定意味薄。
    #         索引漏れ / mapping 不整合は docs-check step 3 / 8 で別途検出)
    case "$(basename "$f")" in
        _README.md) continue ;;
    esac
    total=$((total + 1))
    last_ts=$(git log -1 --format=%at -- "$f" 2>/dev/null || echo 0)
    if [ "$last_ts" -lt "$cutoff_7d" ] && [ "$last_ts" -gt 0 ]; then
        stale_list+=("$f")
    fi
done
stale_count=${#stale_list[@]}

if [ "$SUMMARY_MODE" -eq 1 ]; then
    echo "stale_rules: total=$total stale(7d)=$stale_count"
    exit 0
fi

echo "===== エージェント rule 形骸化検出 (= 7 日無更新) ====="
echo "対象 file 数: $total"
echo "退役候補 (= 7 日無更新): $stale_count"
echo ""
if [ "$stale_count" -gt 0 ]; then
    echo "退役候補一覧:"
    for f in "${stale_list[@]}"; do
        last_date=$(git log -1 --format=%cd --date=short -- "$f" 2>/dev/null || echo "(no commit)")
        echo "  $f (最終 commit: $last_date)"
    done
fi
