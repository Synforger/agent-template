#!/bin/bash
# .tooling/session-end/extract-artifact-index.sh の test。 作り物のエージェントの repo で、 索引に載る commit が
# journal の階層の物だけかを確かめる (= 別の階層の commit は載らない / 自分の repo を持つ階層は、 その repo の commit が載る)。
#
#   bash .tooling/tests/test-artifact-index-scope.sh
set -uo pipefail

TOOLING="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

check() { # <説明> <コマンド...>
    local what="$1"
    shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}

tgit() { HOME="${T}/home" git -c user.name=t -c user.email=t@example.invalid "$@"; }
commit_in() { # <repo> <file> <subject>
    mkdir -p "$(dirname "$1/$2")"
    echo x > "$1/$2"
    tgit -C "$1" add -- "$2" && tgit -C "$1" commit -q -m "$3" -- "$2"
}

# 作り物のエージェントの repo (= script と、 書く前に訊く口だけを写す。 番人の無い機械として通る)
AGENT="${T}/agent"
mkdir -p "${AGENT}/.tooling/session-end" "${AGENT}/.tooling/lib" "${T}/home"
cp "${TOOLING}/session-end/extract-artifact-index.sh" "${AGENT}/.tooling/session-end/"
cp "${TOOLING}/lib/guard-may-write.py" "${AGENT}/.tooling/lib/"
tgit -C "${AGENT}" init -q
echo "projects/OWN/" > "${AGENT}/.gitignore"
commit_in "${AGENT}" "rules/always.md" "parent tier"
commit_in "${AGENT}" "projects/P/rules/always.md" "project tier"
commit_in "${AGENT}" "projects/P/subprojects/S/rules/always.md" "subproject tier"
OWN="${AGENT}/projects/OWN"
mkdir -p "${OWN}"
tgit -C "${OWN}" init -q
commit_in "${OWN}" "rules/always.md" "own repo tier"

today="$(date '+%Y-%m-%d')"
subjects() { # <journal の folder> (= 書いた索引の commit の題を 1 行 1 件)
    python3 -c 'import json,sys; [print(c.split(" ",1)[1]) for c in json.load(open(sys.argv[1]))["commits_agent"]]' \
        "${AGENT}/$1/${today}/session-01-auto-index.jsonl"
}
run() { # <journal の folder> (= 番人の無い HOME で、 その session の記録も無い形で走らせる)
    (cd "${AGENT}" && HOME="${T}/home" CLAUDE_CODE_SESSION_ID="" \
        AREA_GUARD_HOOK="${T}/home/no-guard.py" bash .tooling/session-end/extract-artifact-index.sh "$1" --nn 01) >/dev/null 2>&1
}

run journal
check "the parent's index holds only the parent's commit" [ "$(subjects journal)" = "parent tier" ]

run projects/P/journal
check "a project's index leaves out the parent and its subprojects" [ "$(subjects projects/P/journal)" = "project tier" ]

run projects/P/subprojects/S/journal
check "a subproject's index holds only its own commit" [ "$(subjects projects/P/subprojects/S/journal)" = "subproject tier" ]

run "${OWN}/journal"
check "a tier with its own repository gets that repository's commit" [ "$(subjects projects/OWN/journal)" = "own repo tier" ]

echo "test-artifact-index-scope: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
