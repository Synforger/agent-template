#!/bin/bash
# =============================================================================
# pr-land.sh — PR を、 検査が通ったのを確かめてから merge し、 merge されたのを確かめてから tag を打つ
# =============================================================================
#   bash <エージェントの folder>/.tooling/work/pr-land.sh <PR 番号> [--squash|--merge] [--tag <名前>] [--keep-branch]
#   (= その PR の repo の中で打つ。 型へ上げた PR なら型の worktree の中。 merge の仕方の既定は --squash)
#
# 何のために在るか (= 手で続けて打って 2 種類の誤りが出た):
#   - 検査の結果を見ないまま merge した。 PR を作った直後は検査がまだ 1 つも登録されておらず、
#     `gh pr checks --watch` は「検査なし」 で即座に戻る。 続けて打った merge がそのまま通る
#   - merge されていないのに tag を打った。 merge が衝突で止まっても、 続けて打った tag は古い main に付く
#
# やること:
#   1. 検査が 1 つ以上登録され、 全部が終わるまで待つ。 1 つでも落ちていれば止まる (= merge しない)
#   2. merge して、 PR の状態が MERGED になったのを読んで確かめる。 なっていなければ止まる。
#      元の branch が remote に残っていれば消す (= `gh pr merge --delete-branch` は、 その branch が別の
#      作業場所で開かれている時や repo の設定によって、 何も言わずに残すことがある)
#   3. --tag が在れば、 その PR の merge commit に tag を打って push する (= 2 が通った時だけ)
#
# 終了コード: 0 = 着地した / 1 = 止まった (= 理由を 1 行) / 2 = 使い方の誤り
# 調整 (= 環境変数): PR_LAND_TIMEOUT (= 検査を待つ上限の秒、 既定 900) / PR_LAND_INTERVAL (= 見に行く間隔の秒、 既定 10)
#   PR_LAND_GH (= gh の代わりに呼ぶコマンド。 既定は、 direnv が効く場所なら `direnv exec . gh`、 でなければ `gh`)
# =============================================================================
set -uo pipefail

usage() { echo "usage: pr-land.sh <PR number> [--squash|--merge] [--tag <name>] [--keep-branch]" >&2; exit 2; }
how="--squash"; tag=""; keep=0; pr=""
while [ $# -gt 0 ]; do
    case "$1" in
        --squash|--merge) how="$1" ;;
        --tag) [ -n "${2:-}" ] || usage; tag="$2"; shift ;;
        --keep-branch) keep=1 ;;
        [0-9]*) pr="$1" ;;
        *) usage ;;
    esac
    shift
done
[ -n "${pr}" ] || usage

TIMEOUT="${PR_LAND_TIMEOUT:-900}"
INTERVAL="${PR_LAND_INTERVAL:-10}"
if [ -n "${PR_LAND_GH:-}" ]; then
    read -r -a GH <<< "${PR_LAND_GH}"
elif command -v direnv >/dev/null 2>&1 && direnv exec . true >/dev/null 2>&1; then
    GH=(direnv exec . gh)      # path で決まる認証を使う (= 素の gh は別の口座のことがある)
else
    GH=(gh)
fi
gh_() { "${GH[@]}" "$@" 2>/dev/null; }
stop() { echo "pr-land: stopped — $1" >&2; exit 1; }

# 1. 検査: 1 つ以上在って、 全部終わるまで待つ
waited=0
while :; do
    verdict="$(gh_ pr checks "${pr}" --json name,bucket | python3 -c '
import json, sys
try:
    checks = json.load(sys.stdin)
except ValueError:
    checks = []
buckets = [c.get("bucket") for c in checks]
bad = [c.get("name", "?") for c in checks if c.get("bucket") in ("fail", "cancel")]
if bad:
    print("fail " + ", ".join(bad))
elif not buckets:
    print("none")
elif "pending" in buckets:
    print("pending")
else:
    print("pass %d" % len(buckets))
')"
    case "${verdict}" in
        pass*) echo "pr-land: #${pr} checks passed (${verdict#pass })"; break ;;
        fail*) stop "a check failed on #${pr}: ${verdict#fail } (not merged)" ;;
    esac
    if [ "${waited}" -ge "${TIMEOUT}" ]; then
        [ "${verdict}" = "none" ] && stop "no check was ever reported on #${pr} in ${TIMEOUT}s (not merged)"
        stop "the checks on #${pr} did not finish in ${TIMEOUT}s (not merged)"
    fi
    sleep "${INTERVAL}"
    waited=$((waited + INTERVAL + 1))
done

# 2. merge して、 merge されたのを読んで確かめる
if [ "${keep}" -eq 1 ]; then
    gh_ pr merge "${pr}" "${how}" >/dev/null
else
    gh_ pr merge "${pr}" "${how}" --delete-branch >/dev/null
fi
landed="$(gh_ pr view "${pr}" --json state,baseRefName,mergeCommit,headRefName,headRefOid -q '.state + " " + .baseRefName + " " + (.mergeCommit.oid // "-") + " " + .headRefOid + " " + .headRefName')"
read -r state base commit head_at head <<< "${landed}"
[ "${commit:-}" = "-" ] && commit=""
[ "${state:-}" = "MERGED" ] || stop "#${pr} is ${state:-unreadable} after the merge was asked for (a conflict, or a rule of the branch); nothing was tagged"
echo "pr-land: #${pr} merged into ${base} (${commit:0:7})"
if [ "${keep}" -eq 0 ] && [ -n "${head:-}" ]; then
    # 残っている元の branch は、 PR の先頭と同じ commit を指している時だけ消す (= 後から積まれた物は残す)
    left="$(git ls-remote --heads origin "${head}" 2>/dev/null | cut -f1)"
    if [ -n "${left}" ] && [ "${left}" = "${head_at}" ]; then
        git push -q origin --delete "${head}" 2>/dev/null && echo "pr-land: removed the merged branch ${head} from origin"
    elif [ -n "${left}" ]; then
        echo "pr-land: ${head} is still on origin and has moved since the PR (left alone)"
    fi
fi

# 3. tag は、 merge された commit にだけ打つ
if [ -n "${tag}" ]; then
    [ -n "${commit:-}" ] || stop "#${pr} is merged but names no merge commit; ${tag} was not placed"
    git fetch -q origin "${base}" || stop "could not fetch ${base}; ${tag} was not placed"
    git cat-file -e "${commit}^{commit}" 2>/dev/null || stop "the merge commit ${commit:0:7} is not here after the fetch; ${tag} was not placed"
    git tag "${tag}" "${commit}" || stop "could not place ${tag}"
    git push -q origin "${tag}" || stop "${tag} is placed here but was not pushed"
    echo "pr-land: ${tag} placed on ${commit:0:7} and pushed"
fi
