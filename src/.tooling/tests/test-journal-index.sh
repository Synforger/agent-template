#!/bin/bash
# .tooling/startup/journal_index.py の test。作り物の agent の根に journal を置いて打ち、全文の 1 本の選び方
# (自分のタブの最新・自分の物が無い時)、一覧 (基準より後・自分の物が無い時は前の 2 本・自分から分かれた fork が先頭・
# `tab:` と `pc:` の無い古い物は残す・別の機械の物は外す)、新しさの順、階層の folder の決め方、機械の label の引き方、
# description の 1 文目を、出力の形ごと確かめる。HOME は置き直さず、git も使わない。
#
#   bash .tooling/tests/test-journal-index.sh
set -uo pipefail

TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/startup/journal_index.py"
PYTHON="$(command -v python3)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

check() {
    local name="$1" got="$2" want="$3"
    if [ "${got}" = "${want}" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL ${name}"
        echo "  want: ${want}"
        echo "  got:  ${got}"
    fi
}

# journal を 1 本置く: <根からの journal の folder> <日付> <番号> <欄の行>... (欄の行は frontmatter にそのまま書く)
journal() {
    local folder="${ROOT}/$1/$2" number="$3"
    mkdir -p "${folder}"
    shift 3
    { echo '---'; echo 'type: journal'; printf '%s\n' "$@"; echo '---'; echo; echo '# 本文'; } > "${folder}/session-${number}.md"
}
# 根を作り直す: <名前>
new_root() {
    ROOT="${T}/$1"
    mkdir -p "${ROOT}/journal" "${ROOT}/.tooling/startup"
}
# 根で打つ。外の環境の階層とタブは持ち込まない。所要時間の行と stderr は落とす
run() { (cd "${ROOT}" && env -u AGENT_TIER -u PWA_SID "${PYTHON}" "${TOOL}" "$@" 2>/dev/null) | grep -v '^elapsed: '; }
lines() { printf '%s\n' "$@"; }

# --- 自分のタブの journal が在る時 ---
new_root own
journal journal 2026-01-01 01 'pc: home' 'tab: ses_me' 'description: 古い自分。'
journal journal 2026-01-01 02 'pc: home' 'tab: ses_fork' 'forked_from: ses_me' 'description: 締める前の fork。'
journal journal 2026-01-02 01 'pc: home' 'tab: ses_me' 'description: 今の自分。'
journal journal 2026-01-02 02 'pc: home' 'tab: ses_fork' 'forked_from: ses_me' 'description: fork が決めた事。2 文目は出ない。'
journal journal 2026-01-02 03 'pc: work' 'tab: ses_far' 'description: 別の機械。'
journal journal 2026-01-02 04 'description: 欄の無い古い物。'
journal journal 2026-01-03 01 'pc: home' 'tab: ses_other' 'forked_from: ses_elsewhere' 'description: ほかのタブの fork。'
check "自分の最新を全文にし、後の物を並べる (自分の fork が先頭、別の機械は外し、tab と pc の無い物は残す)" \
    "$(run --tab ses_me --pc home)" \
    "$(lines \
        'journal_full: journal/2026-01-02/session-01.md  (自分のタブの最新)' \
        'journal_others: 3 本 (journal/2026-01-02/session-01.md の後に、同じ階層・同じ機械のほかのタブが書いた物)' \
        '- [fork] 2026-01-02 session-02 ses_fork — fork が決めた事 (journal/2026-01-02/session-02.md)' \
        '- 2026-01-03 session-01 ses_other — ほかのタブの fork (journal/2026-01-03/session-01.md)' \
        '- 2026-01-02 session-04 - — 欄の無い古い物 (journal/2026-01-02/session-04.md)')"
check "後に書いた物が無ければ 0 本" \
    "$(run --tab ses_other --pc home)" \
    "$(lines \
        'journal_full: journal/2026-01-03/session-01.md  (自分のタブの最新)' \
        'journal_others: 0 本 (journal/2026-01-03/session-01.md の後に、同じ階層・同じ機械のほかのタブが書いた物)')"
check "環境変数のタブを読み、--tab が上書きする" \
    "$( (cd "${ROOT}" && env -u AGENT_TIER PWA_SID=ses_other "${PYTHON}" "${TOOL}" --pc home) | head -1
        (cd "${ROOT}" && env -u AGENT_TIER PWA_SID=ses_other "${PYTHON}" "${TOOL}" --pc home --tab ses_me) | head -1)" \
    "$(lines \
        'journal_full: journal/2026-01-03/session-01.md  (自分のタブの最新)' \
        'journal_full: journal/2026-01-02/session-01.md  (自分のタブの最新)')"

