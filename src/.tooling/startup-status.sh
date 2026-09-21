#!/usr/bin/env bash
# startup-status.sh - セッション起動時の状態スナップショット (= LLM 不使用、 token ゼロ)
# 用途: Phase B-共通 で実行、 各 utility を summary モードで呼んで結果を 1 ブロックで出力
# エージェント は出力を Read して「打診すべき項目があれば 1 行打診」 を Phase C で判断
# 走らせ方: bash <agent-repo-root>/.tooling/startup-status.sh

set -uo pipefail
# 自分がどれだけ待たせたかを最後に名乗る (= 遅くなったことに気づけるのは数字が出ている時だけ)
_T0="${EPOCHREALTIME:-$(date +%s)}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "ROOT not found: $ROOT"; exit 2; }

echo "===== agent startup status ($(date '+%Y-%m-%d %H:%M:%S')) ====="

# 0. PC 識別 (= 自宅 / 会社、 LocalHostName → label mapping)
PC_LABELS_FILE="$ROOT/.tooling/pc-labels.txt"
local_host=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
pc_label=""
if [ -f "$PC_LABELS_FILE" ]; then
    pc_label=$(grep -v '^#' "$PC_LABELS_FILE" | grep -v '^$' | awk -v h="$local_host" '$1 == h { print $2; exit }')
fi
if [ -n "$pc_label" ]; then
    echo "PC: $pc_label ($local_host)"
else
    echo "PC: unknown ($local_host) — add it to .tooling/pc-labels.txt"
fi

# 以降の検出は互いに独立なので同時に走らせ、 出力は元の並び順で組み直す
# (= 直列だと一番遅い 1 本の裏で残り全部が待つだけになる)。
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# 1. rule 形骸化検出 (= 7 日無更新 = 退役候補)
step_stale_rules() {
    if [ -x .tooling/detect-stale-rules.sh ]; then
        bash .tooling/detect-stale-rules.sh --summary 2>/dev/null
    else
        echo "stale_rules: (skipped, script not found)"
    fi
}

# 2. rule file 間重複検出
step_duplicates() {
    if [ -x .tooling/detect-duplicates.py ]; then
        python3 .tooling/detect-duplicates.py --summary 2>/dev/null
    else
        echo "duplicates: (skipped, script not found)"
    fi
}

# 4. 静的 rule 容量監視 (= 階層別合計)
#    親 = CLAUDE + profile + always (= 40 KB)
#    project = _README + always (= 20 KB)
#    subproject = _README + always (= 10 KB)
#    形態 D 移行中: rules/always.md (新) + rules/always/*.md (旧) 両対応で合算
step_capacity() {
    # 派生 repo によっては未配備 (= 他の任意 step と同じく在る時だけ走らせる)
    if [ -f .tooling/check-static-capacity.sh ]; then
        bash .tooling/check-static-capacity.sh || true
    fi
}

# 5. docs-check (= 最後の 1 行 summary)
step_docs_check() {
    if [ -x .tooling/docs-check.sh ]; then
        docs_summary=$(bash .tooling/docs-check.sh 2>&1 | sed $'s/\033\[[0-9;]*m//g' | grep -E "^(PASS|WARN|FAIL):" | tr '\n' ' ')
        echo "docs-check: $docs_summary"
    else
        echo "docs-check: (script not found)"
    fi
}

# 5b. staledocs (= code<->docs 整合、 warn 運用の実測フェーズ。 CLI 不在 = skip、 起動を止めない)
step_staledocs() {
    if [ -f .staledocs.yaml ]; then
        SD_BIN=""
        if command -v staledocs >/dev/null 2>&1; then
            SD_BIN="staledocs"
        elif [ -x "$HOME/.cache/staledocs/venv/bin/staledocs" ]; then
            SD_BIN="$HOME/.cache/staledocs/venv/bin/staledocs"
        fi
        if [ -n "$SD_BIN" ]; then
            sd_summary=$("$SD_BIN" check 2>/dev/null | grep -E "^staledocs: " | head -1)
            echo "${sd_summary:-staledocs: (no summary line)}"
        else
            echo "staledocs: (CLI not found, skipped)"
        fi
    fi
}

# 6. local leak detector (= 派生 opt-in: 混入してはいけない語彙の検出 script を
#    .tooling/detect-company-terms.sh として置くと自動で走る、 無ければ skip)
step_company_terms() {
    if [ -x .tooling/detect-company-terms.sh ]; then
        bash .tooling/detect-company-terms.sh --summary 2>/dev/null
    else
        echo "company_terms: (skipped, script not found)"
    fi
}

