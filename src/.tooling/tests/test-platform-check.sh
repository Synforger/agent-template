#!/bin/bash
# .tooling/startup/check_platform.py の test。 作り物の器の根に `platform` の身代わりを置き、 点検の出力ごとに
# 起動の検査の行が clean / 問題の数と 1 件 1 行 / UNKNOWN になる事と、 器の無い機械で黙る事を確かめる。
#
#   bash .tooling/tests/test-platform-check.sh
set -uo pipefail

CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/startup/check_platform.py"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

ROOT="${T}/platform"
FAKE="${ROOT}/manifest/bin/platform"
run() { AGENT_PLATFORM_ROOT="${ROOT}" python3 "${CHECK}"; }

# 身代わりの platform を置く: <標準出力に出す文> <終了コード> [標準エラーに出す文]
fake_platform() {
    mkdir -p "$(dirname "${FAKE}")"
    printf '#!/bin/bash\n[ "$1" = check ] || exit 9\nprintf %%s %q\nprintf %%s %q >&2\nexit %s\n' \
        "$1" "${3-}" "$2" > "${FAKE}"
    chmod +x "${FAKE}"
}

# <説明> <期待する出力の全文>
expect() {
    local what="$1" want="$2" out
    out="$(run)"
    if [ "${out}" = "${want}" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "${what}" "${want//$'\n'/ | }" "${out//$'\n'/ | }"
    fi
}

DRIFT=$'template drift: tools/app from personal-template: 2 missing, 14 differ, 19 same\n'

# --- 器の無い機械 ---
expect "no platform command under the root: nothing is printed" ""

# --- 問題が無い ---
fake_platform "${DRIFT}check: clean"$'\n' 0
expect "clean check with template drift lines: one clean line" "platform_check: clean"

# --- 問題が在る (= この test が実証する本体) ---
fake_platform $'config dir ~/.claude does not trust ~/agent-platform/agents/demo\nservice com.example.preview restarting: read ~/agent-platform/state/preview/error.log\n'"${DRIFT}"$'check: 2 problem(s)\n' 1
expect "two problems: the count, then each problem on its own line, drift lines left out" \
    "platform_check: 2 problem(s)
  problem: config dir ~/.claude does not trust ~/agent-platform/agents/demo
  problem: service com.example.preview restarting: read ~/agent-platform/state/preview/error.log"

# --- 点検が集計の行を出さなかった ---
fake_platform "" 1 $'Traceback (most recent call last):\nModuleNotFoundError: No module named agent_platform\n'
expect "no summary line: UNKNOWN with the exit code and the last error line" \
    "platform_check: UNKNOWN (platform check exited 1 without its summary line: ModuleNotFoundError: No module named agent_platform)"

# --- 点検が終わらない ---
mkdir -p "$(dirname "${FAKE}")"
printf '#!/bin/bash\nexec sleep 60\n' > "${FAKE}"
chmod +x "${FAKE}"
start=${SECONDS}
# 20 秒の上限を待たないよう、 読み込んだ後に上限だけ 1 秒へ差し替えて main を呼ぶ
out="$(AGENT_PLATFORM_ROOT="${ROOT}" python3 - "${CHECK}" <<'EOF'
import runpy, sys
module = runpy.run_path(sys.argv[1], run_name="not_main")
module["main"].__globals__["TIMEOUT_SEC"] = 1
module["main"]()
EOF
)"
if [ "${out}" = "platform_check: UNKNOWN (platform check did not finish in 1s)" ] && [ $((SECONDS - start)) -lt 10 ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    printf 'FAIL: a check that does not finish is cut off and named UNKNOWN\n  got:  %s\n' "${out//$'\n'/ | }"
fi

# --- 動かせない ---
printf 'not a script' > "${FAKE}"
chmod -x "${FAKE}"
expect "a platform file that cannot run: UNKNOWN with the reason" \
    "platform_check: UNKNOWN (could not run ${FAKE}: Permission denied)"

echo "test-platform-check: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
