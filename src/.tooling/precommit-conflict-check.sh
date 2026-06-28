#!/usr/bin/env bash
# precommit-conflict-check.sh - rule 改訂 commit 前に section 名重複 / 同 rule 文重複を機械検査 (= LLM 不使用)
# 用途: .git/hooks/pre-commit から呼ばれる、 stderr 警告のみで blocking なし (= soft fail)
# 走らせ方: bash <agent-repo-root>/.tooling/precommit-conflict-check.sh (= 単体実行可)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 0

# 改訂対象 file の filter (= rule + profile + CLAUDE)
DIFF_FILES=$(git diff --cached --name-only -- \
    CLAUDE.md \
    'profile/*.md' \
    'rules/*.md' \
    'rules/always/*.md' \
    'rules/lazy/*.md' 2>/dev/null | grep -v '^$' || true)

[ -z "$DIFF_FILES" ] && exit 0

# 新規追加された H2/H3 section 名 (= ## or ### 行)
NEW_SECTIONS=$(git diff --cached -- $DIFF_FILES | grep -E '^\+##+\s' | sed 's/^+//' | sort -u || true)

[ -z "$NEW_SECTIONS" ] && exit 0

# 既存 file の section 名と突き合わせ
WARNED=0
ALL_RULE_FILES=$(find . \
    -path "./.git" -prune -o \
    -path "./.claude/worktrees" -prune -o \
    \( \
      -path "./CLAUDE.md" -o \
      -path "./profile/*.md" -o \
      -path "./rules/always/*.md" -o \
      -path "./rules/lazy/*.md" \
    \) -print 2>/dev/null | sort)

while IFS= read -r new_sec; do
    [ -z "$new_sec" ] && continue
    # diff の section 名と同 prefix の section が他 file にあるか
    matches=$(grep -l -F "$new_sec" $ALL_RULE_FILES 2>/dev/null | head -5)
    count=$(echo "$matches" | grep -c . || echo 0)
    if [ "$count" -gt 1 ]; then
        if [ "$WARNED" -eq 0 ]; then
            echo "" >&2
            echo "===== precommit-conflict-check: section 名重複候補 =====" >&2
            WARNED=1
        fi
        echo "  「${new_sec}」 が複数 file にあり:" >&2
        echo "$matches" | sed 's/^/    /' >&2
    fi
done <<< "$NEW_SECTIONS"

if [ "$WARNED" -eq 1 ]; then
    echo "" >&2
    echo "確認推奨: 真値が 2 箇所以上に分散していないか" >&2
    echo "blocking なし (= soft fail)、 確認後そのまま commit 可" >&2
    echo "====================================================" >&2
fi

exit 0
