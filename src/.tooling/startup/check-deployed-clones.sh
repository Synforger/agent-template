#!/usr/bin/env bash
# check-deployed-clones.sh - この機械が手元の clone から配備している repo が、 origin より遅れていないか
#
# 手元の clone から何かを配備している機械 (= その clone で build した画面を配る、 その clone の script を
# 常駐させる) は、 直しが merge された後も、 取り込んで配備し直すまで古い版を動かし続ける。 動いている物の
# 側にはそれを言う物が無いので、 起動のたびにここで数える。
#
# 派生は「この機械で、 手元の clone から配備している repo」 を `.tooling/startup/deployed-clones.txt` に
# 1 行ずつ宣言する (= 書き方 = `deployed-clones.example.txt`)。 宣言された clone ごとに、 追う branch の
# origin に在って clone の HEAD にまだ無い commit を数え、 1 行で出す:
#
#   clone_deploy(<名前>): ok (HEAD has origin/<branch> <sha>)
#   clone_deploy(<名前>): BEHIND <n> commit(s) vs origin/<branch> (<sha> <subject>)
#   clone_deploy(<名前>): UNKNOWN (<理由>)
#
# 数えるだけで取り込まない (= fetch は remote 追跡 ref しか動かさず、 作業木にも HEAD にも触らない)。
# fetch できない時は手元の origin/<branch> と比べ、 そう名乗る。 宣言の file が無い派生では何も出さない。
# 配備した file の中身までは比べない (= 取り込んだ後の build / 再起動の済み具合は、 その repo の配備の手順が持つ)。
#
# 走らせ方: bash .tooling/startup/check-deployed-clones.sh   (= startup-status.sh が呼ぶ)
# 宣言の file は DEPLOYED_CLONES_FILE で差し替えられる (= test が使う)。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="${DEPLOYED_CLONES_FILE:-$ROOT/.tooling/startup/deployed-clones.txt}"
[ -f "$FILE" ] || exit 0

# fetch を待つ上限 (= 秒)。 回線が無い時に起動を待たせない。 timeout が在る環境だけ上限を掛ける
FETCH_TIMEOUT_S=8
_to=""
command -v timeout >/dev/null 2>&1 && _to="timeout $FETCH_TIMEOUT_S"

while read -r name clone branch _rest || [ -n "${name:-}" ]; do
    case "${name:-}" in ''|'#'*) continue ;; esac
    if [ -z "${clone:-}" ] || [ -z "${branch:-}" ]; then
        echo "clone_deploy($name): UNKNOWN (the line needs <name> <clone path> <branch>)"
        continue
    fi
    shown="$clone"
    case "$clone" in '~'|'~/'*) clone="$HOME${clone#\~}" ;; esac
    if ! git -C "$clone" rev-parse --git-dir >/dev/null 2>&1; then
        echo "clone_deploy($name): UNKNOWN (no clone at $shown)"
        continue
    fi
    note=""
    # shellcheck disable=SC2086  # $_to は「timeout 8」 の 2 語か空
    $_to git -C "$clone" fetch --quiet origin "$branch" 2>/dev/null \
        || note=" (not fetched: compared with the last known origin/$branch)"
    if ! git -C "$clone" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
        echo "clone_deploy($name): UNKNOWN (no origin/$branch in $shown)"
        continue
    fi
    behind="$(git -C "$clone" rev-list --count "HEAD..refs/remotes/origin/$branch" 2>/dev/null || true)"
    tip="$(git -C "$clone" log -1 --format='%h %s' "refs/remotes/origin/$branch" 2>/dev/null | cut -c1-80)"
    if [ -z "$behind" ]; then
        echo "clone_deploy($name): UNKNOWN (could not compare HEAD with origin/$branch in $shown)${note}"
    elif [ "$behind" -gt 0 ]; then
        echo "clone_deploy($name): BEHIND $behind commit(s) vs origin/$branch (${tip})${note}"
    else
        echo "clone_deploy($name): ok (HEAD has origin/$branch ${tip%% *})${note}"
    fi
done < "$FILE"
