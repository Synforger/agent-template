#!/bin/bash
# 起動の検査の持ち主の振り分け (.tooling/startup/route_by_owner.py ← owner_routing.py ← owner_table.py) と、
# 道具の Actions の段 (tool_actions.py ← actions_verdict.py) の test。 作り物の階層・作り物の段の出力・番人と gh の身代わりで、
# 持ち主のタブにだけ今の行が出てほかの階層は `others:` にまとまる事、 docs-check の FAIL が path の一番深い階層に振られる事、
# 溢れた階層が名前で振られる事、 読めない階層の名前が伏せられる事、 Actions の ok / RED / UNKNOWN、 承認待ちの設定が
# 自分の repo を持ち guard.scope の無い階層だけに出る事を確かめる。
#
#   bash .tooling/tests/test-startup-owners.sh
set -uo pipefail

TOOLING="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTE="${TOOLING}/startup/route_by_owner.py"
ACTIONS="${TOOLING}/startup/tool_actions.py"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n  got: %s\n' "$1" "${2//$'\n'/ | }"; }

# --- 作り物の agent の folder: 階層 P1・P1/S1・T1/tool と、 本物の .tooling への link ---
AGENT="${T}/agent"
CLIENT_TIER='projects/T1/subprojects/tool'
mkdir -p "${AGENT}/projects/P1/subprojects/S1" "${AGENT}/${CLIENT_TIER}" "${AGENT}/rules" "${AGENT}/profile"
# 道具の持ち主は、 配備の宣言の 4 列目が真値
export DEPLOYED_CLONES_FILE="${T}/owners-declared.txt"
printf 'claude-pwa-client  ~/x/claude-pwa-client  develop  %s\nother-tool  ~/x/other  develop\n' "${CLIENT_TIER}" > "${DEPLOYED_CLONES_FILE}"
ln -s "${TOOLING}" "${AGENT}/.tooling"
printf '# a\n\n## big section\n\n%s\n\n## small\n\nx\n' "$(head -c 300 /dev/zero | tr '\0' 'x')" > "${AGENT}/CLAUDE.md"
cp "${AGENT}/CLAUDE.md" "${AGENT}/projects/P1/_README.md"

# 番人の身代わり: `reach` は GUARD_WORK_FOLDER の .fake-reach の中身、 無ければ FAKE_REACH (空白区切り) を 1 行ずつ返す
HOOK="${T}/area-guard.py"
cat > "${HOOK}" <<'PY'
import os, sys
from pathlib import Path
if sys.argv[1:] != ["reach"]:
    sys.exit(2)
marker = Path(os.environ.get("GUARD_WORK_FOLDER", "/nonexistent")) / ".fake-reach"
if marker.exists():
    print(marker.read_text())
else:
    for name in os.environ.get("FAKE_REACH", "").split():
        print(name)
PY

# --- 作り物の各段の出力 ---
STEPS="${T}/steps"
cat > "${STEPS}" <<EOF
remote_sync: BEHIND 4 commit(s) vs origin/master (ahead 0)
stale_rules: total=18 stale(7d)=8
static_capacity: 3 tier(s) over limit
  - agent parent: 50000 B > 49152 B
  - P1: 21000 B > 20480 B
  - P1/S1 skills listing: 3000 B > 2048 B
  削減候補 (= foreign detail that must not be shown to other tiers):
    999 B  発火  0  違反  projects/P1/subprojects/S1/rules/always.md :: foreign section
docs-check: PASS: 10 WARN: 2 FAIL: 4
  fail: layout: nothing matches _archive in the line of projects/**/.claude/skills
  fail: projects/P1/: hierarchy interface missing file → vision.md
  fail: projects/P1/subprojects/S1/rules/always.md: something wrong
  fail: P1/S1: 11000 B > 10240 B
git_guard: armed (no repo-local hooksPath overrides)
claude_settings: 2 target(s) drifted (run with --apply)
clone_deploy(claude-pwa-client): BEHIND 1 commit(s) vs origin/develop (abc fix)
clone_deploy(pptx-agent-maker): ok (HEAD has origin/develop abc)
tool_actions(claude-pwa-client): RED PR #12
tool_actions(pptx-agent-maker): ok (develop abc: 1 run(s); 0 open PR(s), none red)
tool_actions(unlisted-tool): UNKNOWN (gh exited 1)
weekly_audit: NEW in 1 repo(s) (log, 0d ago)
  new: /work/repo -> commit messages: wordone
children: 0
EOF

