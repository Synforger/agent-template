#!/bin/bash
set -uo pipefail

# =============================================================================
# synced-paths-check.sh — .synced-paths.txt が src/ の実体と一致しているか検査
# =============================================================================
# `.synced-paths.txt` は sync-from-base / promote-to-base の唯一の真値だが、
# 制御 file 自身は sync 対象外なので、 payload に file を足しても列挙を忘れると
# 誰も気づかないまま「base は出荷しているのに派生に降りない」 が成立する。
# 本 check はその 2 方向を機械検出する:
#
#   A. 死に entry     = 列挙されているが src/ に実体が無い (= 退役時の消し忘れ)
#   B. 宣言漏れ       = src/ に出荷しているのに列挙も除外宣言もされていない
#
# B の判定には「意図的に降ろさない」 の宣言が要る (= `.synced-paths.txt` の
# `!path` 行)。 宣言があるものは B から除外され、 コメントでなく機械が読む形で
# 意図が残る。 判定対象は機構と rule の payload のみ (= 下記 ENFORCED_GLOBS)。
# 雛形 dir (= projects/_template-project/ 等) は dir 単位列挙なので対象外。
#
# 呼び出し元: `task ci`
# Exit code: 0 = clean / 1 = 不一致あり
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT" || { echo "repo root not found: $ROOT" >&2; exit 2; }

SYNCED_PATHS_FILE="$ROOT/.synced-paths.txt"
[ -f "$SYNCED_PATHS_FILE" ] || {
    echo "error: .synced-paths.txt not found at the repo root" >&2
    exit 2
}

# 列挙が必須な payload の範囲 (= 降ろし忘れが実害になるもの)
ENFORCED_GLOBS=(
    "src/.tooling/*.sh"
    "src/.tooling/*.py"
    "src/rules/*.md"
    "src/rules/lazy/*.md"
)

listed=()
excluded=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in
        "!"*) excluded+=("${line#!}") ;;
        *)    listed+=("$line") ;;
    esac
done < "$SYNCED_PATHS_FILE"

fails=0

# ---- A. 死に entry (= 列挙されているが src/ に無い) ----
for p in "${listed[@]}"; do
    if [ ! -e "src/$p" ]; then
        echo "  FAIL: dead entry: $p (listed, but src/$p does not exist)"
        fails=$((fails + 1))
    fi
done

# ---- B. 宣言漏れ (= 出荷しているのに列挙も除外宣言もされていない) ----
in_list() {
    local needle="$1" item
    for item in "${listed[@]}"; do
        [ "$item" = "$needle" ] && return 0
        # dir 単位列挙 (= 末尾 /) は配下を包む
        case "$item" in */) case "$needle" in "$item"*) return 0 ;; esac ;; esac
    done
    for item in "${excluded[@]}"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

for glob in "${ENFORCED_GLOBS[@]}"; do
    for f in $glob; do
        [ -e "$f" ] || continue
        rel="${f#src/}"
        if ! in_list "$rel"; then
            echo "  FAIL: undeclared: $rel (shipped in src/, but neither listed nor declared '!$rel')"
            fails=$((fails + 1))
        fi
    done
done

if [ "$fails" -gt 0 ]; then
    echo ""
    echo "synced-paths-check: $fails problem(s)."
    echo "  dead entry  -> drop the line (the payload retired it)"
    echo "  undeclared  -> list it to ship it, or declare '!<path>  # why' to keep it derivation-owned"
    exit 1
fi

echo "synced-paths-check: clean (${#listed[@]} listed, ${#excluded[@]} declared not-synced)"
exit 0
