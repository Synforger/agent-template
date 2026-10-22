#!/usr/bin/env bash
# audit-known.sh - 番人の週次の深い監査の最新の log を、 既知の台帳と比べて起動の 1 行にする
#
# 週次の監査は、 履歴に残った物を毎週同じ数だけ見つけ続ける (= 消すと決めるまで消えない)。 件数だけを
# 見て毎回「見つかった」 と読み上げると、 同じ報告が全部のタブで繰り返され、 本当に新しく見つかった物が
# その中に埋もれる (= 2026-10-20 の事故は、 新しい物が誰にも届かなかった事だった)。 ここは「前から在る物」 と
# 「今回初めて見えた物」 を分け、 新しい物だけを全部のタブへ届ける。
#
# 比べる単位は 3 つ組 = <repo> <調べた場所> <見つかった語>。 組ごとに件数を持つ。
#   - 調べた場所は log の `fail: <場所>: …` の名前 (= tracked files / git history blob / commit messages /
#     author/committer / tags / GitHub PR/Issue text …)
#   - 語が書かれない行 (= `leak found` / `UNREACHABLE`) は語を `*` とし、 その場所の全部で 1 つの組
#   - 件数は log の `N hit(s)` (= その場所の行の数で、 同じ行の語は同じ件数)。 件数の無い行は `-`
#   - 新規 = 台帳に無い組か、 件数が台帳より増えた組 (= 同じ語が履歴に書き足されたのも、 新しく見つかった物)
#
# 台帳は監査の log と同じ機械の中に置き、 git に入れない (= 中身は会社の repo の path と見つかった語)。
#   台帳: ${AUDIT_KNOWN_FILE:-<番人の監査の記録の置き場>/known-findings.tsv}   1 行 = 3 つ組と件数 (タブ区切り)
#   件数の列が無い古い行は、 件数を比べない (= 同じ log を adopt し直すと件数が入る)
#   log : ${AUDIT_LOG_DIR:-<番人の監査の記録の置き場>}/weekly-audit-*.log (= 置き場は guard_place audit-logs)
#
# 使い方:
#   audit-known.sh status                           起動の検査の 1 行 (= startup-status.sh が呼ぶ)
#   audit-known.sh adopt <log>                      その log の 3 つ組を全部、 その件数で既知にする (= 足す口。 運用者が決めた時だけ)
#   audit-known.sh forget <repo> [<場所> [<語>]]    履歴から消すと決めた物を台帳から外す (= 次の監査で出たら新規)
#   audit-known.sh list                             台帳の中身
#
# log の repo の見出しに境界 (= `, area <名前>`) が書かれた回からは、 台帳と比べずに audit_findings.py へ渡す
# (= 番人が既知を除いて書き、 新しい漏れはその境界を読めるタブにだけ出る。 出し方はその file の頭書き)。
# 台帳の比べ方は、 境界の無い log の間のつなぎ。
#
# status の出し方 (= 境界の無い log。 階層は環境変数 AGENT_TIER。 無い時は normal として扱う):
#   weekly_audit: NEW in N repo(s) …       台帳に無い組が在る。 全部のタブに出し、 続く行に repo と見つかった物
#   weekly_audit: known only (N repo(s) …) 既知だけ。 normal のタブにだけ 1 行
#   weekly_audit: STALE / NO RUN / clean   今までどおり
#   weekly_audit: INCOMPLETE (…)          一番新しい log に終わりの行が無い (= 走っている最中か、 途中で止まった)。
#                                         続く行は、 終わりの行を持つ一番新しい log で判定した物

set -uo pipefail
export LC_ALL=C

source "$(dirname "${BASH_SOURCE[0]}")/../lib/guard-place.sh"
AUDIT_DIR="${AUDIT_LOG_DIR:-$(guard_place audit-logs)}"
LEDGER="${AUDIT_KNOWN_FILE:-$AUDIT_DIR/known-findings.tsv}"
TAB=$'\t'
STALE_DAYS=7