# route <階層> [FAKE_REACH] : その階層のタブへの出力
route() { AGENT_TIER="$1" AREA_GUARD_HOOK="${HOOK}" FAKE_REACH="${2:-}" python3 "${ROUTE}" --root "${AGENT}" "${STEPS}"; }
has() { local out; out="$(route "$2" "${4:-}")"; if grep -qE -- "$3" <<< "${out}"; then ok; else bad "$1 (want: $3)" "${out}"; fi; }
lacks() { local out; out="$(route "$2" "${4:-}")"; if grep -qE -- "$3" <<< "${out}"; then bad "$1 (must not match: $3)" "${out}"; else ok; fi; }

# 1. normal: 機械とエージェントの行はそのまま、 docs-check は normal の分だけ数え、 ほかの階層は others へ
has 'normal keeps its own warning rows' normal '^remote_sync: BEHIND 4'
has 'normal keeps the claude_settings row' normal '^claude_settings: 2 target'
has 'normal counts only its own docs-check FAIL' normal '^docs-check: PASS: 10 WARN: 2 FAIL: 1$'
has 'normal sees its own docs-check fail line' normal '^  fail: layout: nothing matches _archive'
lacks 'normal does not see another tier fail line' normal 'vision\.md|something wrong'
has 'docs-check FAIL of P1 goes to P1' normal '^others: docs-check 1 \(owner projects/P1\)$'
has 'docs-check FAILs of S1 (a path and a capacity name) go to S1' normal '^others: docs-check 2 \(owner projects/P1/subprojects/S1\)$'
has 'normal keeps only its own capacity overflow' normal '^static_capacity: 1 tier\(s\) over limit$'
has 'normal sees the parent overflow line' normal '^  - agent parent: 50000 B'
has 'normal gets candidates of its own files' normal '削減候補'
lacks 'normal is not shown the foreign candidate detail' normal 'foreign section'
has 'overflow of P1 goes to P1' normal '^others: static_capacity 1 \(owner projects/P1\)$'
has 'overflow of the skill listing of S1 goes to S1' normal '^others: static_capacity 1 \(owner projects/P1/subprojects/S1\)$'
has 'a tool row goes to the tier that owns the tool' normal "^others: tool_actions 1 \\(owner ${CLIENT_TIER}\\)\$"
lacks 'normal has no others line for its own rows' normal '^others: (remote_sync|claude_settings|clone_deploy)'
has 'a tool missing from the table is normal own' normal '^tool_actions\(unlisted-tool\): UNKNOWN'

# 2. 階層のタブ: 自分の階層の分だけ今の行、 normal の警告は others
has 'tier P1 sees docs-check FAIL: 1 with its line' projects/P1 '^docs-check: PASS: 10 WARN: 2 FAIL: 1$'
has 'tier P1 sees its own fail line' projects/P1 '^  fail: projects/P1/: hierarchy interface missing file'
lacks 'tier P1 is not shown the foreign fail line' projects/P1 'something wrong|nothing matches _archive'
has 'tier P1 sees its own capacity overflow' projects/P1 '^  - P1: 21000 B > 20480 B$'
has 'tier P1 gets candidates of its own README' projects/P1 '削減候補'
lacks 'tier P1 is not shown the parent overflow' projects/P1 'agent parent'
has 'tier P1 gets normal warnings as others' projects/P1 '^others: claude_settings 1 \(owner normal\)$'
has 'every tier is shown that the shared checkout is behind' projects/P1 '^remote_sync: BEHIND 4'
has 'tier P1 gets the normal docs-check FAIL as others' projects/P1 '^others: docs-check 1 \(owner normal\)$'
lacks 'tier P1 is not shown the normal warning rows' projects/P1 '^(claude_settings|clone_deploy\(claude)'
has 'tier P1 still sees healthy rows of normal' projects/P1 '^clone_deploy\(pptx-agent-maker\): ok'
has 'tier S1 sees its docs-check FAIL: 2 and skill overflow' projects/P1/subprojects/S1 '^docs-check: PASS: 10 WARN: 2 FAIL: 2$'
has 'tier S1 sees its skill listing overflow line' projects/P1/subprojects/S1 '^  - P1/S1 skills listing: 3000 B'
has 'the tool owner tier sees its RED line as it is' "${CLIENT_TIER}" '^tool_actions\(claude-pwa-client\): RED PR #12$'
lacks 'the tool owner tier has no others line for its own tool' "${CLIENT_TIER}" "^others: tool_actions [0-9]+ \\(owner ${CLIENT_TIER}"
has 'a tier with no overflow of its own is told it is within limits' "${CLIENT_TIER}" '^static_capacity: OK \(this tab.s tier is within limits; 3 over limit elsewhere'

