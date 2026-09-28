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
# sandbox の中では scutil が本当の名前を返さない (= 汎用名になる) ので、 hostname でも照合する
local_host=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
pc_label=""
if [ -f "$PC_LABELS_FILE" ]; then
    for h in "$local_host" "$(hostname -s)"; do
        pc_label=$(grep -v '^#' "$PC_LABELS_FILE" | grep -v '^$' | awk -v h="$h" '$1 == h { print $2; exit }')
        [ -n "$pc_label" ] && { local_host="$h"; break; }
    done
fi
if [ -n "$pc_label" ]; then
    echo "PC: $pc_label ($local_host)"
else
    echo "PC: unknown ($local_host) — add it to .tooling/pc-labels.txt"
fi

# 以降の検出は互いに独立なので同時に走らせ、 出力は元の並び順で組み直す
# (= 直列だと一番遅い 1 本の裏で残り全部が待つだけになる)。
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/startup-status.XXXXXX")
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
#    Work checkouts also live inside the areas of ~/.config/guard/areas.txt
#    (= machine-local, the same boundary the guard reads), nested to any depth;
#    a sweep of the personal repos folder alone reported "armed" while a client repo ran no
#    guard at all. A local `guard.scope exempt` is a shadow too (= the
#    dispatcher skips the repo outright); only the agent repo itself may carry it.
step_git_guard() {
    guard_shadowed=0
    guard_repos=""
    while IFS= read -r _d; do
        [ -d "${_d}/.git" ] || continue
        _lp="$(git -C "${_d}" config --local --get core.hooksPath 2>/dev/null || true)"
        _scope="$(git -C "${_d}" config --local --get guard.scope 2>/dev/null || true)"
        if [ -n "${_lp}" ]; then
            guard_shadowed=$((guard_shadowed + 1))
            guard_repos="${guard_repos} ${_d#"$HOME"/}(hooksPath)"
        elif [ "${_scope}" = "exempt" ] && [ "${_d%/}" != "${ROOT%/}" ]; then
            guard_shadowed=$((guard_shadowed + 1))
            guard_repos="${guard_repos} ${_d#"$HOME"/}(exempt)"
        fi
    done < <({ printf '%s\n' "$HOME"/repos/*/*/ "$ROOT"
               _areas="$HOME/.config/guard/areas.txt"
               [ -f "${_areas}" ] && awk '!/^[[:space:]]*#/ && NF >= 2 && $1 != "_exempt" { for (i = 2; i <= NF; i++) print $i }' "${_areas}" \
                   | sed "s#^~#$HOME#" | while IFS= read -r _root; do
                       find "${_root}" -maxdepth 7 \( -name third_party -o -name .venv -o -name node_modules \
                           -o -name .fetchcontent-cache -o -name site-packages \) -prune -o -name .git -print 2>/dev/null
                   done | sed 's#/\.git$##' | sort -u; })
    if [ -z "$(git config --global --get core.hooksPath 2>/dev/null || true)" ]; then
        echo "git_guard: DISARMED (no global core.hooksPath on this machine)"
    elif [ "${guard_shadowed}" -gt 0 ]; then
        echo "git_guard: ${guard_shadowed} repo(s) shadowing the global hooks:${guard_repos}"
    else
        echo "git_guard: armed (no repo-local hooksPath overrides)"
    fi
    # The agent entry guard lives in the dispatcher checkout and is reached through
    # ~/.git-hooks; the settings entry passes silently when it is missing (a blocking
    # hook would stop every tool call), so its absence has to be said here.
    if [ -f "$HOME/.git-hooks/agent-hooks/claude-code/area-guard.py" ]; then
        echo "agent_guard: installed"
    else
        echo "agent_guard: MISSING (~/.git-hooks/agent-hooks/claude-code/area-guard.py)"
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
        elif mkdir -p "$(dirname "$MASTER")" 2>/dev/null && cp "$WORDS_TRUTH" "$MASTER" 2>/dev/null; then
            echo "anon_words: master.txt was stale -> redistributed"
        else
            echo "anon_words: master.txt STALE, redistribute FAILED (a cage cannot write it; run the startup check from a plain terminal)"
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

# 11. remote との差 (= 別 PC が push した分を読まずに起動していないか)。
#     起動手順の pull が落ちた / 抜けた時の網で、 ここは数えるだけで取り込まない
#     (= fetch は remote 追跡 ref しか動かさず、 作業木には触らない)。
step_remote_sync() {
    _up="$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null || true)"
    if [ -z "$_up" ]; then
        echo "remote_sync: (skipped, no upstream branch)"
        return
    fi
    # 回線が無い時に起動を待たせない (= timeout が在る環境だけ上限を掛ける)
    _to=""
    command -v timeout >/dev/null 2>&1 && _to="timeout 10"
    if ! $_to git fetch --quiet 2>/dev/null; then
        echo "remote_sync: UNKNOWN (fetch failed — the counts below would be stale, so none are shown)"
        return
    fi
    _counts="$(git rev-list --left-right --count "HEAD...$_up" 2>/dev/null || true)"
    _ahead="${_counts%%[[:space:]]*}"
    _behind="${_counts##*[[:space:]]}"
    if [ -z "$_counts" ]; then
        echo "remote_sync: UNKNOWN (could not compare HEAD with $_up)"
    elif [ "$_behind" -gt 0 ]; then
        echo "remote_sync: BEHIND $_behind commit(s) vs $_up (ahead $_ahead) — everything read so far is stale"
    else
        echo "remote_sync: up to date with $_up (ahead $_ahead)"
    fi
}

# 6c. model pinning in the launch path (= alias only, never a version-pinned id).
#    A version-pinned id or a variant suffix (claude-opus-5, opus[1m]) keeps launching yesterday's shape
#    after a newer one ships, and nothing on screen says so. Aliases (opus /
#    fable / sonnet / haiku, + [1m] for 1M) resolve to the latest each launch.
step_model_pin() {
    local launcher=".tooling/lib/claude-launch.py" model="" pinned="" exec_line=""
    if [ ! -f "$launcher" ]; then
        echo "model_pin: (skipped, $launcher not found)"
        return
    fi
    model=$(sed -nE 's/^MODEL = "([^"]*)".*/\1/p' "$launcher" | head -1)
    exec_line=$(grep -c -- '"--model"' "$launcher")
    if [ -z "$model" ] || [ "$exec_line" -eq 0 ]; then
        echo "model_pin: UNPINNED (launcher passes no --model; the global settings default decides)"
        return
    fi
    case "$model" in
        claude-*) pinned="launcher($model = 版を名指し)" ;;
        *\[*)    pinned="launcher($model = 変種の接尾辞)" ;;
    esac
    if [ -f "$HOME/.zshrc" ] && grep -qE -- '--model[= ]+.?(claude-[a-z]+-[0-9]|[a-z]+\[)' "$HOME/.zshrc"; then
        pinned="${pinned}${pinned:+, }zshrc"
    fi
    if [ -n "$pinned" ]; then
        echo "model_pin: PINNED $pinned (= 固定要因。 alias 1 語へ直す)"
    else
        echo "model_pin: ok (launcher=$model, alias だけ = 毎回最新へ解決)"
    fi
}

