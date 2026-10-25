#!/bin/bash
set -euo pipefail

# =============================================================================
# sync-from-base.sh
# -----------------------------------------------------------------------------
# 派生エージェント repo で実行。 agent-template (base) 最新を取り込む。
#
# Usage:
#   ./.tooling/distribute/sync-from-base.sh
#
# Environment:
#   BASE_REPO_URL  : base repo の git URL (default: 下記 DEFAULT_BASE_URL)
#   BASE_REPO_PATH : ローカル base path を直接指定 (= clone をスキップ、 開発時用)
#   BASE_BRANCH    : base branch (default: main)
#
# 動作:
#   1. base を tmpdir に clone (or BASE_REPO_PATH を直参照)
#   2. base の .synced-paths.txt に在る path (= 列挙も `!` 除外も) が、 派生の .synced-paths.txt に
#      列挙か `!` 除外で全部在るかを見る。 欠けが 1 つでも在れば、 足す行を名指して何も写さずに止まる
#      (= 取り込みは派生の宣言だけを読むので、 base が後から足した file は宣言するまで黙って降りない。
#      新しい script だけが降りて、 それが呼ぶ file が降りない半端な状態を作らない)
#   3. .synced-paths.txt を読んで、 base/src/<path> → 派生/<path> に上書き
#   4. git diff で内容確認 (= 派生 owner が判断、 そのまま commit or 個別 revert)
#
# この file は sync 自身を運べないので (= init で一度だけ届く)、 判定も shell の中に置く
# (= 別の file に出すと、 その file を運ぶ口が無い)
# =============================================================================

DEFAULT_BASE_URL="${BASE_REPO_URL:-git@github.com:synforger/agent-template.git}"
BASE_BRANCH="${BASE_BRANCH:-main}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

# .synced-paths.txt の宣言を 1 行ずつ出す (= 1 行 1 path、 # コメント / 空行 skip、 `!` prefix はそのまま)
declarations() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$line" ] && printf '%s\n' "$line"
    done < "$1"
}

# base が宣言しているのに派生が列挙も `!` 除外もしていない path (= 写す前に止める)
BASE_SYNCED_PATHS_FILE="$BASE_DIR/.synced-paths.txt"
if [ -f "$BASE_SYNCED_PATHS_FILE" ]; then
    declared="$(declarations "$SYNCED_PATHS_FILE" | sed 's/^!//' | sort -u)"
    undeclared=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s\n' "$declared" | grep -qxF -- "${line#!}" || undeclared+=("$line")
    done < <(declarations "$BASE_SYNCED_PATHS_FILE")
    if [ "${#undeclared[@]}" -gt 0 ]; then
        echo "error: ${#undeclared[@]} path(s) the base declares are not in $SYNCED_PATHS_FILE — nothing was synced:" >&2
        for p in "${undeclared[@]}"; do
            echo "    $p" >&2
        done
        echo "  Add each line as the base has it (a path to receive it, '!<path>' to keep it out),"  >&2
        echo "  or as '!<path>  # <reason>' to keep a file the base ships out of this agent, then sync again." >&2
        exit 1
    fi
fi

# 写すのは列挙の path だけ (= `!` prefix は sync 対象外の明示宣言なので読み飛ばす)
sync_paths=()
while IFS= read -r line; do
    case "$line" in "!"*) continue ;; esac
    sync_paths+=("$line")
done < <(declarations "$SYNCED_PATHS_FILE")

if [ "${#sync_paths[@]}" -eq 0 ]; then
    echo "error: no paths in $SYNCED_PATHS_FILE" >&2
    exit 1
fi

echo "==> sync ${#sync_paths[@]} paths from base/src/ → $AGENT_DIR/"
missing_paths=()
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
        # 中間 stderr は完了バナーまでスクロールで流れる。 集計して末尾で再掲する
        # (= 運ばれなかった事実が「✓ sync complete」 と同じ画面に必ず並ぶ)
        echo "  warn: $src not found in base, skip" >&2
        missing_paths+=("$p")
    fi
done

echo ""
echo "==> changes:"
cd "$AGENT_DIR"
git status --short || true

echo ""
if [ "${#missing_paths[@]}" -gt 0 ]; then
    echo "! ${#missing_paths[@]} listed path(s) do not exist in base — nothing was synced for them:"
    for p in "${missing_paths[@]}"; do
        echo "    - $p"
    done
    echo "  Either the base retired them (drop the line from .synced-paths.txt),"
    echo "  or your .synced-paths.txt is ahead of the base you synced from."
    echo ""
    echo "✓ sync complete with ${#missing_paths[@]} skipped. Review with 'git diff', then commit:"
else
    echo "✓ sync complete. Review with 'git diff', then commit:"
fi
echo "  git add -A && git commit -m 'chore: sync from agent-template'"
echo ""
echo "if a derived-side change was overwritten, revert it individually:"
echo "  git checkout HEAD -- <path>"