# 3. どの階層にも持ち主の無い行はそのまま出る
has 'weekly_audit is never routed' projects/P1 '^weekly_audit: NEW in 1 repo'
has 'weekly_audit detail follows its row' projects/P1 '^  new: /work/repo'
has 'stale_rules is never routed' projects/P1 '^stale_rules: total=18'
has 'children is never routed' projects/P1 '^children: 0$'

# 4. 階層の名前は、 このタブがその階層のタブの読む境界を全部読める時だけ書く
has 'a readable owner is named' projects/P1 '^others: docs-check 1 \(owner normal\)$' 'zone-a'
printf 'secret-zone\n' > "${AGENT}/projects/P1/subprojects/S1/.fake-reach"
has 'an owner reading a boundary this tab cannot is hidden' normal '^others: docs-check 2 \(owner \(別の境界\)\)$' ''
lacks 'a hidden owner is not named' normal 'others:.*owner projects/P1/subprojects/S1'
has 'a boundary this tab also reads is named again' normal '^others: docs-check 2 \(owner projects/P1/subprojects/S1\)$' 'secret-zone'
rm -f "${AGENT}/projects/P1/subprojects/S1/.fake-reach"
out="$(AGENT_TIER=normal AREA_GUARD_HOOK="${T}/no-guard.py" python3 "${ROUTE}" --root "${AGENT}" "${STEPS}")"
if grep -qE '^others: docs-check 2 \(owner \(別の境界\)\)$' <<< "${out}"; then ok; else bad 'with no guard every owner but normal is hidden' "${out}"; fi
if grep -qE '^others: claude_settings' <<< "$(AGENT_TIER=projects/P1 AREA_GUARD_HOOK="${T}/no-guard.py" python3 "${ROUTE}" --root "${AGENT}" "${STEPS}")"; then ok; else bad 'normal is named even with no guard' ''; fi

# 5. docs-check の FAIL の持ち主: path の一番深い階層、 実在しない階層は近い親、 path が無ければ normal
owner_of() { python3 -c '
import sys
sys.path[:0] = [sys.argv[1] + "/lib", sys.argv[1] + "/startup"]
from owner_routing import docs_fail_owner
print(docs_fail_owner(sys.argv[2], frozenset({"projects/P1", "projects/P1/subprojects/S1"})))' "${TOOLING}" "$1"; }
expect_owner() { local got; got="$(owner_of "$2")"; if [ "${got}" = "$3" ]; then ok; else bad "$1 (want $3)" "${got}"; fi; }
expect_owner 'a rule file of the parent is normal' 'rules/always.md: too long' normal
expect_owner 'no path is normal' 'something without any path' normal
expect_owner 'a glob that is no tier is normal' 'layout: nothing matches x in projects/**/.claude/skills' normal
expect_owner 'a project file goes to the project' 'projects/P1/_README.md: bad' projects/P1
expect_owner 'a tier folder named with a trailing slash is that tier' 'projects/P1/subprojects/S1/: missing' projects/P1/subprojects/S1
expect_owner 'a tier folder named without a slash is that tier' 'link: projects/P1/subprojects/S1 broken' projects/P1/subprojects/S1
expect_owner 'the deepest tier among several paths wins' 'projects/P1/a.md → projects/P1/subprojects/S1/b.md (not found)' projects/P1/subprojects/S1
expect_owner 'a tier that does not exist falls back to its nearest parent' 'projects/P1/subprojects/GONE/a.md: bad' projects/P1
expect_owner 'a template folder is normal own' 'projects/_template-project/a.md: bad' normal
expect_owner 'a capacity name is mapped to its tier' 'P1/S1: 11000 B > 10240 B' projects/P1/subprojects/S1
expect_owner 'the parent capacity name is normal' 'agent parent skills listing: 7000 B > 6144 B' normal

# 6. 道具の Actions の段 (= gh の身代わり)
FAKEGH="${T}/fake-gh.sh"
cat > "${FAKEGH}" <<'SH'
#!/bin/bash
d="${FAKE_GH_DIR}"
[ -f "${d}/fail" ] && { echo "HTTP 401: bad credentials" >&2; exit 1; }
[ -f "${d}/slow" ] && sleep 5
case "$1 $2" in
    "api repos/"*) cat "${d}/api.json" ;;
    "run list") cat "${d}/runs.json" ;;
    "pr list") if [[ " $* " == *" merged "* ]]; then cat "${d}/merged.json"; else cat "${d}/open.json"; fi ;;
