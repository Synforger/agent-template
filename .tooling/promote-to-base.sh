#!/bin/bash
set -euo pipefail

# =============================================================================
# promote-to-base.sh
# -----------------------------------------------------------------------------
# 派生エージェント repo で実行。 派生で発見した機構改善を agent-template (base) へ
# 逆昇格する。
#
# Usage:
#   ./.tooling/promote-to-base.sh [--file <path>]... [<commit-message>]
#
# Options:
#   --file <path> : 指定 file のみ promote (= 複数指定可、 synced-paths 内のもののみ受理)。
#                   省略時は .synced-paths.txt 全件を書き戻し。
#
# Environment:
#   BASE_REPO_URL  : base repo の git URL (default: 下記)
#   BASE_REPO_PATH : ローカル base path (= clone をスキップ、 開発時用)
#   BASE_BRANCH    : base branch (default: main)
#   FEATURE_BRANCH : 上げる feature branch 名 (default: feature/promote-<timestamp>)
#
# 動作:
#   1. **先に sync-from-base.sh を実行することを推奨** (= 競合解決を派生で済ます)
#   2. base を tmpdir に clone (or BASE_REPO_PATH を直参照)
#   3. .synced-paths.txt を読んで、 派生/<path> → base/src/<path> に書き戻し
#      (= 派生独自 file (synced-paths 外) は弾く、 --file 指定時は対象を絞る)
#   4. base 側で feature branch を切って commit + push
#   5. PR 提案 (= gh pr create) or push URL を出力
# =============================================================================

DEFAULT_BASE_URL="${BASE_REPO_URL:-git@github.com:synforger/agent-template.git}"
BASE_BRANCH="${BASE_BRANCH:-main}"

# --file 引数を抽出 (= 残りは commit message)
SELECTED_FILES=()
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --file)
            shift
            SELECTED_FILES+=("$1")
            shift
            ;;
        --file=*)
            SELECTED_FILES+=("${1#--file=}")
            shift
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

COMMIT_MSG="${POSITIONAL[0]:-chore: promote changes from derived agent}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SYNCED_PATHS_FILE="$AGENT_DIR/.synced-paths.txt"
if [ ! -f "$SYNCED_PATHS_FILE" ]; then
    echo "error: $SYNCED_PATHS_FILE not found" >&2
    exit 1
fi

# base を確保
KEEP_BASE=0
if [ -n "${BASE_REPO_PATH:-}" ]; then
    BASE_DIR="$BASE_REPO_PATH"
    KEEP_BASE=1
    if [ ! -d "$BASE_DIR" ]; then
        echo "error: BASE_REPO_PATH=$BASE_DIR does not exist" >&2
        exit 1
    fi
    echo "==> using local base: $BASE_DIR"
else
    TMP_DIR="$(mktemp -d)"
    BASE_DIR="$TMP_DIR/agent-template"
    echo "==> clone $DEFAULT_BASE_URL ($BASE_BRANCH) → $BASE_DIR"
    git clone --branch="$BASE_BRANCH" "$DEFAULT_BASE_URL" "$BASE_DIR"
fi

# .synced-paths.txt を読む (= synced 集合)
all_sync_paths=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    all_sync_paths+=("$line")
done < "$SYNCED_PATHS_FILE"

# --file 指定がある場合は selective、 synced-paths 内のもののみ受理
sync_paths=()
if [ "${#SELECTED_FILES[@]}" -gt 0 ]; then
    for sel in "${SELECTED_FILES[@]}"; do
        found=0
        for p in "${all_sync_paths[@]}"; do
            if [ "$sel" = "$p" ]; then
                sync_paths+=("$sel")
                found=1
                break
            fi
        done
        if [ "$found" -eq 0 ]; then
            echo "error: --file '$sel' is not in .synced-paths.txt (派生独自 file は promote 不可)" >&2
            exit 1
        fi
    done
    echo "==> selective promote: ${#sync_paths[@]} file(s)"
else
    sync_paths=("${all_sync_paths[@]}")
fi

# feature branch
TS="$(git -C "$AGENT_DIR" rev-parse --short HEAD 2>/dev/null || echo init)"
FEATURE_BRANCH="${FEATURE_BRANCH:-feature/promote-$TS}"
cd "$BASE_DIR"
git checkout -b "$FEATURE_BRANCH"

# 派生 → base 書き戻し
echo "==> write back ${#sync_paths[@]} paths from $AGENT_DIR → base/src/"
for p in "${sync_paths[@]}"; do
    src="$AGENT_DIR/$p"
    dst="$BASE_DIR/src/$p"
    if [ -d "$src" ] || [[ "$p" == */ ]]; then
        mkdir -p "$dst"
        rsync -a --delete "$src/" "$dst/"
    elif [ -f "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
    else
        echo "  warn: $src not found in derived, skip" >&2
    fi
done

# base 側 diff チェック
if git diff --quiet; then
    echo ""
    echo "✓ no changes to promote (= base と派生 同一)"
    [ "$KEEP_BASE" -eq 0 ] && rm -rf "$TMP_DIR"
    exit 0
fi

echo ""
echo "==> changes to promote:"
git status --short

echo ""
echo "==> commit + push"
git add -A
git commit -m "$COMMIT_MSG" -q

if [ "$KEEP_BASE" -eq 0 ]; then
    git push -u origin "$FEATURE_BRANCH"
    echo ""
    echo "✓ pushed to $FEATURE_BRANCH on base remote"
    echo ""
    if command -v gh > /dev/null 2>&1; then
        echo "Create PR with:"
        echo "  cd $BASE_DIR && gh pr create --title \"$COMMIT_MSG\" --body 'Promoted from derived agent.'"
    else
        echo "Open PR manually on the base repo."
    fi
    echo ""
    echo "(base clone left at $BASE_DIR — remove after PR is merged)"
    trap "" EXIT  # tmpdir を消さず PR まで残す
else
    echo ""
    echo "✓ committed on local base ($BASE_DIR) branch $FEATURE_BRANCH"
    echo "  Review + push manually."
fi
