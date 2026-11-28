#!/usr/bin/env bash
# startup-status.sh - セッション起動時の状態スナップショット (= LLM 不使用、 token ゼロ)
# 用途: Phase B-共通 で実行、 各 utility を summary モードで呼んで結果を 1 ブロックで出力
# エージェント は出力を Read して「打診すべき項目があれば 1 行打診」 を Phase C で判断
# 走らせ方: bash <agent-repo-root>/.tooling/startup/startup-status.sh

set -uo pipefail
# 自分がどれだけ待たせたかを最後に名乗る (= 遅くなったことに気づけるのは数字が出ている時だけ)
_T0="${EPOCHREALTIME:-$(date +%s)}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "ROOT not found: $ROOT"; exit 2; }
# shellcheck source=../lib/guard-place.sh
source "$ROOT/.tooling/lib/guard-place.sh"

echo "===== agent startup status ($(date '+%Y-%m-%d %H:%M:%S')) ====="

# 0. PC 識別 (= 自宅 / 会社、 LocalHostName → label mapping)
PC_LABELS_FILE="$ROOT/.tooling/startup/pc-labels.txt"
local_host=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
pc_label=""
if [ -f "$PC_LABELS_FILE" ]; then
    pc_label=$(grep -v '^#' "$PC_LABELS_FILE" | grep -v '^$' | awk -v h="$local_host" '$1 == h { print $2; exit }')
fi
if [ -n "$pc_label" ]; then
    echo "PC: $pc_label ($local_host)"
else
    echo "PC: unknown ($local_host) — add it to .tooling/startup/pc-labels.txt"
fi

# 以降の検出は互いに独立なので同時に走らせ、 出力は元の並び順で組み直す
# (= 直列だと一番遅い 1 本の裏で残り全部が待つだけになる)。
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# 1. rule 形骸化検出 (= 7 日無更新 = 退役候補)
step_stale_rules() {
    if [ -x .tooling/startup/detect-stale-rules.sh ]; then
        bash .tooling/startup/detect-stale-rules.sh --summary 2>/dev/null
    else
        echo "stale_rules: (skipped, script not found)"
    fi
}

# 2. rule file 間重複検出
step_duplicates() {
    if [ -x .tooling/startup/detect-duplicates.py ]; then
        python3 .tooling/startup/detect-duplicates.py --summary 2>/dev/null
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
    if [ -f .tooling/startup/check-static-capacity.sh ]; then
        bash .tooling/startup/check-static-capacity.sh || true
    fi
}

# 5. docs-check (= 1 行 summary + FAIL の行ごとの `  fail: <本文>`。 後者は route_by_owner.py が持ち主の階層へ振り分けて消す)
step_docs_check() {
    if [ -x .tooling/docs-check/docs-check.sh ]; then
        docs_output=$(bash .tooling/docs-check/docs-check.sh 2>&1 | sed $'s/\033\[[0-9;]*m//g')
        echo "docs-check: $(grep -E "^(PASS|WARN|FAIL):" <<< "$docs_output" | tr '\n' ' ')"
        grep -E "^  FAIL: " <<< "$docs_output" | sed 's/^  FAIL: /  fail: /'
    else
        echo "docs-check: (script not found)"
    fi
}

# 6. local leak detector (= 派生 opt-in: 混入してはいけない語彙の検出 script を
#    .tooling/commit/detect-company-terms.sh として置くと自動で走る、 無ければ skip)
step_company_terms() {
    if [ -x .tooling/commit/detect-company-terms.sh ]; then
        bash .tooling/commit/detect-company-terms.sh --summary 2>/dev/null
    else
        echo "company_terms: (skipped, script not found)"
    fi
}

# 6b. 番人の週次の深い監査の、 最後の回の結果 (= log に書くだけで誰にも届かず、 10 週見つけ続けていた。
#     2026-10-20 の事故)。 番人が既知を除いて書くので、 見つかった物は全部新しい漏れで、 その repo の境界を
#     読めるタブにだけ出す。 判定と出し方は audit_findings.py の頭書き。
step_weekly_audit() {
    bash .tooling/startup/audit-known.sh status
}

