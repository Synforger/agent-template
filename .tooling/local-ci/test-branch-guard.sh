#!/bin/bash
# The branch-name guard of .githooks/pre-commit reads the name of a detached HEAD without running it as a command,
# and still refuses main and develop. Runs the hook in throwaway repositories.
#
#   bash .tooling/local-ci/test-branch-guard.sh   (called by `task ci`)
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.githooks/pre-commit"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
failed=0

mkdir "${T}/bin"
# a command with the same name as the branch a detached HEAD is described by
printf '#!/bin/sh\ntouch "%s/ran"\n' "${T}" > "${T}/bin/probe"
chmod +x "${T}/bin/probe"

# run the hook in a repository whose only branch is <branch>, on it or detached at its tip
hook_on() { # <branch> <on|detached>
    local repo="${T}/repo"
    rm -rf "${repo}" "${T}/ran"
    mkdir "${repo}"
    (
        cd "${repo}" || exit 2
        export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
        export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
        git init -q . || exit 2
        tip="$(git commit-tree "$(git write-tree)" -m fixture)" || exit 2
        git update-ref "refs/heads/$1" "${tip}" || exit 2
        git symbolic-ref HEAD "refs/heads/$1" || exit 2
        if [ "$2" = detached ]; then git update-ref --no-deref HEAD "${tip}" || exit 2; fi
        PATH="${T}/bin:${PATH}" bash "${HOOK}"
    ) > "${T}/out" 2>&1
}

expect() { # <branch> <on|detached> <pass|refuse>
    hook_on "$1" "$2"
    local status=$?
    if [ -e "${T}/ran" ]; then
        echo "FAIL: $1 ($2): the branch name ran as a command"
        failed=1
    elif [ "$3" = pass ] && [ "${status}" -ne 0 ]; then
        echo "FAIL: $1 ($2): refused"
        failed=1
    elif [ "$3" = refuse ] && ! grep -q "Can't commit on branch" "${T}/out"; then
        echo "FAIL: $1 ($2): not refused by the branch guard"
        failed=1
    fi
}

expect probe detached pass
expect feature/unnamed-command detached pass
expect main detached refuse
expect develop detached refuse
expect main on refuse
expect feature/work on pass

echo "branch-guard: failed=${failed}"
exit "${failed}"
