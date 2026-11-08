#!/usr/bin/env bash
# check-static-capacity.sh の fixture test (= わざと溢れる形で赤が出ることを実証する)。
#
# 一時 repo で走らせる:
#   1. skill の一覧だけが溢れる   → exit 1、 skill の行と長い順の内訳が出る
#   2. 常時 load だけが溢れる     → exit 1、 skill 側の処理で落ちない (= 空配列の展開)
#   3. どちらも収まる             → exit 0
#   4. サブプロの下の 2 段目・3 段目の常時 load が溢れる → exit 1、 その階層の名前が出る
#   5. commit の検査 (`--commit`): git に載る階層が溢れたら exit 1、 git に載らない階層だけが溢れたら
#      exit 0 で `WARN <階層>:` を出す (= 他のタブの commit を止めない)。 引数なし (= 起動の検査) は載らない階層でも exit 1
#   6. docs-check の容量の段が、 溢れた階層ごとに FAIL を 1 行出す (= git に載らない階層も)
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

# docs-check を走らせる repo (= .tooling を丸ごと写す。 docs-check は repo の root を script の位置から決める)
make_docs_repo() {
    local d
    d=$(make_repo)
    cp -R "$SRC/docs-check" "$SRC/rules" "$SRC/session-end" "$d/.tooling/"
    cp "$SRC/lib/"* "$d/.tooling/lib/" 2>/dev/null
    echo "$d"
}

add_skill() { # $1=repo $2=名前 $3=description のバイト数
    mkdir -p "$1/.claude/skills/$2"
    printf -- '---\ntitle: t\ndescription: %s\nwhen_to_use: w\n---\n' "$(head -c "$3" /dev/zero | tr '\0' 'a')" \
        > "$1/.claude/skills/$2/SKILL.md"
}

expect() { # $1=名前 $2=期待 exit $3=出力に含むべき語 (空なら見ない) $4=repo $5=script に渡す引数 (省略可)
    local out code
    out=$(cd "$4" && "$SH" .tooling/startup/check-static-capacity.sh ${5:-} 2>&1)
    code=$?
    if [ "$code" -ne "$2" ] || { [ -n "$3" ] && ! grep -q -- "$3" <<<"$out"; } || grep -q 'unbound variable' <<<"$out"; then
        echo "FAIL [$SH] $1 (exit=$code)"; sed 's/^/    /' <<<"$out"; fails=$((fails + 1))
    else
        echo "ok   [$SH] $1"
    fi
    rm -rf "$4"
}

# git に載らない階層 (= 無視される folder) を作り、 常時 load を溢れさせる
make_ignored_tier() { # $1=repo $2=階層名
    printf 'projects/%s/\n' "$2" > "$1/.gitignore"
    mkdir -p "$1/projects/$2/rules"
    head -c "$(( $(limit PROJECT_LIMIT) + 1000 ))" /dev/zero | tr '\0' 'a' > "$1/projects/$2/rules/always.md"
}

# docs-check の容量の段だけを見る (= 他の段の FAIL は repo の作りが粗いので数えない)
expect_docs_check() { # $1=名前 $2=出力に含むべき行 (空なら FAIL 行が 0 件であること) $3=repo
    local out cap
    out=$(cd "$3" && "$SH" .tooling/docs-check/docs-check.sh 2>&1 | sed $'s/\033\\[[0-9;]*m//g')
    cap=$(sed -n '/capacity of every tier/,$p' <<<"$out" | grep '^  FAIL: ' || true)
    if { [ -n "$2" ] && ! grep -q -- "$2" <<<"$cap"; } || { [ -z "$2" ] && [ -n "$cap" ]; }; then
        echo "FAIL [$SH] $1"; sed 's/^/    /' <<<"$out" | tail -20; fails=$((fails + 1))
    else
        echo "ok   [$SH] $1"
    fi
    rm -rf "$3"
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

    r=$(make_repo); mkdir -p "$r/projects/p/rules"
    head -c "$(( $(limit PROJECT_LIMIT) + 1000 ))" /dev/zero | tr '\0' 'a' > "$r/projects/p/rules/always.md"
    expect "commit の検査: git に載る階層が溢れたら止まる" 1 "p: " "$r" --commit

    r=$(make_repo); make_ignored_tier "$r" p
    expect "commit の検査: git に載らない階層だけが溢れたら通り、 WARN を出す" 0 "WARN p: .* B > .* B (その階層のタブが直す)" "$r" --commit

    r=$(make_repo); make_ignored_tier "$r" p; add_skill "$r/projects/p" big "$(( $(limit SKILLS_PROJECT_LIMIT) + 1000 ))"
    expect "commit の検査: git に載らない階層の skill の一覧が溢れても通る" 0 "WARN p skills listing" "$r" --commit

    r=$(make_repo); make_ignored_tier "$r" p; head -c "$PARENT_OVER" /dev/zero | tr '\0' 'a' > "$r/rules/always.md"
    expect "commit の検査: 載らない階層が溢れていても、 載る親が溢れたら止まる" 1 "agent parent: " "$r" --commit

    r=$(make_repo); make_ignored_tier "$r" p
    expect "起動の検査 (引数なし): git に載らない階層の溢れも今までどおり赤" 1 "p: " "$r"

    r=$(make_docs_repo); make_ignored_tier "$r" p
    expect_docs_check "docs-check: git に載らない階層の溢れを FAIL で名指す" "FAIL: p: .* B > .* B" "$r"

    r=$(make_docs_repo)
    expect_docs_check "docs-check: 収まっていれば容量の FAIL は出ない" "" "$r"
done

echo "elapsed: $(( $(date +%s) - start ))s"
[ "$fails" -eq 0 ]
