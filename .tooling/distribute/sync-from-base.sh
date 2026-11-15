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
#   BASE_BRANCH    : base branch (default: develop。 base の新しい物は develop に入り、 main は release の時だけ進む)
#   SYNC_OVERWRITE : 1 にすると、 派生だけが変えた file を名指した上で base の版で上書きして進む
#
# 動作:
#   1. base を tmpdir に clone (or BASE_REPO_PATH を直参照)
#   2. 写す path を決める: base の .synced-paths.txt が列挙する path と、 派生の .synced-paths.txt が列挙する
#      path を合わせ、 派生が `!` で外した path を引く (= 何を降ろすかの真値は base の宣言 1 本。 派生の file は
#      外す物と、 自分だけが足す物を書く。 base が後から足した file は、 派生が何もしなくても次の取り込みで降りる)
#   3. base が列挙する path を、 理由 (= `!<path>  # <理由>`) の無い `!` で外していれば、 その行を名指して
#      何も写さずに止まる (= 共通の物を黙って外したままにしない)。 外している物は毎回、 理由つきで並べて出す
#   4. 前の取り込みの base の版 (= 派生の .synced-paths.txt の `# synced from base: <sha>` の行) と比べ、
#      その後に派生だけが変えた・足した・消した file があれば、 名指して何も写さずに止まる
#      (= 上書きで派生の直しが黙って消えるのを止める。 base へ上げるか、 `!` で外すか、 SYNC_OVERWRITE=1 で捨てる)
#   5. base/src/<path> → 派生/<path> に上書きし、 今の base の版を `# synced from base:` の行に書く
#   6. 派生の docs-check を流し、 FAIL があれば commit の案内を出さずに exit 1
#   7. 写した path を名指す commit の案内を出す (= 同じ repo の別の作業の stage を拾わない。 一覧は .git の中の file)
#
# base が .synced-paths.txt を持たない時は、 派生の列挙だけを写す。
# base が git の repo でない時 (= 開発時の BASE_REPO_PATH) は、 4 の比べと 5 の版の記録をしない
#
# この file は sync 自身を運べないので (= init で一度だけ届く)、 判定も shell の中に置く
# (= 別の file に出すと、 その file を運ぶ口が無い)
# =============================================================================

DEFAULT_BASE_URL="${BASE_REPO_URL:-git@github.com:synforger/agent-template.git}"
BASE_BRANCH="${BASE_BRANCH:-develop}"
RECORD_PREFIX="# synced from base: "

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

SYNCED_PATHS_FILE="$AGENT_DIR/.synced-paths.txt"
if [ ! -f "$SYNCED_PATHS_FILE" ]; then
    echo "error: $SYNCED_PATHS_FILE not found" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap "rm -rf '$WORK_DIR'" EXIT

# base を確保。 clone は履歴を持つ (= 前の取り込みの版の木と比べるため) が、 中身は今の版の分だけ取る
if [ -n "${BASE_REPO_PATH:-}" ]; then
    BASE_DIR="$BASE_REPO_PATH"
    if [ ! -d "$BASE_DIR" ]; then
        echo "error: BASE_REPO_PATH=$BASE_DIR does not exist" >&2
        exit 1
    fi
    echo "==> using local base: $BASE_DIR"
else
    BASE_DIR="$WORK_DIR/agent-template"
    echo "==> clone $DEFAULT_BASE_URL ($BASE_BRANCH) → $BASE_DIR"
    git clone --quiet --filter=blob:none --branch="$BASE_BRANCH" "$DEFAULT_BASE_URL" "$BASE_DIR"
fi

# .synced-paths.txt の宣言を 1 行ずつ出す (= 1 行 1 path、 # コメント / 空行 skip、 `!` prefix はそのまま)
declarations() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [ -n "$line" ]; then printf '%s\n' "$line"; fi
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

# --- 前の取り込みの後に、 派生だけが変えた file ------------------------------------------------

