#!/usr/bin/env bash
# 静的 rule 容量の階層別合計を測る (= 真値はここ 1 箇所)。
#
#   親        = CLAUDE + profile + always            (= 40 KB)
#   project   = _README + always                          (= 20 KB)
#   subproject= _README + always                          (= 10 KB)
#
# skill の一覧 (= description + when_to_use、 毎 session 文脈に入る) は別枠で階層ごとに数える
# (= 常時 load の枠へ統合するかはルールの見直しで決める):
#   親 4 KB / project 4 KB / subproject 2 KB
#
# 呼び出し元:
#   - .tooling/startup-status.sh  (= 起動時の 1 行 summary)
#   - .githooks/pre-commit        (= 超過したまま commit させない)
#
# 超過が 1 つでもあれば exit 1。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PARENT_LIMIT=40960
PROJECT_LIMIT=20480
SUBPROJECT_LIMIT=10240
SKILLS_PARENT_LIMIT=4096
SKILLS_PROJECT_LIMIT=4096
SKILLS_SUBPROJECT_LIMIT=2048

sum_files() {
    local total=0 f
    for f in "$@"; do
        [ -f "$f" ] && total=$((total + $(wc -c < "$f")))
    done
    echo "$total"
}

# その階層の skill 一覧のバイト数 (= 0 本なら 0)
skills_size() {
    local files=("$1".claude/skills/*/SKILL.md)
    [ -f "${files[0]}" ] || { echo 0; return; }
    python3 .tooling/lib/skill-listing.py "${files[@]}" | awk '{s += $1} END {print s + 0}'
}

# 超過したら overflows に積む (= $1 表示名 / $2 階層 dir / $3 上限)
check_skills() {
    local size
    size=$(skills_size "$2")
    if [ "$size" -gt "$3" ]; then
        overflows+=("$1 skills listing: ${size} B > $3 B")
        skill_overflow_dirs+=("$2")
    fi
}

overflows=()
overflow_files=()   # 超過した階層の file 群 (= 削減候補を出す対象)
skill_overflow_dirs=()
parent_files=(CLAUDE.md profile/profile.md rules/always.md)
parent_size=$(sum_files "${parent_files[@]}")
if [ "$parent_size" -gt "$PARENT_LIMIT" ]; then
    overflows+=("agent parent: ${parent_size} B > ${PARENT_LIMIT} B")
    overflow_files+=("${parent_files[@]}")
fi
check_skills "agent parent" "" "$SKILLS_PARENT_LIMIT"

for p_dir in projects/*/; do
    p_name=$(basename "$p_dir")
    case "$p_name" in _*) continue ;; esac
    proj_files=("$p_dir/_README.md" "$p_dir/rules/always.md")
    proj_size=$(sum_files "${proj_files[@]}")
    if [ "$proj_size" -gt "$PROJECT_LIMIT" ]; then
        overflows+=("$p_name: ${proj_size} B > ${PROJECT_LIMIT} B")
        overflow_files+=("${proj_files[@]}")
    fi
    check_skills "$p_name" "$p_dir" "$SKILLS_PROJECT_LIMIT"

    for s_dir in "$p_dir"subprojects/*/; do
        [ -d "$s_dir" ] || continue
        s_name=$(basename "$s_dir")
        case "$s_name" in _*) continue ;; esac
        sub_files=("$s_dir/_README.md" "$s_dir/rules/always.md")
        sub_size=$(sum_files "${sub_files[@]}")
        if [ "$sub_size" -gt "$SUBPROJECT_LIMIT" ]; then
            overflows+=("$p_name/$s_name: ${sub_size} B > ${SUBPROJECT_LIMIT} B")
            overflow_files+=("${sub_files[@]}")
        fi
        check_skills "$p_name/$s_name" "$s_dir" "$SKILLS_SUBPROJECT_LIMIT"
    done
done

if [ "${#overflows[@]}" -gt 0 ]; then
    echo "static_capacity: ${#overflows[@]} tier(s) over limit"
    for o in "${overflows[@]}"; do echo "  - $o"; done
    # どれを消せば何バイト減るかを先に出す (= 「少し削って測り直す」 の往復を作らない)
    [ "${#overflow_files[@]}" -gt 0 ] && { python3 .tooling/lib/capacity-candidates.py "${overflow_files[@]}" 2>/dev/null || true; }
    # skill は一覧に出る説明文の長い順に出す
    # bash 3.2 は set -u の下で空配列の展開を unbound と見なすので、 在る時だけ展開する
    for d in ${skill_overflow_dirs[@]+"${skill_overflow_dirs[@]}"}; do
        python3 .tooling/lib/skill-listing.py "$d".claude/skills/*/SKILL.md | sort -rn | sed 's/^/    /'
    done
    echo "  condense before committing (relaxing the cap is the last resort)" >&2
    exit 1
fi
# 起動で実際に読む量 (= 常時 load + vision + skill の一覧)。 上限はそれぞれ別に守られているが、 合計を出して数えていない量を作らない
startup_read=$(( parent_size + $(sum_files vision.md) + $(skills_size "") ))
echo "static_capacity: OK (all tiers within limits; parent startup read = ${startup_read} B incl. vision + skill listing)"