# --- 自分の journal が無い時 ---
new_root fresh
journal journal 2026-01-01 01 'pc: home' 'tab: ses_a' 'description: 一番古い。'
journal journal 2026-01-02 01 'pc: home' 'tab: ses_fork' 'forked_from: ses_new' 'description: 締めていないタブの fork。'
journal journal 2026-01-02 02 'tab: ses_b' 'description: pc の無い物。'
journal journal 2026-01-03 01 'pc: home' 'tab: ses_c' 'description: この機械の最新。'
journal journal 2026-01-04 01 'pc: work' 'tab: ses_far' 'description: 別の機械の最新。'
check "自分の物が無ければ、この機械の最新を全文にし、その前の 2 本を並べる" \
    "$(run --tab ses_nobody --pc home)" \
    "$(lines \
        'journal_full: journal/2026-01-03/session-01.md  (自分の journal が無いので階層の最新)' \
        'journal_others: 2 本 (journal/2026-01-03/session-01.md より前の物。自分の journal が無いので直近を出す)' \
        '- 2026-01-02 session-02 ses_b — pc の無い物 (journal/2026-01-02/session-02.md)' \
        '- 2026-01-02 session-01 ses_fork — 締めていないタブの fork (journal/2026-01-02/session-01.md)')"
check "前の 2 本の中でも、自分から分かれた fork が先頭" \
    "$(run --tab ses_new --pc home | sed -n 3p)" \
    '- [fork] 2026-01-02 session-01 ses_fork — 締めていないタブの fork (journal/2026-01-02/session-01.md)'
check "タブの id が無ければ、fork の印は付けない" \
    "$(run --pc home | grep -c '\[fork\]')" "0"
check "機械を替えれば、その機械の最新が全文になる" \
    "$(run --tab ses_nobody --pc work | head -1)" \
    'journal_full: journal/2026-01-04/session-01.md  (自分の journal が無いので階層の最新)'

# --- 新しさの順と、数えない file ---
new_root order
journal journal 2026-01-05 9 'description: 九。'
journal journal 2026-01-05 10 'description: 十。'
journal journal 2026-01-04 11 'description: 前の日。'
journal journal/_archive 2026-02-01 01 'description: 退避。'
journal journal drafts 01 'description: 日付でない folder。'
echo '{}' > "${ROOT}/journal/2026-01-05/session-12-auto-index.jsonl"
echo x > "${ROOT}/journal/2026-01-05/session-13-notes.md"
check "日付、次に番号の数の順で並べ、退避・日付でない folder・journal でない file は数えない" \
    "$(run --pc home)" \
    "$(lines \
        'journal_full: journal/2026-01-05/session-10.md  (自分の journal が無いので階層の最新)' \
        'journal_others: 2 本 (journal/2026-01-05/session-10.md より前の物。自分の journal が無いので直近を出す)' \
        '- 2026-01-05 session-9 - — 九 (journal/2026-01-05/session-9.md)' \
        '- 2026-01-04 session-11 - — 前の日 (journal/2026-01-04/session-11.md)')"

# --- description と欄の読み方 ---
new_root text
journal journal 2026-01-01 01 'tab: ses_me' 'description: 基準。'
journal journal 2026-01-02 01 'tab: {{締めの時の PWA_SID}}' 'forked_from: {{元のタブ}}' 'description: {{一文}}'
journal journal 2026-01-02 02 'tab: "ses_q"' "description: '引用の「止めて。」を受けた (理由。) 話。次の文。'"
journal journal 2026-01-02 03 'description: 句点の無い 1 行'
mkdir -p "${ROOT}/journal/2026-01-02"
echo '# 頭の無い journal' > "${ROOT}/journal/2026-01-02/session-04.md"
check "1 文目は括弧の中の句点で切らず、引用符を外し、雛形のままの欄と無い欄は無い物にする" \
    "$(run --tab ses_me --pc home | tail -n +3)" \
    "$(lines \
        '- 2026-01-02 session-04 - — (description 無し) (journal/2026-01-02/session-04.md)' \
        '- 2026-01-02 session-03 - — 句点の無い 1 行 (journal/2026-01-02/session-03.md)' \
        '- 2026-01-02 session-02 ses_q — 引用の「止めて。」を受けた (理由。) 話 (journal/2026-01-02/session-02.md)' \
        '- 2026-01-02 session-01 - — (description 無し) (journal/2026-01-02/session-01.md)')"