# parse_log <log> : log の 3 つ組と件数を 1 行ずつ (repo, 場所, 語, 件数)、 並べて重複を除く。
#   `--- <repo> (…) ---` が repo の始まり、 `--- <repo>: FINDINGS ---` が終わり。 終わりで組が 1 つも
#   無い repo は読み解けていないので (repo, ?, *) を出す (= log の書式が変わっても黙って消えない)
parse_log() {
    awk -v TAB="$TAB" '
        /^--- .* \(.*\) ---$/ { repo = $0; sub(/^--- /, "", repo); sub(/ \(.*\) ---$/, "", repo); n = 0; next }
        /^--- .*: (clean|FINDINGS) ---$/ {
            if ($0 ~ /: FINDINGS ---$/ && n == 0) {
                r = $0; sub(/^--- /, "", r); sub(/: FINDINGS ---$/, "", r); print r TAB "?" TAB "*" TAB "-"
            }
            repo = ""; next
        }
        repo != "" && /^fail: / {
            line = substr($0, 7)
            if (line ~ /^deep audit: /) next
            i = index(line, ": "); if (i == 0) next
            src = substr(line, 1, i - 1); rest = substr(line, i + 2)
            if (match(rest, /^[0-9]+ hit\(s\) = /)) {
                hits = substr(rest, 1, index(rest, " ") - 1)
                m = split(substr(rest, RLENGTH + 1), w, " ")
                for (k = 1; k <= m; k++) { print repo TAB src TAB w[k] TAB hits; n++ }
            } else {
                print repo TAB src TAB "*" TAB "-"; n++
            }
        }
    ' "$1" | sort -u
}

# ledger_rows : 台帳の組 (= 並べて重複を除く)。 台帳が無ければ空
ledger_rows() { [ -f "$LEDGER" ] && grep -v -e '^#' -e '^$' "$LEDGER" | sort -u; return 0; }

write_ledger() {
    local tmp
    mkdir -p "$(dirname "$LEDGER")"
    tmp="$(mktemp "$LEDGER.XXXXXX")" || return 1
    {
        printf '# 週次の監査で見つかり、 既知にした物 (= repo, 調べた場所, 語, 件数)。 手で書かない (= audit-known.sh の adopt / forget)\n'
        cat
    } > "$tmp" && mv "$tmp" "$LEDGER"
}

# unknown_rows <log の組> : 台帳に無い組と、 件数が台帳より増えた場所の組。 件数は場所の行の物なので、
#   増えた場所には 5 列目に台帳の件数を付け、 その場所に新しい語が在ればその語だけを出す (= 既知の語は読み上げない)
unknown_rows() {
    awk -F"$TAB" -v OFS="$TAB" '
        FILENAME == ARGV[1] { held[$1 OFS $2 OFS $3] = 1; if (NF >= 4 && $4 ~ /^[0-9]+$/) was[$1 OFS $2] = $4; next }
        { place = $1 OFS $2; key = place OFS $3; row[++n] = $0; pl[n] = place; known[n] = (key in held)
          if (!known[n]) fresh[place] = 1
          if ((place in was) && $4 ~ /^[0-9]+$/ && $4 + 0 > was[place] + 0) grew[place] = was[place] }
        END { for (i = 1; i <= n; i++) {
                  p = pl[i]
                  if (known[i] && (!(p in grew) || (p in fresh))) continue
                  print row[i] ((p in grew) ? OFS grew[p] : "") } }
    ' <(ledger_rows) <(printf '%s\n' "$1")
}

