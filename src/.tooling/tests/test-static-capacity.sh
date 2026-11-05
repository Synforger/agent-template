#!/usr/bin/env bash
# check-static-capacity.sh の fixture test (= わざと溢れる形で赤が出ることを実証する)。
#
# 4 通りを一時 repo で走らせる:
#   1. skill の一覧だけが溢れる   → exit 1、 skill の行と長い順の内訳が出る
#   2. 常時 load だけが溢れる     → exit 1、 skill 側の処理で落ちない (= 空配列の展開)
#   3. どちらも収まる             → exit 0
#   4. サブプロの下の 2 段目・3 段目の常時 load が溢れる → exit 1、 その階層の名前が出る
#
# macOS 標準の /bin/bash (= 3.2) と PATH の bash の両方で回す (= 3.2 だけが空配列の展開で落ちる)。
#
# 走らせ方: bash .tooling/tests/test-static-capacity.sh
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
start=$(date +%s)
fails=0
# 溢れさせる大きさは、 script の上限から決める (= 上限を変えても試験はそのまま効く)
limit() { sed -n "s/^$1=\([0-9]*\)$/\1/p" "$SRC/startup/check-static-capacity.sh"; }
SKILLS_OVER=$(( $(limit SKILLS_PARENT_LIMIT) + 1000 ))
PARENT_OVER=$(( $(limit PARENT_LIMIT) + 1000 ))
SUB_OVER=$(( $(limit SUBPROJECT_LIMIT) + 1000 ))

make_repo() {
    local d
    d=$(mktemp -d)
    git -C "$d" init -q
    mkdir -p "$d/.tooling/lib" "$d/.tooling/startup" "$d/profile" "$d/rules"
    cp "$SRC/startup/check-static-capacity.sh" "$SRC/startup/capacity-candidates.py" "$d/.tooling/startup/"
    cp "$SRC/lib/skill-listing.py" "$SRC/lib/tier_paths.py" "$d/.tooling/lib/"
    printf 'x\n' > "$d/CLAUDE.md"
    printf 'x\n' > "$d/profile/profile.md"
    printf 'x\n' > "$d/rules/always.md"
    echo "$d"
}

add_skill() { # $1=repo $2=名前 $3=description のバイト数
    mkdir -p "$1/.claude/skills/$2"
    printf -- '---\ntitle: t\ndescription: %s\nwhen_to_use: w\n---\n' "$(head -c "$3" /dev/zero | tr '\0' 'a')" \
        > "$1/.claude/skills/$2/SKILL.md"
}

expect() { # $1=名前 $2=期待 exit $3=出力に含むべき語 (空なら見ない) $4=repo
    local out code
    out=$(cd "$4" && "$SH" .tooling/startup/check-static-capacity.sh 2>&1)
    code=$?
    if [ "$code" -ne "$2" ] || { [ -n "$3" ] && ! grep -q -- "$3" <<<"$out"; } || grep -q 'unbound variable' <<<"$out"; then
        echo "FAIL [$SH] $1 (exit=$code)"; sed 's/^/    /' <<<"$out"; fails=$((fails + 1))
    else
        echo "ok   [$SH] $1"
    fi
    rm -rf "$4"
}

for SH in /bin/bash bash; do
    r=$(make_repo); add_skill "$r" big "$SKILLS_OVER"; add_skill "$r" small 10
    expect "skill の一覧だけが溢れる" 1 "agent parent skills listing" "$r"

    r=$(make_repo); head -c "$PARENT_OVER" /dev/zero | tr '\0' 'a' > "$r/rules/always.md"
    expect "常時 load だけが溢れる" 1 "agent parent: " "$r"

    r=$(make_repo); add_skill "$r" small 10
    expect "どちらも収まる" 0 "OK" "$r"

    r=$(make_repo); mkdir -p "$r/projects/p/subprojects/s/subprojects/t/rules"
    head -c "$SUB_OVER" /dev/zero | tr '\0' 'a' > "$r/projects/p/subprojects/s/subprojects/t/rules/always.md"
    expect "サブプロの下の 3 段目の常時 load が溢れる" 1 "p/s/t: " "$r"

    r=$(make_repo); mkdir -p "$r/projects/p/subprojects/s/subprojects/t/.claude/skills/"
    add_skill "$r/projects/p/subprojects/s/subprojects/t" big "$(( $(limit SKILLS_SUBPROJECT_LIMIT) + 1000 ))"
    expect "サブプロの下の 3 段目の skill の一覧が溢れる" 1 "p/s/t skills listing" "$r"
done

echo "elapsed: $(( $(date +%s) - start ))s"
[ "$fails" -eq 0 ]