esac
SH
mkdir -p "${T}/clones/tool-a" "${T}/gh"
git -C "${T}/clones/tool-a" init -q
git -C "${T}/clones/tool-a" remote add origin git@github-x:Org/tool-a.git
printf '# a comment\ntool-a  %s/clones/tool-a  develop\n' "${T}" > "${T}/declared.txt"
SHA=0123456789abcdef0123456789abcdef01234567
gh_case() { # <runs> <merged> <open> : 3 つの JSON を置く
    printf '{"sha":"%s"}' "${SHA}" > "${T}/gh/api.json"
    printf '%s' "$1" > "${T}/gh/runs.json"; printf '%s' "$2" > "${T}/gh/merged.json"; printf '%s' "$3" > "${T}/gh/open.json"
    rm -f "${T}/gh/fail" "${T}/gh/slow"
}
actions() { FAKE_GH_DIR="${T}/gh" TOOL_ACTIONS_GH="bash ${FAKEGH}" DEPLOYED_CLONES_FILE="${T}/declared.txt" TOOL_ACTIONS_TIMEOUT_SEC="${1:-20}" python3 "${ACTIONS}"; }
expect_actions() { local out; out="$(actions "${3:-20}")"; if grep -qE -- "$2" <<< "${out}"; then ok; else bad "$1 (want: $2)" "${out}"; fi; }
MERGED_GREEN="[{\"number\":5,\"mergeCommit\":{\"oid\":\"${SHA}\"},\"statusCheckRollup\":[{\"conclusion\":\"SUCCESS\"}]}]"
MERGED_RED="[{\"number\":5,\"mergeCommit\":{\"oid\":\"${SHA}\"},\"statusCheckRollup\":[{\"conclusion\":\"FAILURE\"}]}]"

gh_case '[]' "${MERGED_GREEN}" '[]'
expect_actions 'a green merged PR and no open PR is ok' '^tool_actions\(tool-a\): ok \(develop 0123456: 1 check\(s\) of merged PR #5; 0 open PR\(s\)'
gh_case '[]' "${MERGED_RED}" '[]'
expect_actions 'a red merged PR makes develop RED' '^tool_actions\(tool-a\): RED develop \(0123456: merged PR #5\)$'
gh_case '[]' '[{"number":4,"mergeCommit":{"oid":"ffff"},"statusCheckRollup":[{"conclusion":"FAILURE"}]}]' '[]'
expect_actions 'a red PR that did not make the tip is not read' '^tool_actions\(tool-a\): ok \(develop 0123456: no run and no merged PR to read'
gh_case '[{"workflowName":"CI","conclusion":"success"},{"workflowName":"CI","conclusion":"failure"}]' '[]' '[]'
expect_actions 'a rerun that passed replaces the failed run' '^tool_actions\(tool-a\): ok \(develop 0123456: 2 run\(s\)'
gh_case '[{"workflowName":"CI","conclusion":"failure"},{"workflowName":"CI","conclusion":"success"}]' '[]' '[]'
expect_actions 'the newest run of a workflow decides: red' '^tool_actions\(tool-a\): RED develop \(0123456: CI\)$'
gh_case '[]' "${MERGED_GREEN}" '[{"number":7,"statusCheckRollup":[{"conclusion":"FAILURE"}]},{"number":8,"statusCheckRollup":[{"conclusion":"CANCELLED"},{"state":"SUCCESS"}]},{"number":9,"statusCheckRollup":[{"state":"ERROR"}]}]'
expect_actions 'open PRs with a failure or an error are RED, a cancelled one is not' '^tool_actions\(tool-a\): RED PR #7, RED PR #9$'
gh_case '[]' "${MERGED_RED}" '[{"number":7,"statusCheckRollup":[{"conclusion":"TIMED_OUT"}]}]'
expect_actions 'develop and a PR both red are listed together' '^tool_actions\(tool-a\): RED develop \(0123456: merged PR #5\), RED PR #7$'
gh_case '[]' "${MERGED_GREEN}" '[]'
touch "${T}/gh/fail"
expect_actions 'a gh that fails is UNKNOWN with the reason' '^tool_actions\(tool-a\): UNKNOWN \(.*HTTP 401'
rm -f "${T}/gh/fail"; touch "${T}/gh/slow"
expect_actions 'a gh that outlasts the limit is UNKNOWN' '^tool_actions\(tool-a\): UNKNOWN \(not finished in 1s\)' 1
rm -f "${T}/gh/slow"
printf 'tool-b  %s/no-such-clone  develop\n' "${T}" > "${T}/declared.txt"
expect_actions 'a clone that is not a repo is UNKNOWN' '^tool_actions\(tool-b\): UNKNOWN'
rm -f "${T}/declared.txt"
if [ -z "$(actions)" ]; then ok; else bad 'no declaration prints nothing' "$(actions)"; fi
if grep -q 'direnv exec' "${ACTIONS}"; then ok; else bad 'gh runs through direnv exec on the tools folder' "$(grep -n GH_COMMAND "${ACTIONS}")"; fi