# 起動した檻から読めない階層 (= 別の境界)。 数え上げる検査はそこを黙って飛ばすので、 名前をここで出す
step_unchecked_tiers() {
    local hidden=() p
    for p in projects/*/ projects/*/subprojects/*/; do
        [ -d "$p" ] || continue
        case "$(basename "$p")" in _*) continue ;; esac
        ls "$p" > /dev/null 2>&1 || hidden+=("${p%/}")
    done
    if [ "${#hidden[@]}" -gt 0 ]; then
        echo "unchecked_tiers: ${hidden[*]} (= この檻から読めない。 その階層の檻の起動と終了で点検される)"
    else
        echo "unchecked_tiers: none"
    fi
}

step_unchecked_tiers  > "$TMPD/0b-unchecked" &
step_remote_sync      > "$TMPD/0-remote"     &
step_stale_rules      > "$TMPD/1-stale"      &
step_rule_hits        > "$TMPD/10-hits"      &
step_duplicates       > "$TMPD/2-dup"        &
step_capacity         > "$TMPD/3-capacity"   &
step_docs_check       > "$TMPD/4-docs"       &
step_company_terms    > "$TMPD/6-company"    &
step_git_guard        > "$TMPD/7-guard"      &
step_claude_settings  > "$TMPD/8-settings"   &
step_model_pin        > "$TMPD/8b-model"    &
step_anon_words       > "$TMPD/9-anon"       &
wait

cat "$TMPD/0-remote" "$TMPD/0b-unchecked" "$TMPD/1-stale" "$TMPD/2-dup" "$TMPD/10-hits" "$TMPD/3-capacity" "$TMPD/4-docs" \
    "$TMPD/6-company" "$TMPD/7-guard" "$TMPD/8-settings" "$TMPD/8b-model"
awk -v a="$_T0" -v b="${EPOCHREALTIME:-$(date +%s)}" \
    'BEGIN{printf "elapsed: %.1fs (= 全 step 並列、 律速は最も遅い 1 本)\n", b-a}'

echo "============================================"
echo ""
cat "$TMPD/9-anon"

echo "action policy:"
echo "  - remote_sync BEHIND -> run 'git pull --rebase --autostash' and re-read every startup file before briefing"
echo "    (UNKNOWN -> say so in the briefing; do not claim the state is current)"
echo "  - stale_rules / dup_pairs: ignore at startup (the agent sweeps them in session-end Step 2)"
echo "  - unchecked_tiers listed -> say in the briefing that those tiers were not checked; every count above covers"
echo "    the visible tiers only (the hidden ones are checked when their own cage starts and ends)"
echo "  - docs-check FAIL >= 1 -> must fix within the same session"
echo "  - static_capacity over limit -> DELETE rules outright, in one shot, then return to the task."
echo "    Moving text to a skill or rewording it shorter does not count. Never make the user wait on this."
echo "  - company_terms LEAK >= 1 -> forbidden vocabulary reached the state tree; scrub/delete within the same session"
echo "  - git_guard not 'armed' -> the commit-msg identifier scan is off for those repos; clear the local"
echo "    core.hooksPath (the global dispatcher already delegates to .githooks/) before committing there"
echo "  - agent_guard MISSING -> this machine's guard-dispatcher checkout predates agent-hooks/ (the agent can read"
echo "    areas and write anywhere until then): in the guard-dispatcher clone run 'git fetch origin &&"
echo "    git checkout -B develop origin/develop && bash scripts/bootstrap-machine.sh' (= its README)"
echo "  - model_pin PINNED -> a launch path names a model version or a variant suffix; use the bare alias"
echo "    (opus / fable / sonnet / haiku) so every release and every default change is picked up"
echo "  - claude_settings drifted -> a config dir diverged from templates/claude-settings.json; fold the"
echo "    wanted change into the truth, then run .tooling/sync-claude-settings.sh --apply (outside a cage: a cage"
echo "    cannot write Claude Code settings files, so ask the operator to run it from a plain terminal)"
