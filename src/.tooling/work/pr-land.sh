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
#   0. その番号の PR が今いる folder の repo に無ければ、 待たずに止まる (= 別の repo の中で打った時)
#   1. 検査が 1 つ以上登録され、 全部が終わるまで待つ。 1 つでも落ちていれば止まる (= merge しない)。
#      ただし private の repo で workflow が 1 本も無い時は待たない (= 決まりでは、 private の repo は手元の全体の
#      試験が検査で、 それを流してから打つ)。 公開の repo は Actions の結果で判定するので、 workflow が無ければ止まる。
#      gh が repo の公開・非公開を読めない時は、 待たずに止まる (= 使っている口座がその repo を見られないので、
#      検査も読めず、 待っても必ず時間切れになる)
#   2. merge して、 PR の状態が MERGED になったのを読んで確かめる。 なっていなければ、 gh が最後に出した 1 行を
#      添えて止まる。 GraphQL の口が「Merge already in progress」 と答えた時は、 GitHub の側に処理中の merge が
#      残っていて同じ口では通らないので、 REST の口へ PR の先頭の sha を付けて 1 回だけ頼み直す。
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
visibility="$(gh_ repo view --json visibility -q .visibility)"
workflows="$(gh_ api 'repos/{owner}/{repo}/actions/workflows' -q .total_count)"
if [ -z "${visibility}" ]; then
    stop "gh could not read the repository of #${pr} (not merged). The account it uses may not see this repository:
  run it with GH_TOKEN, or PR_LAND_GH, set to an account that can"
elif [ -z "$(gh_ pr view "${pr}" --json number -q .number)" ]; then
    # 検査を待つ前に確かめる: 無い番号では `gh pr checks` が空を返し続け、 上限まで「検査なし」 で待つ
    stop "this repository ($(gh_ repo view --json nameWithOwner -q .nameWithOwner)) has no #${pr} (not merged).
  Run pr-land inside the repository the PR belongs to"
elif [ "${workflows}" = "0" ] && [ "${visibility}" = "PRIVATE" ]; then
    echo "pr-land: #${pr} is in a private repo with no workflow; its check is the local whole test run, so nothing is awaited"
elif [ "${workflows}" = "0" ] && [ "${visibility}" = "PUBLIC" ]; then
    stop "#${pr} is in a public repo with no workflow; a public repo is judged by its Actions (not merged)"
fi
waited=0
while [ "${workflows}" != "0" ] || [ "${visibility}" != "PRIVATE" ]; do
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
        [ "${verdict}" = "none" ] && stop "no check was ever reported on #${pr} in ${TIMEOUT}s (not merged).
  If a workflow here listens to pull_request and GitHub created no run for this PR at all, GitHub's
  record of which workflow starts on which event is stale for this repository: turn the repository's
  Actions off and on again ('gh api -X PUT repos/{owner}/{repo}/actions/permissions -F enabled=false',
  then the same with '-F enabled=true' and the allowed_actions it had), then push to the PR again"
        stop "the checks on #${pr} did not finish in ${TIMEOUT}s (not merged)"
    fi
    sleep "${INTERVAL}"
    waited=$((waited + INTERVAL + 1))
done

# 2. merge して、 merge されたのを読んで確かめる
read_state() {
    local landed
    landed="$(gh_ pr view "${pr}" --json state,baseRefName,mergeCommit,headRefName,headRefOid -q '.state + " " + .baseRefName + " " + (.mergeCommit.oid // "-") + " " + .headRefOid + " " + .headRefName')"
    read -r state base commit head_at head <<< "${landed}"
    [ "${commit:-}" = "-" ] && commit=""
}
# gh の stderr の最後の 1 行 (= direnv が出す読み込みの行は除く)
last_error_line() { printf '%s\n' "$1" | grep -v 'direnv: ' | sed '/^[[:space:]]*$/d' | tail -n 1; }
merge_args=(pr merge "${pr}" "${how}")
[ "${keep}" -eq 1 ] || merge_args+=(--delete-branch)
merge_err="$("${GH[@]}" "${merge_args[@]}" 2>&1 >/dev/null)"
read_state
if [ "${state:-}" != "MERGED" ] && [[ "${merge_err}" == *"Merge already in progress"* ]] && [ -n "${head_at:-}" ]; then
    echo "pr-land: GitHub answered 'Merge already in progress' on #${pr}; asking again through the REST merge with the head ${head_at:0:7}"
    rest_err="$("${GH[@]}" api -X PUT "repos/{owner}/{repo}/pulls/${pr}/merge" -f merge_method="${how#--}" -f sha="${head_at}" 2>&1 >/dev/null)"
    merge_err="${rest_err:-${merge_err}}"
    read_state
fi
if [ "${state:-}" != "MERGED" ]; then
    said="$(last_error_line "${merge_err}")"
    reason="a conflict, or a rule of the branch"
    [ -n "${said}" ] && reason="gh: ${said#gh: }"
    stop "#${pr} is ${state:-unreadable} after the merge was asked for (${reason}); nothing was tagged"
fi
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
