#!/bin/bash
# test-ci-duplicate-guard.sh - hooks/ci_duplicate_guard.py が、 公開の repo で `task ci` を打つ時だけ止めるか。
# 作り物の repo (= `task ci` を呼ぶ workflow の有無) と gh の身代わり (= PUBLIC / PRIVATE / 失敗) で確かめる。
#
#   bash .tooling/tests/test-ci-duplicate-guard.sh
set -u
HOOK="$(cd "$(dirname "$0")/../hooks" && pwd)/ci_duplicate_guard.py"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
T="$(cd -P "${T}" && pwd)"
pass=0; fail=0
check() { # <説明> <コマンド...>
    local what="$1"
    shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}

# 作り物の repo: pub は `task ci` を呼ぶ workflow を持つ、 bare は workflow を持たない
for r in pub bare; do
    mkdir -p "${T}/${r}"
    git -C "${T}/${r}" init -q
done
mkdir -p "${T}/pub/.github/workflows" "${T}/pub/sub"
printf 'jobs:\n  gates:\n    steps:\n      - run: task ci\n' > "${T}/pub/.github/workflows/ci.yml"
mkdir -p "${T}/elsewhere"
# gh の身代わり: GH_ANSWER をそのまま答える (= fail なら exit 1)
cat > "${T}/gh" <<'SH'
#!/bin/sh
[ "${GH_ANSWER}" = "fail" ] && exit 1
echo "${GH_ANSWER}"
SH
chmod +x "${T}/gh"

run() { # <gh の答え> <作業の folder> <命令> [道具]
    local tool="${4:-Bash}"
    python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":sys.argv[1],"tool_input":{"command":sys.argv[2]},"cwd":sys.argv[3]}))' \
        "${tool}" "$3" "$2" | GH_ANSWER="$1" CI_GUARD_GH="${T}/gh" python3 "${HOOK}"
}
denied() { run "$@" | grep -q '"permissionDecision": "deny"'; }
passed() { [ -z "$(run "$@")" ]; }

check "公開の repo で task ci を打つと止める" denied PUBLIC "${T}/pub" "task ci"
check "repo の中の下の folder からでも止める" denied PUBLIC "${T}/pub/sub" "task ci"
check "前の段の cd の先で打つ task ci を止める" denied PUBLIC "${T}/elsewhere" "cd ${T}/pub && task ci"
check "task -d で repo を指す形を止める" denied PUBLIC "${T}/elsewhere" "task -d ${T}/pub ci"
check "止める理由に Actions と直した file の試験を書く" bash -c "$(declare -f run); T='${T}'; HOOK='${HOOK}'; run PUBLIC '${T}/pub' 'task ci' | grep -q 'Actions'"
check "private の repo は通す" passed PRIVATE "${T}/pub" "task ci"
check "gh が答えない時は通す" passed fail "${T}/pub" "task ci"
check "task ci を呼ぶ workflow の無い repo は通す" passed PUBLIC "${T}/bare" "task ci"
check "公開の repo でも直した file の試験は通す" passed PUBLIC "${T}/pub" "task test"
check "task ci で始まる別の task は通す" passed PUBLIC "${T}/pub" "task ci:lint"
check "文字として task ci を含むだけの命令は通す" passed PUBLIC "${T}/pub" "grep -n 'task ci' Taskfile.yml"
check "git の外は通す" passed PUBLIC "${T}/elsewhere" "task ci"
check "Bash 以外の道具は通す" passed PUBLIC "${T}/pub" "task ci" Read

echo "test-ci-duplicate-guard: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