latest_log() { ls -t "$AUDIT_DIR"/weekly-audit-*.log 2>/dev/null | head -1; }
# 終わりの行 (= `=== done: N repo(s) with findings ===`) を持つ一番新しい log。 走っている最中と、
#   途中で止まった log は終わりの行を持たない
finished_log() {
    local log
    while IFS= read -r log; do
        if grep -qE '^=== done: [0-9]+ repo' "$log"; then printf '%s\n' "$log"; return; fi
    done < <(ls -t "$AUDIT_DIR"/weekly-audit-*.log 2>/dev/null)
}
age_days() { echo $(( ( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1") ) / 86400 )); }

cmd_status() {
    local last newest n age rows new tier nrepo_new
    newest="$(latest_log)"
    if [ -z "$newest" ]; then echo "weekly_audit: NO RUN (no log in $AUDIT_DIR)"; return; fi
    last="$(finished_log)"
    # 終わりの行の無い log を 0 件と読むと、 一つ前の本物の結果が「clean」 に隠れる
    if [ "$newest" != "$last" ]; then
        echo "weekly_audit: INCOMPLETE ($(basename "$newest") has no end line, $(age_days "$newest")d old: running, or stopped half way) -> the lines below are from the last finished run"
    fi
    if [ -z "$last" ]; then echo "weekly_audit: NO RUN (no finished log in $AUDIT_DIR)"; return; fi
    n="$(grep -oE 'done: [0-9]+ repo' "$last" | grep -oE '[0-9]+' | tail -1)"
    age="$(age_days "$last")"
    if [ -z "$n" ] || [ "$n" -eq 0 ]; then
        if [ "$age" -gt "$STALE_DAYS" ]; then
            echo "weekly_audit: STALE (last run ${age}d ago: $(basename "$last"))"
        else
            echo "weekly_audit: clean ($(basename "$last"), ${age}d ago)"
        fi
        return
    fi

    # 見出しに境界が書かれた log は、 番人が既知を除いて書いている: 台帳と比べず、 境界でタブに分ける
    if grep -qE '^--- .* \((.*, )?area [^,)]+\) ---$' "$last"; then
        python3 "$(dirname "${BASH_SOURCE[0]}")/audit_findings.py" "$last" "$age"
        return
    fi
    # TODO: 境界つきの log が出たら、 ここから下の台帳の比べ方と adopt / forget / list を外し、 この file を退役する
    rows="$(parse_log "$last")"
    # 数が合わない = log の読み方が外れている。 既知で黙らせず、 新規として log を読ませる
    if [ "$(cut -f1 <<< "$rows" | sort -u | grep -c .)" -ne "$n" ]; then
        echo "weekly_audit: NEW in $n repo(s) ($(basename "$last"), ${age}d ago, log not parsed) -> read the FINDINGS blocks of that log"
        return
    fi
    new="$(unknown_rows "$rows")"
    nrepo_new="$(cut -f1 <<< "$new" | sort -u | grep -c .)"
    if [ -n "$new" ]; then
        echo "weekly_audit: NEW in $nrepo_new repo(s) ($(basename "$last"), ${age}d ago; $((n - nrepo_new)) other repo(s) with only known findings, not shown) -> say it first in the briefing"
        # 件数が増えた場所は語の後に (hits <台帳> -> <今回>)
        awk -F"$TAB" '
            function close_src() { if (more != "") line = line " (hits " more ")"; more = "" }
            { if ($1 != cur) { close_src(); if (cur != "") print line; cur = $1; line = "  new: " $1 " -> " $2 ": " $3 }
              else if ($2 != src) { close_src(); line = line "; " $2 ": " $3 } else { line = line " " $3 }
              src = $2; if (NF >= 5) more = $5 " -> " $4 }
            END { close_src(); if (cur != "") print line }
        ' <<< "$new"
        return
    fi
    tier="${AGENT_TIER:-normal}"
    if [ "$tier" = "normal" ]; then
        echo "weekly_audit: known only ($n repo(s), $(basename "$last"), ${age}d ago; nothing new, see $last)"
    fi
}

cmd_adopt() {
    local log="${1:-}" rows
    [ -f "$log" ] || { echo "usage: audit-known.sh adopt <log>   (log not found: $log)" >&2; return 2; }
    rows="$(parse_log "$log")"
    [ -n "$rows" ] || { echo "adopt: no finding in $log, nothing to add" >&2; return 1; }
    # 同じ組の台帳の行 (= 古い件数・件数の無い行) は、 この log の行で置き換える
    awk -F"$TAB" -v OFS="$TAB" '
        FNR == NR { fresh[$1 OFS $2 OFS $3] = 1; print; next }
        !(($1 OFS $2 OFS $3) in fresh)
    ' <(printf '%s\n' "$rows") <(ledger_rows) | sort -u | write_ledger || return 1
    echo "adopt: $(printf '%s\n' "$rows" | wc -l | tr -d ' ') finding(s) of $(basename "$log") are known now ($LEDGER)"
}

cmd_forget() {
    local repo="${1:-}" src="${2:-}" word="${3:-}" kept removed total
    [ -n "$repo" ] || { echo "usage: audit-known.sh forget <repo> [<source> [<word>]]" >&2; return 2; }
    total="$(ledger_rows | grep -c .)"
    kept="$(ledger_rows | awk -F"$TAB" -v repo="$repo" -v src="$src" -v word="$word" '
        { r = ($1 == repo || (length($1) > length(repo) && substr($1, length($1) - length(repo)) == "/" repo))
          if (r && (src == "" || $2 == src) && (word == "" || $3 == word)) next
          print }
    ')"
    removed=$(( total - $(printf '%s' "$kept" | grep -c .) ))
    if [ "$removed" -eq 0 ]; then echo "forget: nothing in the ledger matches ($repo ${src} ${word})" >&2; return 1; fi
    { [ -z "$kept" ] || printf '%s\n' "$kept"; } | write_ledger || return 1
    echo "forget: removed $removed finding(s) (a later audit that finds them again reports them as NEW)"
}

case "${1:-}" in
    status) cmd_status ;;
    adopt)  shift; cmd_adopt "$@" ;;
    forget) shift; cmd_forget "$@" ;;
    list)   ledger_rows ;;
    *) echo "usage: audit-known.sh status | adopt <log> | forget <repo> [<source> [<word>]] | list" >&2; exit 2 ;;
esac
