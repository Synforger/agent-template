#!/bin/bash
# .tooling/startup/tab_health.py の test。 身代わりの ps・tmux・lsof・launchctl と作り物のタブの一覧を置き、
# server が 1 本で残り物が無い時に ok、 同じ名前の server が 2 本の時と一覧に無い session が在る時に WARN、
# 一覧が読めない時に UNKNOWN になる事を確かめる。
#
#   bash .tooling/tests/test-tab-health.sh
set -uo pipefail

CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/startup/tab_health.py"
PYTHON="$(command -v python3)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0
BIN="${T}/bin"
mkdir -p "${BIN}" "${T}/platform/state/claude-pwa-client/data"
export AGENT_PLATFORM_ROOT="${T}/platform"
META="${T}/platform/state/claude-pwa-client/data/session_meta.json"

# 身代わり: <server の pid を空白区切り> <tmux の session を空白区切り>
fake() {
    {
        echo '#!/bin/bash'
        for pid in $1; do
            echo "echo '${pid} tmux -L sock-x new-session -d -s claudepwa-sentinel -x 8 -y 2 /bin/sh'"
        done
        echo "echo '999 zsh -il'"
    } > "${BIN}/ps"
    printf '#!/bin/bash\nfor s in %s; do echo "$s"; done\n' "$2" > "${BIN}/tmux"
    printf '#!/bin/bash\nprintf "HEAD\\na\\nb\\n"\n' > "${BIN}/lsof"
    printf '#!/bin/bash\necho "maxfiles 256 unlimited"\n' > "${BIN}/launchctl"
    chmod +x "${BIN}"/*
}

check() { # <名前> <期待の正規表現>
    local out
    out="$(PATH="${BIN}:/usr/bin:/bin" "${PYTHON}" "${CHECK}")"
    if [[ "${out}" =~ $2 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: ${out}"; fi
}

echo '[{"id": "ses_a", "created_at": 0}, {"id": "ses_b", "created_at": 0}]' > "${META}"
fake "100" "claudepwa-sentinel pwa-ses_a pwa-ses_b"
check "1 本で残り無し" '^tab_health: ok \(タブ 2 \(24 時間で作られた 0\)・server の開いた file 2 \(天井 256\)\)$'

fake "100 200" "claudepwa-sentinel pwa-ses_a"
check "server 2 本" '^tab_health: WARN sock-x の server が 2 本 \(pid 100, 200\)'

fake "100" "claudepwa-sentinel pwa-ses_a pwa-ses_zz"
check "一覧に無い session" '^tab_health: WARN 一覧に無い tmux session 1 \(pwa-ses_zz\)'

rm -f "${META}"
check "一覧が読めない" '^tab_health: UNKNOWN \(タブの一覧を読めない'

echo "tab-health: pass=${pass} fail=${fail}"
[ "${fail}" -eq 0 ]
