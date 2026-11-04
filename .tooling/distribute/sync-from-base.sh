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
#   2. 写す path を決める: base の .synced-paths.txt が列挙する path と、 派生の .synced-paths.txt が列挙する
#      path を合わせ、 派生が `!` で外した path を引く (= 何を降ろすかの真値は base の宣言 1 本。 派生の file は
#      外す物と、 自分だけが足す物を書く。 base が後から足した file は、 派生が何もしなくても次の取り込みで降りる)
#   3. base が列挙する path を、 理由 (= `!<path>  # <理由>`) の無い `!` で外していれば、 その行を名指して
#      何も写さずに止まる (= 共通の物を黙って外したままにしない)。 外している物は毎回、 理由つきで並べて出す
#   4. base/src/<path> → 派生/<path> に上書き
#   5. git diff で内容確認 (= 派生 owner が判断、 そのまま commit or 個別 revert)
#
# base が .synced-paths.txt を持たない時は、 派生の列挙だけを写す
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

# `!` 行を「path<TAB>理由」 で出す (= 理由は `#` の後ろ。 書いていなければ空)
exclusions() {
    local line path reason
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//')"
        case "$line" in "!"*) ;; *) continue ;; esac
        path="$(printf '%s' "${line%%#*}" | sed -e 's/[[:space:]]*$//')"
        reason=""
        case "$line" in *"#"*) reason="$(printf '%s' "${line#*#}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" ;; esac
        printf '%s\t%s\n' "${path#!}" "$reason"
    done < "$1"
}

own_listed="$(declarations "$SYNCED_PATHS_FILE" | grep -v '^!' || true)"
own_excluded="$(exclusions "$SYNCED_PATHS_FILE")"
excluded_paths="$(printf '%s\n' "$own_excluded" | cut -f1)"

BASE_SYNCED_PATHS_FILE="$BASE_DIR/.synced-paths.txt"
kept_out=""
if [ -f "$BASE_SYNCED_PATHS_FILE" ]; then
    base_listed="$(declarations "$BASE_SYNCED_PATHS_FILE" | grep -v '^!' || true)"
    unexplained=""
    while IFS=$'\t' read -r p reason; do
        [ -n "$p" ] || continue
        printf '%s\n' "$base_listed" | grep -xF -- "$p" > /dev/null || continue
        if [ -z "$reason" ]; then
            unexplained="$unexplained    !$p"$'\n'
        else
            kept_out="$kept_out    $p  # $reason"$'\n'
        fi
    done <<< "$own_excluded"
    if [ -n "$unexplained" ]; then
        echo "error: $SYNCED_PATHS_FILE keeps out path(s) the base ships to every agent, without a reason — nothing was synced:" >&2
        printf '%s' "$unexplained" >&2
        echo "  Write why after the line ('!<path>  # <reason>'), or drop the line to receive the file, then sync again." >&2
        exit 1
    fi
    candidates="$(printf '%s\n%s\n' "$base_listed" "$own_listed" | sed '/^$/d' | awk '!seen[$0]++')"
else
    candidates="$own_listed"
fi

sync_paths=()
while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$excluded_paths" | grep -xF -- "$p" > /dev/null && continue
    sync_paths+=("$p")
done <<< "$candidates"

if [ "${#sync_paths[@]}" -eq 0 ]; then
    echo "error: no paths to sync (neither the base nor $SYNCED_PATHS_FILE lists any)" >&2
    exit 1
fi

if [ -n "$kept_out" ]; then
    echo "==> kept out of this agent (the base ships them to every agent):"
    printf '%s' "$kept_out"
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
