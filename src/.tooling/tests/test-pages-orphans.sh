#!/bin/bash
# .tooling/startup/pages_orphans.py の test。 作り物の agent の根と `tabs` の身代わりを置き、 起動した階層の pages/ の
# 残り物が、 生きているタブ・別の機械のタブ・`_` 始まりを数えずに、 中身ありと雛形だけに分かれて出る事と、
# タブの一覧が読めない時に UNKNOWN になる事を確かめる。
#
#   bash .tooling/tests/test-pages-orphans.sh
set -uo pipefail

CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/startup/pages_orphans.py"
PYTHON="$(command -v python3)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

ROOT="${T}/agent"
BIN="${T}/bin"
mkdir -p "${BIN}"

# 身代わりの tabs を置く: <tabs list の出力> <終了コード>
fake_tabs() {
    printf '#!/bin/bash\n[ "$1" = list ] || exit 9\nprintf %%s %q\nexit %s\n' "$1" "$2" > "${BIN}/tabs"
    chmod +x "${BIN}/tabs"
}
# PATH は身代わりの folder だけにする (macOS の /usr/bin には、端末の tab 位置を決める別の tabs が在る)
run() { PATH="${BIN}" "${PYTHON}" "${CHECK}" --root "${ROOT}" "$@"; }

check() {
    local name="$1" got="$2" want="$3"
    if [ "${got}" = "${want}" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL ${name}"
        echo "  want: ${want}"
        echo "  got:  ${got}"
    fi
}

# 階層の pages/ を作る: <pages の folder>
make_pages() {
    local pages="$1"
    mkdir -p "${pages}/_template-tab" "${pages}/_common" "${pages}/_archive/ses_old"
    echo top > "${pages}/index.html"
    for id in ses_live ses_home ses_withpage ses_withdata ses_bare; do
        mkdir -p "${pages}/${id}"
        echo top > "${pages}/${id}/index.html"
        echo memo > "${pages}/${id}/memo.md"
    done
    mkdir -p "${pages}/ses_withpage/model" "${pages}/ses_withdata/data"
    echo page > "${pages}/ses_withpage/model/depth.html"
    echo 1 > "${pages}/ses_withdata/data/values.csv"
}

make_pages "${ROOT}/pages"
make_pages "${ROOT}/projects/見本/subprojects/親/pages"
LIST=$'ses_live  normal  口座=personal  busy  境界=なし  main  (= このタブ)\nhome:ses_home  別の機械  main'

fake_tabs "${LIST}" 0
check "normal の pages/ を、生きているタブ・別の機械のタブ・_ 始まりを外して分ける" \
    "$(run --tier normal)" \
    "pages_orphans: 3 (中身あり 2: ses_withdata ses_withpage / 雛形だけ 1: ses_bare)"
check "AGENT_TIER の階層の pages/ を見る" \
    "$(AGENT_TIER=projects/見本/subprojects/親 run)" \
    "pages_orphans: 3 (中身あり 2: ses_withdata ses_withpage / 雛形だけ 1: ses_bare)"
check "pages/ の無い階層は 0" "$(run --tier projects/見本)" "pages_orphans: 0 (この階層に pages/ が無い)"

LIVE="${T}/live.txt"
printf 'ses_live\nses_home\nses_withpage\nses_withdata\nses_bare\n' > "${LIVE}"
check "全部が生きているタブなら 0" "$(run --tier normal --live-ids "${LIVE}")" "pages_orphans: 0"

fake_tabs "" 1
check "tabs list が失敗したら UNKNOWN" "$(run --tier normal)" "pages_orphans: UNKNOWN (tabs list が読めない (PWA のタブの外))"
rm -f "${BIN}/tabs"
check "tabs が無ければ UNKNOWN" "$(run --tier normal)" "pages_orphans: UNKNOWN (tabs が無い)"

echo "test-pages-orphans: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
