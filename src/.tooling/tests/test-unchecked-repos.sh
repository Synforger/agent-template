#!/bin/bash
# test-unchecked-repos.sh - unchecked_repos.py が、 番人の doctor の一覧から、 このタブが読める境界と境界の外・除外の
# 行だけ path を出し、 ほかは数だけにし、 一覧の無い機械では黙ることを、 作り物の一覧と作り物の番人で確かめる。
#   bash .tooling/tests/test-unchecked-repos.sh
set -u
TOOL="$(cd "$(dirname "$0")/.." && pwd)/startup/unchecked_repos.py"
W="$(mktemp -d)"
trap 'rm -rf "${W}"' EXIT
export UNCHECKED_REPOS_FILE="${W}/unchecked-repos.txt"
export AREA_GUARD_HOOK="${W}/area-guard.py"
pass=0
fail=0
check() { # <説明> <コマンド...>
    local what="$1"; shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}
# 番人の身代わり: `reach` は FAKE_REACH (空白区切り) を 1 行ずつ返す
cat > "${AREA_GUARD_HOOK}" <<'PY'
import os, sys
if sys.argv[1:] == ["reach"]:
    print("\n".join(os.environ.get("FAKE_REACH", "").split()))
PY
run() { FAKE_REACH="${1:-}" python3 "${TOOL}"; }

check "一覧の無い機械では黙る" [ -z "$(run)" ]

printf '# written 2026-11-15T18:52:50Z by doctor.sh --machine\n' > "${UNCHECKED_REPOS_FILE}"
check "当たる repo が無ければ none と書いた時刻" [ "$(run)" = "unchecked_repos: none (written 2026-11-15T18:52:50Z)" ]

printf 'outside\tarea-a\t/w/area-a/repo1\tguard.scope exempt\noutside\t-\t/w/free/repo2\tno remote\noutside\t_exempt\t/w/x/repo3\texempt folder\noutside\tarea-b\t/w/area-b/repo4\tguard.scope exempt\n' >> "${UNCHECKED_REPOS_FILE}"
out="$(run)"
check "頭の行は全部の数 (${out})" grep -q "^unchecked_repos: 4 repo(s) outside the guard's matching (written 2026-11-15T18:52:50Z)$" <<< "${out}"
check "境界の外と除外の行は、 境界を読まないタブにも path を出す" bash -c 'grep -q "repo: /w/free/repo2 (area -; no remote)" <<< "$1" && grep -q "repo: /w/x/repo3 (area _exempt; exempt folder)" <<< "$1"' _ "${out}"
check "読まない境界の path は出さず、 数だけ" bash -c '! grep -q "area-a\|area-b" <<< "$1" && grep -q "^  2 more in areas this tab does not read$" <<< "$1"' _ "${out}"
out="$(run area-a)"
check "読める境界の path は出す" bash -c 'grep -q "repo: /w/area-a/repo1 (area area-a; guard.scope exempt)" <<< "$1" && ! grep -q "area-b" <<< "$1" && grep -q "^  1 more in areas" <<< "$1"' _ "${out}"
out="$(AREA_GUARD_HOOK="${W}/no-such.py" run area-a)"
check "番人に訊けない時は、 境界の行を全部数だけにする" bash -c '! grep -q "area-a\|area-b" <<< "$1" && grep -q "^  2 more in areas" <<< "$1"' _ "${out}"

echo "test-unchecked-repos: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