# 7. git guard armament across every checkout on this machine.
#    A repo-local core.hooksPath REPLACES the global one (git honours exactly
#    one), so a single `git config --local core.hooksPath .githooks` silently
#    disables the machine-wide baseline — including the commit-msg scan that
#    keeps personal identifiers out of commit subjects and bodies. The
#    dispatcher's own doctor only inspects the current directory unless given a
#    glob, which is why two repos sat shadowed unnoticed; sweep them all here.
step_git_guard() {
    guard_shadowed=0
    guard_repos=""
    for _d in "$HOME"/repos/*/*/ "$ROOT"; do
        [ -d "${_d}/.git" ] || continue
        _lp="$(git -C "${_d}" config --local --get core.hooksPath 2>/dev/null || true)"
        if [ -n "${_lp}" ]; then
            guard_shadowed=$((guard_shadowed + 1))
            guard_repos="${guard_repos} ${_d#"$HOME"/}"
        fi
    done
    if [ -z "$(git config --global --get core.hooksPath 2>/dev/null || true)" ]; then
        echo "git_guard: DISARMED (no global core.hooksPath on this machine)"
    elif [ "${guard_shadowed}" -gt 0 ]; then
        echo "git_guard: ${guard_shadowed} repo(s) shadowing the global hooks:${guard_repos}"
    else
        echo "git_guard: armed (no repo-local hooksPath overrides)"
    fi
}

# 8. Claude Code settings distribution (truth -> every config dir).
#    Per-dir maintenance is how the personal and work accounts ended up on
#    different models, effort levels and hooks — the work account had no
#    go-gate hook at all. One truth, distributed; drift is reported here.
step_claude_settings() {
    if [ -f .tooling/sync-claude-settings.sh ]; then
        bash .tooling/sync-claude-settings.sh | tail -1
    fi
}

# 6b. anon word-list distribution freshness (truth -> machine config, one-way).
#    A stale machine copy silently weakens every repo's scanning, so a drift
#    is repaired automatically, not just reported.
step_anon_words() {
    WORDS_TRUTH="rules/anon-words.txt"
    MASTER="$HOME/.config/anon-words/master.txt"
    if [ -f "$WORDS_TRUTH" ]; then
        if [ -f "$MASTER" ] && diff -q "$WORDS_TRUTH" "$MASTER" >/dev/null 2>&1; then
            echo "anon_words: master.txt in sync"
        else
            mkdir -p "$(dirname "$MASTER")"
            cp "$WORDS_TRUTH" "$MASTER"
            echo "anon_words: master.txt was stale -> redistributed"
        fi
        # operator-specific extra distributions (e.g. filtered subsets) live in a
        # local, non-synced hook so the base stays generic
        if [ -f .tooling/anon-dist-local.sh ]; then
            bash .tooling/anon-dist-local.sh
        fi
    fi
}

step_rule_hits() {
    if [ -f .tooling/rule-hits-summary.py ]; then
        python3 .tooling/rule-hits-summary.py 2>/dev/null
    else
        echo "rule_hits: (skipped, script not found)"
    fi
}

step_stale_rules      > "$TMPD/1-stale"      &
step_rule_hits        > "$TMPD/10-hits"      &
step_duplicates       > "$TMPD/2-dup"        &
step_capacity         > "$TMPD/3-capacity"   &
step_docs_check       > "$TMPD/4-docs"       &
step_staledocs        > "$TMPD/5-staledocs"  &
step_company_terms    > "$TMPD/6-company"    &
step_git_guard        > "$TMPD/7-guard"      &
step_claude_settings  > "$TMPD/8-settings"   &
step_anon_words       > "$TMPD/9-anon"       &
wait

cat "$TMPD/1-stale" "$TMPD/2-dup" "$TMPD/10-hits" "$TMPD/3-capacity" "$TMPD/4-docs" \
    "$TMPD/5-staledocs" "$TMPD/6-company" "$TMPD/7-guard" "$TMPD/8-settings"
awk -v a="$_T0" -v b="${EPOCHREALTIME:-$(date +%s)}" \
    'BEGIN{printf "elapsed: %.1fs (= 全 step 並列、 律速は最も遅い 1 本)\n", b-a}'

echo "============================================"
echo ""
cat "$TMPD/9-anon"

echo "action policy:"
echo "  - stale_rules / dup_pairs: ignore at startup (the agent sweeps them in session-end Step 2)"
echo "  - docs-check FAIL >= 1 -> must fix within the same session"
echo "  - static_capacity over limit -> DELETE rules outright, in one shot, then return to the task."
echo "    Moving text to a lazy file or rewording it shorter does not count. Never make the user wait on this."
echo "  - staledocs red >= 1 -> read the findings; fix real drift, ack verified pairs (warn gate)"
echo "  - company_terms LEAK >= 1 -> forbidden vocabulary reached the state tree; scrub/delete within the same session"
echo "  - git_guard not 'armed' -> the commit-msg identifier scan is off for those repos; clear the local"
echo "    core.hooksPath (the global dispatcher already delegates to .githooks/) before committing there"
echo "  - claude_settings drifted -> a config dir diverged from templates/claude-settings.json; fold the"
echo "    wanted change into the truth, then run .tooling/sync-claude-settings.sh --apply"