# 標準入力の相対 path のうち <root> の下に file として在る物を「path<TAB>blob」 で出す
# (= blob は <repo> で `git hash-object` した値で、 ls-tree の blob と同じ物差し)
blob_hashes() { # <root> <repo>
    local root="$1" repo="$2" f
    : > "$WORK_DIR/exist"
    while IFS= read -r f; do
        if [ -f "$root/$f" ]; then printf '%s\n' "$f" >> "$WORK_DIR/exist"; fi
    done
    if [ -s "$WORK_DIR/exist" ]; then
        while IFS= read -r f; do printf '%s/%s\n' "$root" "$f"; done < "$WORK_DIR/exist" \
            | git -C "$repo" hash-object --stdin-paths | paste "$WORK_DIR/exist" -
    fi
}

base_is_git=0
if git -C "$BASE_DIR" rev-parse --git-dir > /dev/null 2>&1; then base_is_git=1; fi
recorded="$(sed -n "s/^${RECORD_PREFIX}\([0-9a-f]\{40\}\)\$/\1/p" "$SYNCED_PATHS_FILE" | head -1)"

if [ "$base_is_git" -eq 1 ] && [ -z "$recorded" ]; then
    echo "note: $SYNCED_PATHS_FILE has no record of the last sync, so changes made only in this agent cannot be told apart this time. This sync writes the record."
elif [ "$base_is_git" -eq 1 ] && ! git -C "$BASE_DIR" cat-file -e "${recorded}^{commit}" 2> /dev/null; then
    echo "note: the base no longer has the last synced version ${recorded:0:7}, so changes made only in this agent cannot be told apart this time. This sync writes a new record."
    recorded=""
fi

if [ "$base_is_git" -eq 1 ] && [ -n "$recorded" ]; then
    git -C "$BASE_DIR" ls-tree -r --full-tree "$recorded" -- src/ \
        | awk -F'\t' '{ split($1, meta, " "); sub(/^src\//, "", $2); print $2 "\t" meta[3] }' > "$WORK_DIR/recorded.tsv"
    : > "$WORK_DIR/files.raw"
    for p in "${sync_paths[@]}"; do
        if [ -d "$BASE_DIR/src/$p" ] || [[ "$p" == */ ]]; then
            # folder は rsync --delete で丸ごと揃うので、 3 つの側の file を全部見る
            prefix="${p%/}/"
            awk -F'\t' -v pre="$prefix" 'index($1, pre) == 1 { print $1 }' "$WORK_DIR/recorded.tsv" >> "$WORK_DIR/files.raw"
            if [ -d "$BASE_DIR/src/$prefix" ]; then
                (cd "$BASE_DIR/src" && find "${prefix%/}" -type f) >> "$WORK_DIR/files.raw"
            fi
            git -C "$AGENT_DIR" ls-files --cached --others --exclude-standard -- "$prefix" >> "$WORK_DIR/files.raw"
        elif [ -f "$BASE_DIR/src/$p" ]; then
            # base に無い単体の path は写さないので、 派生の側を見る必要が無い
            printf '%s\n' "$p" >> "$WORK_DIR/files.raw"
        fi
    done
    awk '!seen[$0]++' "$WORK_DIR/files.raw" > "$WORK_DIR/files"
    blob_hashes "$BASE_DIR/src" "$BASE_DIR" < "$WORK_DIR/files" > "$WORK_DIR/base.tsv"
    blob_hashes "$AGENT_DIR" "$AGENT_DIR" < "$WORK_DIR/files" > "$WORK_DIR/agent.tsv"
    # 派生の版が base の今の版とも前の取り込みの版とも違う file だけを出す。
    # base が前の取り込みから変えていなければ、 派生だけが変えた物
    awk -F'\t' '
        FILENAME == ARGV[1] { rec[$1] = $2; next }
        FILENAME == ARGV[2] { now[$1] = $2; next }
        FILENAME == ARGV[3] { here[$1] = $2; next }
        {
            f = $1
            r = (f in rec) ? rec[f] : "-"
            n = (f in now) ? now[f] : "-"
            d = (f in here) ? here[f] : "-"
            if (d == n || d == r) next
            if (r != n) kind = "changed here and in the base"
            else if (d == "-") kind = "deleted here"
            else if (r == "-") kind = "added here"
            else kind = "changed here"
            printf "    %-30s %s\n", kind, f
        }' "$WORK_DIR/recorded.tsv" "$WORK_DIR/base.tsv" "$WORK_DIR/agent.tsv" "$WORK_DIR/files" > "$WORK_DIR/local-changes"
    if [ -s "$WORK_DIR/local-changes" ]; then
        if [ "${SYNC_OVERWRITE:-0}" = "1" ]; then
            echo "==> SYNC_OVERWRITE=1: these changes made in this agent since the last sync (${recorded:0:7}) are replaced by the base:"
            cat "$WORK_DIR/local-changes"
        else
            echo "error: files changed in this agent since the last sync (base ${recorded:0:7}) — nothing was synced:" >&2
            cat "$WORK_DIR/local-changes" >&2
            echo "  For each: promote it to the base (promote-to-base.sh --file <path>; merge by hand first when the base changed it too)," >&2
            echo "  keep this agent's own copy with '!<path>  # <reason>' in .synced-paths.txt," >&2
            echo "  or drop the change and sync again with SYNC_OVERWRITE=1." >&2
            exit 1
        fi
    fi