# 7. 承認待ちの設定 (= pending_approvals.py): 自分の .git を持つ階層のうち、 番人が名乗りの検査をかける種類の物だけが出る
PENDING="${TOOLING}/startup/pending_approvals.py"
# 番人の部品の作り物: .fake-kind があればその種類、 無ければ guard.scope が corpus の時 corpus、 ほかは no-remote
export GUARD_DISPATCHER_COMMON="${T}/fake-dispatcher-common.sh"
cat > "${GUARD_DISPATCHER_COMMON}" <<'FAKE'
dispatcher::detect_repo_kind() {
    if [ -f .fake-kind ]; then cat .fake-kind
    elif [ "$(git config --get guard.scope)" = corpus ]; then echo corpus
    else echo no-remote; fi
}
FAKE
pending() { python3 "${PENDING}" --root "${AGENT}"; }
out="$(pending)"
if [ "${out}" = "pending_approval: none" ]; then ok; else bad 'tiers inside the parent repo print none' "${out}"; fi
git -C "${AGENT}/projects/P1" init -q                      # 自分の repo、 番人は no-remote と答える
git -C "${AGENT}/projects/P1/subprojects/S1" init -q       # 自分の repo、 番人は corpus と答える
git -C "${AGENT}/projects/P1/subprojects/S1" config --local guard.scope corpus
out="$(pending)"
if [ "${out}" = "pending_approval: guard.scope projects/P1" ]; then ok; else bad 'only the tier the guard checks for names is named' "${out}"; fi
printf 'corpus\n' > "${AGENT}/projects/P1/.fake-kind"      # 番人が置き場から corpus と決める (guard.scope 無し)
out="$(pending)"
if [ "${out}" = "pending_approval: none" ]; then ok; else bad 'a tier the guard judges corpus by its place is not named' "${out}"; fi
rm -f "${AGENT}/projects/P1/.fake-kind"
out="$(GUARD_DISPATCHER_COMMON="${T}/no-such-common.sh" pending)"
if [ "${out}" = "pending_approval: none" ]; then ok; else bad 'a machine without the guard names nothing' "${out}"; fi
printf '%s\n' "$(pending)" > "${STEPS}.pending"
has_pending() { local out; out="$(AGENT_TIER="$2" AREA_GUARD_HOOK="${HOOK}" python3 "${ROUTE}" --root "${AGENT}" "${STEPS}.pending")"; if grep -qE -- "$3" <<< "${out}"; then ok; else bad "$1 (want: $3)" "${out}"; fi; }
has_pending 'the tier owns its pending_approval line' projects/P1 '^pending_approval: guard.scope projects/P1$'
has_pending 'normal gets the pending_approval of a tier as others' normal '^others: pending_approval 1 \(owner projects/P1\)$'
has_pending 'another tier gets it as others too' projects/P1/subprojects/S1 '^others: pending_approval 1 \(owner projects/P1\)$'
printf 'pending_approval: none\n' > "${STEPS}.pending"
has_pending 'none is shown as it is' normal '^pending_approval: none$'

# 8. 起動の検査は、 Actions の段と承認待ちの段を呼び、 全段の出力を route_by_owner.py に通す
START="${TOOLING}/startup/startup-status.sh"
if grep -q 'tool_actions.py' "${START}" && grep -q 'pending_approvals.py' "${START}" && grep -q 'route_by_owner.py' "${START}"; then ok; else bad 'startup-status.sh calls tool_actions.py, pending_approvals.py and route_by_owner.py' "$(grep -n 'route_by\|tool_actions' "${START}" | head -3)"; fi

printf 'startup-owners: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