# 7. git guard armament across every checkout on this machine.
#    A repo-local core.hooksPath REPLACES the global one (git honours exactly
#    one), so a single `git config --local core.hooksPath .githooks` silently
#    disables the machine-wide baseline — including the commit-msg scan that
#    keeps personal identifiers out of commit subjects and bodies. The
#    dispatcher's own doctor only inspects the current directory unless given a
#    glob, which is why two repos sat shadowed unnoticed; sweep them all here.
#    Work checkouts also live inside the areas of the guard's areas.txt
#    (= machine-local, the same boundary the guard reads), nested to any depth;
#    a sweep of the personal repos folder alone reported "armed" while a client repo ran no
#    guard at all. A local `guard.scope exempt` is a shadow too (= the
#    dispatcher skips the repo outright); only the agent repo itself may carry it, and a tier's
#    record repository inside it while it has no remote (= nothing it holds can leave the machine).
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
        elif [ "${_scope}" = "exempt" ] && [ "${_d%/}" != "${ROOT%/}" ] \
            && ! { [ "${_d#"${ROOT%/}"/}" != "${_d}" ] && [ -z "$(git -C "${_d}" remote 2>/dev/null)" ]; }; then
            guard_shadowed=$((guard_shadowed + 1))
            guard_repos="${guard_repos} ${_d#"$HOME"/}(exempt)"
        fi
    done < <({ printf '%s\n' "$HOME"/repos/*/*/ "$ROOT"
               _areas="$(guard_place areas.txt)"
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
    if [ -e "$(guard_place agent-off)" ]; then
        echo "agent_guard: OFF (the operator switched it off = $(guard_place agent-off))"
    elif [ -f "$HOME/.git-hooks/agent-hooks/claude-code/area-guard.py" ]; then
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
    if [ -f .tooling/distribute/sync-claude-settings.sh ]; then
        bash .tooling/distribute/sync-claude-settings.sh | tail -1
    fi
}

# 6b. anon word-list distribution freshness (truth -> machine config, one-way).
#    A stale machine copy silently weakens every repo's scanning, so a drift
#    is repaired automatically, not just reported.
step_anon_words() {
    WORDS_TRUTH="rules/anon-words.txt"
    MASTER="$(guard_place master-words)"
    if [ -f "$WORDS_TRUTH" ]; then
        # words that must stay out of git (= names only this machine's folders know) come from a
        # local, non-synced generator and are appended before comparing: the machine copy is the
        # tracked truth plus what this machine alone can say
        local wanted
        wanted="$(mktemp)"
        cat "$WORDS_TRUTH" > "$wanted"
        if [ -f .tooling/startup/anon-words-local.sh ]; then
            bash .tooling/startup/anon-words-local.sh >> "$wanted" 2>/dev/null
        fi
        if [ -f "$MASTER" ] && diff -q "$wanted" "$MASTER" >/dev/null 2>&1; then
            echo "anon_words: master.txt in sync"
        elif mkdir -p "$(dirname "$MASTER")" 2>/dev/null && cp "$wanted" "$MASTER" 2>/dev/null; then
            echo "anon_words: master.txt was stale -> redistributed"
        else
            echo "anon_words: master.txt STALE, redistribute FAILED (could not write $MASTER)"
        fi
        rm -f "$wanted"
        # operator-specific extra distributions (e.g. filtered subsets) live in a
        # local, non-synced hook so the base stays generic
        if [ -f .tooling/startup/anon-dist-local.sh ]; then
            bash .tooling/startup/anon-dist-local.sh
        fi
    fi
}

step_rule_hits() {
    if [ -f .tooling/rules/rule-hits-summary.py ]; then
        python3 .tooling/rules/rule-hits-summary.py 2>/dev/null
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

# 6c. model / effort pinning in the launch path (= 判定の真値は check-launch-pins.py)。
#    A version-pinned id or a variant suffix keeps launching yesterday's shape after a newer one ships, and an
#    effort env var silently beats the launcher's --effort; nothing on screen says either.
step_launch_pins() {
    python3 .tooling/startup/check-launch-pins.py || echo "model_pin: (failed, check-launch-pins.py exited $?)"
}

# 6e. 動いている番人 (= ~/.git-hooks が指す clone) が origin/develop と揃っているか。 番人の直しは merge しただけでは
#    効かず、 各 PC で guard-update.sh を流して clone を develop に進めて初めて入る。 clone が別の branch に居る /
#    手で書き換わっている時も STALE になる。 develop の tree の blob と clone の file の hash を突き合わせる
#    (= 違う / 無い / 余分 を数える)。 fetch できない時は手元の origin/develop と比べ、 そう名乗る
step_guard_deploy() {
    local clone="${GUARD_CLONE:-$(cd -P "$HOME/.git-hooks/scripts" 2>/dev/null && cd .. && pwd)}" note="" tip result
    [ -d "$HOME/.git-hooks/scripts" ] || { echo "guard_deploy: (skipped, no guard installed)"; return; }
    git -C "$clone" rev-parse --git-dir >/dev/null 2>&1 || { echo "guard_deploy: (skipped, no clone at $clone)"; return; }
    timeout 8 git -C "$clone" fetch -q origin develop 2>/dev/null \
        || note=" (not fetched: compared with the last known origin/develop)"
    tip=$(git -C "$clone" log -1 --format='%h %s' origin/develop 2>/dev/null | cut -c1-80)
    [ -n "$tip" ] || { echo "guard_deploy: UNKNOWN (no origin/develop in $clone)"; return; }
    result=$(git -C "$clone" ls-tree -r -z origin/develop | python3 -c '
import hashlib, os, sys
home = os.path.realpath(os.path.expanduser("~/.git-hooks/scripts/.."))
keep = {"anon-words.txt", "anon-words.local.txt"}  # = 運用者の禁止語 (= git に載らない。 番人の中のどの folder に在っても名前で見る)
skip_dirs = {"node_modules", "__pycache__", ".git"}
tree = {}
for entry in sys.stdin.buffer.read().split(b"\0"):
    if entry:
        meta, path = entry.split(b"\t", 1)
        mode, kind, sha = meta.split()
        if kind == b"blob":
            tree[path.decode()] = (mode.decode(), sha.decode())
def blob(path, mode):
    data = os.readlink(path).encode() if mode == "120000" else open(path, "rb").read()
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
differ = missing = 0
for rel, (mode, sha) in tree.items():
    p = os.path.join(home, rel)
    if not os.path.lexists(p):
        missing += 1
    elif blob(p, mode) != sha:
        differ += 1
extra = 0
for root, dirs, files in os.walk(home):
    dirs[:] = [d for d in dirs if d not in skip_dirs]
    for f in files:
        rel = os.path.relpath(os.path.join(root, f), home)
        if rel not in tree and f not in keep and not rel.endswith(".pyc"):
            extra += 1
print(differ, missing, extra)
' 2>/dev/null)
    set -- $result
    if [ $# -ne 3 ]; then
        echo "guard_deploy: UNKNOWN (could not compare the clone with origin/develop)${note}"
    elif [ "$1$2$3" = "000" ]; then
        echo "guard_deploy: ok (clone = origin/develop ${tip%% *})${note}"
    else
        echo "guard_deploy: STALE (clone differs from origin/develop ${tip}: ${1} changed, ${2} missing, ${3} extra)${note}"
    fi
}

# 6f. この機械が手元の clone から配備している repo が、 origin より遅れていないか (= 判定の真値は
#     check-deployed-clones.sh)。 派生が deployed-clones.txt に宣言した clone だけを見る。 宣言が無ければ何も出さない
step_clone_deploys() {
    if [ -f .tooling/startup/check-deployed-clones.sh ]; then
        bash .tooling/startup/check-deployed-clones.sh
    fi
}

# 8g. 器 (= manifest で建てた道具・体・常駐の置き場) が、 宣言どおりに揃って動いているか (= 判定の真値は
#     manifest の `platform check`、 読んで行にするのは check_platform.py)。 器の無い機械では何も出さない
step_platform_check() {
    if [ -f .tooling/startup/check_platform.py ]; then
        python3 .tooling/startup/check_platform.py
    fi
}

step_children() {
    # このタブが立てた子のタブ (= 入れ替わった親が、 自分の子とその状態を読む口。 PWA のタブの外では UNKNOWN)
    if command -v tabs >/dev/null 2>&1; then
        tabs children --summary 2>/dev/null || echo "children: UNKNOWN"
    fi
}

step_tickets() {
    # このタブが持つ票の数 (= tabs status の tickets: の行。 子の状態は children: の段が出す。 PWA のタブの外では何も出さない)
    if command -v tabs >/dev/null 2>&1; then
        tabs status 2>/dev/null | grep '^tickets:' || echo "tickets: UNKNOWN"
    fi
}

step_fixed_cost() {
    # 起動と締めの固定費 (= hooks/fixed_cost.py が全部のタブで書く記録) の、 この階層と全体の 1 行
    if [ -f .tooling/startup/fixed_cost_summary.py ]; then
        python3 .tooling/startup/fixed_cost_summary.py
    fi
}

# 回している計画の予算 (= 公式の % が頭、 会話からの見当が内訳) と、 repo に開いたまま残る物の数 (= work/plan_run.py の 1 行ずつ。
# 設定が無ければ何も出さない。 どちらも止めず、 値と離れた印だけ)
step_plan_budget() {
    if [ -f .tooling/work/plan_run.py ] && [ -f .tooling/work/plan-run.toml ]; then
        python3 .tooling/work/plan_run.py budget 2>/dev/null | grep '^plan_budget('
    fi
}

step_leftovers() {
    if [ -f .tooling/work/plan_run.py ] && [ -f .tooling/work/plan-run.toml ]; then
        python3 .tooling/work/plan_run.py leftovers --no-pr 2>/dev/null | grep '^leftovers:'
    fi
}

step_tab_health() {
    # この機械の client のタブの土台 (= tmux の server が 1 本か・一覧に無い session) を見る
    if [ -f .tooling/startup/tab_health.py ]; then
        python3 .tooling/startup/tab_health.py
    fi
}

step_pages_orphans() {
    # 起動した階層の pages/ に残った、生きているタブの物でない folder (= 閉じたタブのページを誰も拾わずに残さないため)
    if [ -f .tooling/startup/pages_orphans.py ]; then
        python3 .tooling/startup/pages_orphans.py
    fi
}

# 6g. 道具の repo の Actions (= develop の最新の commit と開いている PR の結果。 判定は tool_actions.py)。
#     (= 赤のまま merge され続けても、 道具の repo の側には起動の画面へ言う物が無い)
step_tool_actions() {
    if [ -f .tooling/startup/tool_actions.py ]; then
        python3 .tooling/startup/tool_actions.py
    fi
}

# 6i. 別の機械に繋がっているか (= client の見張りの記録を読むだけ。 判定は peer_health.py)。 届かなかった連絡は
#     送り主にしか見えず、 相手の機械が落ちていても誰も気づかなかった (= 2 日)
step_peer_health() {
    if [ -f .tooling/startup/peer_health.py ]; then
        python3 .tooling/startup/peer_health.py
    fi
}

# 6j. 番人の照合の外にある repo (= 番人の doctor が書く一覧を読むだけ。 割り方は unchecked_repos.py)。
#     持ち主は振り分けず、 どのタブも自分の読める境界の分の path と、 ほかの数を見る
step_unchecked_repos() {
    if [ -f .tooling/startup/unchecked_repos.py ]; then
        python3 .tooling/startup/unchecked_repos.py
    fi
}

# 6h. 番人が名乗りの検査をかけ、 締めの commit で初めて止まる階層 (= 判定は pending_approvals.py、 種類は番人に訊く)。
#     持ち主はその階層で、 route_by_owner.py がその階層のタブにだけ出す
step_pending_approvals() {
    if [ -f .tooling/startup/pending_approvals.py ]; then
        python3 .tooling/startup/pending_approvals.py --root "$ROOT"
    fi
}

step_remote_sync      > "$TMPD/0-remote"     &
step_peer_health      > "$TMPD/8j-peers"     &
step_unchecked_repos  > "$TMPD/6c-unchecked" &
step_stale_rules      > "$TMPD/1-stale"      &
step_rule_hits        > "$TMPD/10-hits"      &
step_duplicates       > "$TMPD/2-dup"        &
step_capacity         > "$TMPD/3-capacity"   &
step_docs_check       > "$TMPD/4-docs"       &
step_company_terms    > "$TMPD/6-company"    &
step_weekly_audit     > "$TMPD/6b-audit"     &
step_git_guard        > "$TMPD/7-guard"      &
step_claude_settings  > "$TMPD/8-settings"   &
step_launch_pins      > "$TMPD/8b-pins"     &
step_guard_deploy     > "$TMPD/8d-deploy"   &
step_clone_deploys    > "$TMPD/8e-clones"   &
step_tool_actions     > "$TMPD/8e2-tools"   &
step_pending_approvals > "$TMPD/8i-pending" &
step_platform_check   > "$TMPD/8g-platform" &
step_children         > "$TMPD/8f-children" &
step_tickets          > "$TMPD/8f2-tickets" &
step_pages_orphans    > "$TMPD/8h-pages"    &
step_tab_health       > "$TMPD/8k-tabs"     &
step_fixed_cost       > "$TMPD/8l-cost"     &
step_plan_budget      > "$TMPD/8m-budget"   &
step_leftovers        > "$TMPD/8n-left"     &
step_anon_words       > "$TMPD/9-anon"       &
wait

# 警告は持ち主の階層のタブにだけ今の行で出し、 ほかの階層の分は末尾の `others:` の行にまとめる (= route_by_owner.py)
python3 .tooling/startup/route_by_owner.py --root "$ROOT" \
    "$TMPD/0-remote" "$TMPD/1-stale" "$TMPD/2-dup" "$TMPD/10-hits" "$TMPD/3-capacity" "$TMPD/4-docs" \
    "$TMPD/6-company" "$TMPD/6b-audit" "$TMPD/6c-unchecked" "$TMPD/7-guard" "$TMPD/8-settings" "$TMPD/8b-pins" "$TMPD/8d-deploy" "$TMPD/8e-clones" \
    "$TMPD/8e2-tools" "$TMPD/8g-platform" "$TMPD/8f-children" "$TMPD/8f2-tickets" "$TMPD/8h-pages" "$TMPD/8k-tabs" "$TMPD/8l-cost" "$TMPD/8m-budget" "$TMPD/8n-left" "$TMPD/8i-pending" "$TMPD/8j-peers" | tee "$TMPD/status"
awk -v a="$_T0" -v b="${EPOCHREALTIME:-$(date +%s)}" \
    'BEGIN{printf "elapsed: %.1fs (= 全 step 並列、 律速は最も遅い 1 本)\n", b-a}'

echo "============================================"
echo ""
cat "$TMPD/9-anon"

# 反応の決まりは、 ok でない行に当たる物だけを出す (= 本文の真値は action-policy.txt)
python3 .tooling/startup/action_policy.py "$TMPD/status" "$ROOT"
