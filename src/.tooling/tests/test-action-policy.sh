#!/bin/bash
# .tooling/startup/action_policy.py の試験。 作り物の検査の出力で、 ok でない行に当たる決まりだけが出るかを確かめる。
#
#   bash .tooling/tests/test-action-policy.sh
set -u
POLICY="$(cd "$(dirname "$0")/.." && pwd)/startup/action_policy.py"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
pass=0
fail=0

check() { # <説明> <コマンド...>
    local what="$1"
    shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}
run() { printf '%s\n' "$@" > "${WORK}/status"; python3 "${POLICY}" "${WORK}/status" "${HOME}/agent"; }

out="$(run 'remote_sync: up to date with origin/master (ahead 0)' 'docs-check: PASS: 9 WARN: 1 FAIL: 0 ' 'claude_settings: in sync' \
    'pages_orphans: 0' 'peer(home): ok' 'pending_approval: none' 'git_guard: armed (no repo-local hooksPath overrides)')"
check "全部 ok なら決まりを 1 行も出さない" [ "${out}" = "action policy: nothing to act on (every line above is ok)" ]

out="$(run 'remote_sync: BEHIND 3' 'docs-check: PASS: 9 WARN: 1 FAIL: 2 ' 'claude_settings: in sync')"
check "ok でない行の決まりは出す" grep -q 'remote_sync BEHIND ->' <<< "${out}"
check "FAIL のある docs-check の決まりは出す" grep -q 'docs-check FAIL >= 1' <<< "${out}"
check "ok の行の決まりは出さない" bash -c '! grep -q "claude_settings drifted" <<< "$1"' _ "${out}"

out="$(run 'guard_deploy: STALE (clone 1 behind origin/develop)' 'peer(home): DOWN 2h (3 messages wait)' 'pages_orphans: 2 (雛形だけ 2: ses_a ses_b)')"
check "決まりの {root} はエージェントの folder を ~ の形で埋める" grep -q 'bash ~/agent/.tooling/distribute/guard-update.sh' <<< "${out}"
check "peer( の行も頭で当てる" grep -q 'peer(<name>) DOWN' <<< "${out}"
check "0 でない pages_orphans は出す" grep -q 'pages_orphans >= 1' <<< "${out}"

out="$(run 'pages_orphans: 0 (別の機械のタブか不明 1: ses_a)')"
check "不明だけの pages_orphans は出さない" bash -c '! grep -q "pages_orphans >= 1" <<< "$1"' _ "${out}"

out="$(run 'git_guard: DISARMED repo-a' 'company_terms: 0 (clean)' 'unchecked_repos: none (written 2026-11-15)')"
check "armed でない git_guard は出す" grep -q "git_guard not 'armed'" <<< "${out}"
check "0 の company_terms は出さない" bash -c '! grep -q "company_terms LEAK" <<< "$1"' _ "${out}"
check "none の unchecked_repos は出さない" bash -c '! grep -q "unchecked_repos N ->" <<< "$1"' _ "${out}"

out="$(run 'others: docs-check 2 (owner projects/X)')"
check "others: の行が在れば、 その決まりを出す" grep -q 'others: lines ->' <<< "${out}"

echo "test-action-policy: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
