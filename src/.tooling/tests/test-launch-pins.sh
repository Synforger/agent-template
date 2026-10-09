#!/bin/bash
# .tooling/startup/check-launch-pins.py の test。 作り物の HOME / repo で、 起動の経路に model の版名指しや
# effort の上書きを 1 つずつ置き、 赤になる形と緑のままの形を確かめる。
#
#   bash .tooling/tests/test-launch-pins.sh
set -uo pipefail

CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/startup/check-launch-pins.py"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

# <説明> <期待する行の正規表現> : 直前に組んだ fixture で check を走らせ、 出力のどこかの行が一致すれば緑
expect() {
    local what="$1" pattern="$2" out
    out="$(HOME="${T}/home" AGENT_ROOT="${T}/agent" \
        AGENT_TIER="${TIER-}" CLAUDE_EFFORT="${SESSION_EFFORT-}" python3 "${CHECK}")"
    if grep -qE -- "${pattern}" <<< "${out}"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "${what}" "${pattern}" "${out//$'\n'/ | }"
    fi
}

# launcher の身代わり (= 本物と同じ 3 行と、 引数を組む行、 session に階層を渡す行だけ)
launcher() { # <MODEL> <EFFORT> [引数の行]
    local args="${3-    command = [CLAUDE, \"--model\", MODEL, \"--effort\", EFFORT]}"
    printf 'MODEL = "%s"\nEFFORT = "%s"\nFAST_MODE = False\n%s\n        os.environ["AGENT_TIER"] = tier\n' "$1" "$2" "${args}" \
        > "${T}/agent/.tooling/lib/claude-launch.py"
}

setup() {
    rm -rf "${T}/home" "${T}/agent"
    mkdir -p "${T}/home/.claude" "${T}/home/.claude-work" "${T}/agent/.tooling/lib"
    printf '{"theme": "dark"}\n' > "${T}/home/.claude/settings.json"
    printf '{"theme": "dark"}\n' > "${T}/home/.claude-work/settings.json"
    launcher opus high
    TIER=""
    SESSION_EFFORT=""
}

# --- model_pin ---
setup
expect "alias だけなら緑" '^model_pin: ok \(launcher=opus'
expect "上書きが無ければ effort も緑" '^effort_pin: ok \(launcher=high, session=unmeasured\)'

setup; launcher claude-opus-5 high
expect "launcher の版名指しは赤" '^model_pin: PINNED launcher\(claude-opus-5 = 版を名指し\)'

setup; launcher 'opus[1m]' high
expect "launcher の変種接尾辞は赤" '^model_pin: PINNED launcher\(opus\[1m\] = 変種の接尾辞\)'

setup; launcher opus high '    command = [CLAUDE, "--effort", EFFORT]'
expect "--model を渡さない launcher は UNPINNED" '^model_pin: UNPINNED'

setup; printf 'alias c="claude --model claude-opus-5"\n' > "${T}/home/.zshrc"
expect "zshrc の版名指しは赤" '^model_pin: PINNED zshrc'

setup; printf 'claude --model opus\n' > "${T}/home/.zshrc"
expect "zshrc の alias 指定は緑" '^model_pin: ok'

setup; printf '{"model": "claude-fable-5[1m]"}\n' > "${T}/home/.claude-work/settings.json"
expect "settings.json の版名指しは赤" '^model_pin: PINNED settings\(~/.claude-work/settings.json = claude-fable-5\[1m\]\)'

setup; printf '{"model": "opus"}\n' > "${T}/home/.claude/settings.json"
expect "settings.json の alias は緑" '^model_pin: ok'

setup; printf '{not json\n' > "${T}/home/.claude/settings.json"
expect "壊れた settings.json では落ちない" '^model_pin: ok'

# --- effort_pin ---
setup; printf 'export CLAUDE_CODE_EFFORT_LEVEL=medium\n' > "${T}/home/.zshenv"
expect "zshenv の環境変数は赤" '^effort_pin: OVERRIDDEN launcher=high but zshenv\(CLAUDE_CODE_EFFORT_LEVEL\)'

setup; printf 'CLAUDE_CODE_EFFORT_LEVEL=low\n' > "${T}/home/.bash_profile"
expect "export 無しの代入も赤" '^effort_pin: OVERRIDDEN .*bash_profile'

setup; printf '# export CLAUDE_CODE_EFFORT_LEVEL=medium\n' > "${T}/home/.zshenv"
expect "comment にした行は緑" '^effort_pin: ok'

setup; TIER=normal; SESSION_EFFORT=medium
expect "launcher 起動の session で実効値が違えば赤" '^effort_pin: OVERRIDDEN launcher=high but session=medium'

setup; TIER=normal; SESSION_EFFORT=high
expect "実効値が launcher と同じなら緑" '^effort_pin: ok \(launcher=high, session=high\)'

setup; TIER=""; SESSION_EFFORT=medium
expect "launcher を通らない起動の実効値は比べない" '^effort_pin: ok \(launcher=high, session=unmeasured\)'

setup; launcher opus high '    command = [CLAUDE, "--model", MODEL]'
expect "--effort を渡さない launcher は UNPINNED" '^effort_pin: UNPINNED'

setup; rm "${T}/agent/.tooling/lib/claude-launch.py"
expect "launcher が無い派生は skip" '^model_pin: \(skipped, \.tooling/lib/claude-launch\.py not found\)'

echo "launch-pins: ${pass} ok, ${fail} FAIL"
[ "${fail}" -eq 0 ]