fi

# --- 写す ---------------------------------------------------------------------------------

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

# 今の base の版を記録する。 base に commit していない変更があると、 その版の木と写した中身が食い違うので書かない
if [ "$base_is_git" -eq 1 ]; then
    if [ -n "$(git -C "$BASE_DIR" status --porcelain -- src .synced-paths.txt)" ]; then
        echo "note: the base has uncommitted changes, so the record of this sync is not written."
    else
        current="$(git -C "$BASE_DIR" rev-parse HEAD)"
        grep -v "^${RECORD_PREFIX}" "$SYNCED_PATHS_FILE" > "$WORK_DIR/synced-paths.new" || true
        printf '%s%s\n' "$RECORD_PREFIX" "$current" >> "$WORK_DIR/synced-paths.new"
        cat "$WORK_DIR/synced-paths.new" > "$SYNCED_PATHS_FILE"
    fi
fi

echo ""
echo "==> changes:"
cd "$AGENT_DIR"
git status --short -- .synced-paths.txt "${sync_paths[@]}" || true

echo ""
if [ "${#missing_paths[@]}" -gt 0 ]; then
    echo "! ${#missing_paths[@]} listed path(s) do not exist in base — nothing was synced for them:"
    for p in "${missing_paths[@]}"; do
        echo "    - $p"
    done
    echo "  Either the base retired them (drop the line from .synced-paths.txt),"
    echo "  or your .synced-paths.txt is ahead of the base you synced from."
    echo ""
fi

# 赤のまま commit しないよう、 案内の前に派生の docs-check を通す
DOCS_CHECK="$AGENT_DIR/.tooling/docs-check/docs-check.sh"
if [ -f "$DOCS_CHECK" ]; then
    echo "==> docs-check"
    if ! bash "$DOCS_CHECK" > "$WORK_DIR/docs-check.out" 2>&1; then
        sed -e $'s/\033\\[[0-9;]*m//g' "$WORK_DIR/docs-check.out" | grep -E '^ *FAIL' || true
        echo ""
        echo "✗ synced, but docs-check fails on the result. Fix the FAIL lines above, run docs-check again, then commit."
        exit 1
    fi
    echo "  docs-check passed"
    echo ""
fi

if [ "${#missing_paths[@]}" -gt 0 ]; then
    echo "✓ sync complete with ${#missing_paths[@]} skipped. Review with 'git diff', then commit the synced paths:"
else
    echo "✓ sync complete. Review with 'git diff', then commit the synced paths:"
fi
# 写した path の一覧は .git の中に置き、 案内の行を短く保つ (= git の外の作業の folder を汚さない)
pathspec="$(git rev-parse --git-path sync-from-base.pathspec)"
printf '%s\n' .synced-paths.txt "${sync_paths[@]}" > "$pathspec"
echo "  git add -A --pathspec-from-file=$pathspec && git commit -m 'chore: sync from agent-template' --pathspec-from-file=$pathspec"
echo ""
echo "if a derived-side change was overwritten, revert it individually:"
echo "  git checkout HEAD -- <path>"
