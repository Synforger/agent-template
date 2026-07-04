#!/bin/bash
set -euo pipefail

# =============================================================================
# sync-from-base.sh
# -----------------------------------------------------------------------------
# 派生エージェント repo で実行。 agent-template (base) 最新を取り込む。
#
# Usage:
#   ./.tooling/sync-from-base.sh
#
# Environment:
#   BASE_REPO_URL  : base repo の git URL (default: 下記 DEFAULT_BASE_URL)
#   BASE_REPO_PATH : ローカル base path を直接指定 (= clone をスキップ、 開発時用)
#   BASE_BRANCH    : base branch (default: main)
#
# 動作:
#   1. base を tmpdir に clone (or BASE_REPO_PATH を直参照)
#   2. .synced-paths.txt を読んで、 base/src/<path> → 派生/<path> に上書き
#   3. git diff で内容確認 (= 派生 owner が判断、 そのまま commit or 個別 revert)
# =============================================================================

DEFAULT_BASE_URL="${BASE_REPO_URL:-git@github.com:synforger/agent-template.git}"
BASE_BRANCH="${BASE_BRANCH:-main}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SYNCED_PATHS_FILE="$AGENT_DIR/.synced-paths.txt"
if [ ! -f "$SYNCED_PATHS_FILE" ]; then
    echo "error: $SYNCED_PATHS_FILE not found" >&2
    exit 1
fi

# base を確保
if [ -n "${BASE_REPO_PATH:-}" ]; then
    BASE_DIR="$BASE_REPO_PATH"
    if [ ! -d "$BASE_DIR" ]; then
        echo "error: BASE_REPO_PATH=$BASE_DIR does not exist" >&2
        exit 1
    fi
    echo "==> using local base: $BASE_DIR"
else
    TMP_DIR="$(mktemp -d)"
    trap "rm -rf '$TMP_DIR'" EXIT
    BASE_DIR="$TMP_DIR/agent-template"
    echo "==> clone $DEFAULT_BASE_URL ($BASE_BRANCH) → $BASE_DIR"
    git clone --depth=1 --branch="$BASE_BRANCH" "$DEFAULT_BASE_URL" "$BASE_DIR"
fi

# .synced-paths.txt を読む (= 1 行 1 path、 # コメント / 空行 skip)
sync_paths=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    sync_paths+=("$line")
done < "$SYNCED_PATHS_FILE"

if [ "${#sync_paths[@]}" -eq 0 ]; then
    echo "error: no paths in $SYNCED_PATHS_FILE" >&2
    exit 1
fi

echo "==> sync ${#sync_paths[@]} paths from base/src/ → $AGENT_DIR/"
for p in "${sync_paths[@]}"; do
    src="$BASE_DIR/src/$p"
    dst="$AGENT_DIR/$p"
    # 末尾 / の dir 同期 or 単体 file
    if [ -d "$src" ] || [[ "$p" == */ ]]; then
        mkdir -p "$dst"
        rsync -a --delete "$src/" "$dst/"
    elif [ -f "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
    else
        echo "  warn: $src not found in base, skip" >&2
    fi
done

echo ""
echo "==> changes:"
cd "$AGENT_DIR"
git status --short || true

echo ""
echo "✓ sync complete. Review with 'git diff', then commit:"
echo "  git add -A && git commit -m 'chore: sync from agent-template'"
echo ""
echo "if a derived-side change was overwritten, revert it individually:"
echo "  git checkout HEAD -- <path>"