# --- 階層の folder ---
new_root tiers
journal journal 2026-01-01 01 'description: 根。'
journal projects/見本/journal 2026-01-02 01 'description: 親。'
journal projects/見本/subprojects/子/subprojects/孫/journal 2026-01-03 01 'description: 孫。'
mkdir -p "${ROOT}/projects/空"
full_of() { run --pc home "$@" | head -1; }
check "normal は根の journal/" "$(full_of --tier normal)" \
    'journal_full: journal/2026-01-01/session-01.md  (自分の journal が無いので階層の最新)'
check "階層を渡さず環境にも無ければ normal" "$(full_of)" \
    'journal_full: journal/2026-01-01/session-01.md  (自分の journal が無いので階層の最新)'
check "project は <階層>/journal/ (下の段の物は数えない)" "$(run --pc home --tier projects/見本 | head -2)" \
    "$(lines \
        'journal_full: projects/見本/journal/2026-01-02/session-01.md  (自分の journal が無いので階層の最新)' \
        'journal_others: 0 本 (projects/見本/journal/2026-01-02/session-01.md より前の物。自分の journal が無いので直近を出す)')"
check "AGENT_TIER の深い段も同じ形で決まる" \
    "$( (cd "${ROOT}" && env -u PWA_SID AGENT_TIER=projects/見本/subprojects/子/subprojects/孫 "${PYTHON}" "${TOOL}" --pc home) | head -1)" \
    'journal_full: projects/見本/subprojects/子/subprojects/孫/journal/2026-01-03/session-01.md  (自分の journal が無いので階層の最新)'
check "journal の無い階層は - と 0 本" "$(run --pc home --tier projects/空)" \
    "$(lines \
        'journal_full: -  (この階層・この機械の journal が無い)' \
        'journal_others: 0 本 (journal が無い)')"
(cd "${ROOT}" && "${PYTHON}" "${TOOL}" --pc home --tier projects/無い > /dev/null 2>&1)
check "階層の folder が無ければ 2 で終わる" "$?" "2"
(cd "${T}" && "${PYTHON}" "${TOOL}" --pc home --tier normal > /dev/null 2>&1)
check "根でない folder (journal/ が無い) で打てば 2 で終わる" "$?" "2"
check "最後の行は所要時間" \
    "$( (cd "${ROOT}" && "${PYTHON}" "${TOOL}" --pc home --tier normal) | tail -1 | grep -cE '^elapsed: [0-9]+\.[0-9]s$')" "1"

# --- 機械の label (起動の検査と同じ表を、同じ名前で引く) ---
new_root label
journal journal 2026-01-01 01 'pc: home' 'description: 家。'
journal journal 2026-01-02 01 'pc: work' 'description: 会社。'
HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
printf '# コメント\nother-host work\n%s home\n' "${HOST}" > "${ROOT}/.tooling/startup/pc-labels.txt"
check "--pc が無ければ pc-labels.txt の label で絞る" "$(run --tier normal | head -1)" \
    'journal_full: journal/2026-01-01/session-01.md  (自分の journal が無いので階層の最新)'
printf 'other-host home\n' > "${ROOT}/.tooling/startup/pc-labels.txt"
check "表に無い機械は絞らない" "$(run --tier normal | head -1)" \
    'journal_full: journal/2026-01-02/session-01.md  (自分の journal が無いので階層の最新)'
check "絞らない時は stderr に 1 行" \
    "$( (cd "${ROOT}" && "${PYTHON}" "${TOOL}" --tier normal 2>&1 >/dev/null) | grep -c '機械で絞らない')" "1"
rm -f "${ROOT}/.tooling/startup/pc-labels.txt"
check "表の無い根も絞らない" "$(run --tier normal | head -1)" \
    'journal_full: journal/2026-01-02/session-01.md  (自分の journal が無いので階層の最新)'

echo "test-journal-index: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
