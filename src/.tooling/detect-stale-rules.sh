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
# 除外 = _template.md (= 雛形) / _archive/* (= 履歴)。 個別 file は frontmatter `stable: true` で除外
# 対象は rule / profile / _README だけなので、 記録と作業用の枝は歩かない
# (= journal / drafts / plans / research / todos 配下に対象 path は 1 つも無い)
TARGETS=$(find . \
  -path "./.git" -prune -o \
  -path "./.claude/worktrees" -prune -o \
  -path "*/_archive" -prune -o \
  -path "*/journal" -prune -o \
  -path "*/drafts" -prune -o \
  -path "*/plans" -prune -o \
  -path "*/research" -prune -o \
  -path "*/todos" -prune -o \
  -path "*/_scratch" -prune -o \
  \( \
    -path "./CLAUDE.md" -o \
    -path "./profile/*.md" -o \
    -path "./rules/always.md" -o \
    -path "./rules/always/*.md" -o \
    -path "./rules/lazy/*.md" -o \
    -path "./rules/_README.md" -o \
    -path "./projects/_README.md" -o \
    -path "./projects/*/_README.md" -o \
    -path "./projects/*/rules/always.md" -o \
    -path "./projects/*/rules/always/*.md" -o \
    -path "./projects/*/rules/lazy/*.md" -o \
    -path "./projects/*/subprojects/*/_README.md" -o \
    -path "./projects/*/subprojects/*/rules/always.md" -o \
    -path "./projects/*/subprojects/*/rules/always/*.md" -o \
    -path "./projects/*/subprojects/*/rules/lazy/*.md" \
  \) -print 2>/dev/null | grep -v '_template\.md$' | sort)

now_ts=$(date +%s)
cutoff_7d=$(( now_ts - 7 * 86400 ))

# 判定に要るのは「7 日以内に触られたか」だけなので、 履歴全体を遡らず境界から先だけ見る。
# file ごとに `git log -1` を起こすと対象数だけ全履歴走査が走っていた (= 所要時間の大半)。
# 日付の実値は退役候補の表示にだけ要るので、 該当した file にのみ後から引く。
RECENT_FILES=$(git -c core.quotePath=false log --since="@$cutoff_7d" --format= --name-only -- $TARGETS 2>/dev/null | sort -u)
TRACKED_FILES=$(git -c core.quotePath=false ls-files -- $TARGETS 2>/dev/null)

# frontmatter `stable: true` (= 永続原則 file、 触らないのが正常) を 1 回の awk で拾う。
# file ごとに awk と grep を起こすと対象数ぶんプロセスが増える。
STABLE_FILES=$(awk 'FNR==1{c=0; done=0} done{next} /^---$/{c++; if(c==2) done=1; next} c==1 && /^stable:[[:space:]]*true/{print FILENAME; done=1}' $TARGETS 2>/dev/null)

# 改行区切りの一覧に対する所属判定 (= 外部コマンドを起こさない)
in_list() { case $'\n'"$2"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }

stale_list=()
total=0
for f in $TARGETS; do
    [ -f "$f" ] || continue
    in_list "$f" "$STABLE_FILES" && continue
    # 除外 2: _README.md = 構造/仕様説明 file (= 仕様改修時のみ触る性質、 単独 stale 判定意味薄。
    #         索引漏れ / mapping 不整合は docs-check step 3 / 8 で別途検出)
    case "${f##*/}" in
        _README.md) continue ;;
    esac
    total=$((total + 1))
    rel="${f#./}"
    # untracked / gitignored 配下は判定対象外 (= 旧実装の last_ts=0 扱いと同じ)
    in_list "$rel" "$TRACKED_FILES" || continue
    in_list "$rel" "$RECENT_FILES" || stale_list+=("$f")
done
stale_count=${#stale_list[@]}

if [ "$SUMMARY_MODE" -eq 1 ]; then
    echo "stale_rules: total=$total stale(7d)=$stale_count"
    exit 0
fi

echo "===== stale-rule detection (no update for 7 days) ====="
echo "files scanned: $total"
echo "retirement candidates (7 days stale): $stale_count"
echo ""
if [ "$stale_count" -gt 0 ]; then
    echo "candidates:"
    for f in "${stale_list[@]}"; do
        last_date=$(git log -1 --format=%cd --date=short -- "$f" 2>/dev/null || echo "(no commit)")
        echo "  $f (last commit: $last_date)"
    done
fi
