#!/bin/bash
# 横の目次の部品を根から直に読む形の test。 作り物のエージェントの根 (= 根・プロジェクト・サブプロジェクトの階層と、
# タブ・枝 (2 段まで) のページ) を組み、 install_toc.py が根の部品への正しい相対の 1 行を入れ、 2 回流しても増えず、
# 階層の写しを指す古い行を直し、 写しを作らない事と、 check-tab-links.py が誤った path と階層に残った写しを名指して
# 正しい形を 0 件にする事を確かめる。 部品は、 タブのトップを自分の置き場でなくページの URL から決める事を、
# node で topPage() だけを取り出して 4 つの場面で確かめる (node が無い時は skip と名乗る)。
#
#   bash .tooling/local-ci/test-explainer-pages-toc.sh   (= `task ci` が呼ぶ)
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../src" && pwd)"
SKILL_SCRIPTS="${SRC}/.claude/skills/explainer-pages/scripts"
COMPONENT="${SRC}/pages/_common/toc-sidebar.js"
# script は resolve した path を出すので、 macOS の /var → /private/var の link を作業の folder から外しておく
T="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

AGENT="${T}/agent"
INSTALL="${AGENT}/.claude/skills/explainer-pages/scripts/install_toc.py"
CHECK="${AGENT}/.claude/skills/explainer-pages/scripts/check-tab-links.py"

check() { # <説明> <期待> <実際>
    if [ "$3" = "$2" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1"
        echo "  want: $2"
        echo "  got:  $3"
    fi
}

# ページ 1 本を書く: <path> <本文のリンク>
page() {
    mkdir -p "$(dirname "$1")"
    printf '<html><body>\n<main><h1>t</h1>%s</main>\n</body></html>\n' "${2:-}" > "$1"
}
# ページが部品を読む行の path (= 1 行も無ければ空)
loaded() { sed -n 's/.*<script src="\([^"]*toc-sidebar.js\)".*/\1/p' "$1"; }

# 作り物の根: 根・プロジェクト P・P の下のサブプロジェクト S。 タブは階層ごとに 1 つ、 P のタブは枝を 2 段まで持つ
mkdir -p "${AGENT}/.claude/skills/explainer-pages/scripts" "${AGENT}/pages/_common"
cp "${SKILL_SCRIPTS}/install_toc.py" "${SKILL_SCRIPTS}/check-tab-links.py" "${AGENT}/.claude/skills/explainer-pages/scripts/"
cp "${COMPONENT}" "${AGENT}/pages/_common/toc-sidebar.js"
for tier in "" projects/P/ projects/P/subprojects/S/; do
    mkdir -p "${AGENT}/${tier}"
    echo "# v" > "${AGENT}/${tier}vision.md"
done
ROOT_PAGES="${AGENT}/pages"
P_PAGES="${AGENT}/projects/P/pages"
S_PAGES="${AGENT}/projects/P/subprojects/S/pages"
page "${ROOT_PAGES}/index.html"
page "${ROOT_PAGES}/ses_root/index.html" '<a href="x.html">x</a>'
page "${ROOT_PAGES}/ses_root/x.html"
page "${P_PAGES}/index.html"
page "${P_PAGES}/ses_tab/index.html" '<a href="model/a.html">a</a><a href="model/deep/c.html">c</a>'
page "${P_PAGES}/ses_tab/model/a.html"
page "${P_PAGES}/ses_tab/model/deep/c.html"
page "${S_PAGES}/ses_sub/index.html" '<a href="branch/b.html">b</a>'
page "${S_PAGES}/ses_sub/branch/b.html"
# 組み立ての元 (= src/ の下と、 名前に template を含む物) は触らない
page "${P_PAGES}/ses_tab/src/build.html"
page "${P_PAGES}/ses_tab/model/chart-template.html"

# --- install_toc.py: 入れる ---
out="$(python3 -I "${INSTALL}" "${ROOT_PAGES}" "${AGENT}/projects" 2>&1)"
check "install: 部品を読む行が無かった 9 本に入れる" "9" "$(printf '%s\n' "${out}" | grep -c '^added: ')"
check "install: 組み立ての元 2 本は skipped" "2" "$(printf '%s\n' "${out}" | grep -c '^skipped: ')"
check "install: 出力はページ 1 本に 1 行" "11" "$(printf '%s\n' "${out}" | grep -c .)"
check "install: 根のタブのページ" "../_common/toc-sidebar.js" "$(loaded "${ROOT_PAGES}/ses_root/x.html")"
check "install: プロジェクトの階層のトップ" "../../../pages/_common/toc-sidebar.js" "$(loaded "${P_PAGES}/index.html")"
check "install: プロジェクトのタブのトップ" "../../../../pages/_common/toc-sidebar.js" "$(loaded "${P_PAGES}/ses_tab/index.html")"
check "install: プロジェクトのタブの枝 (1 段)" "../../../../../pages/_common/toc-sidebar.js" "$(loaded "${P_PAGES}/ses_tab/model/a.html")"
check "install: プロジェクトのタブの枝 (2 段)" "../../../../../../pages/_common/toc-sidebar.js" "$(loaded "${P_PAGES}/ses_tab/model/deep/c.html")"
check "install: サブプロジェクトのタブの枝" "../../../../../../../pages/_common/toc-sidebar.js" "$(loaded "${S_PAGES}/ses_sub/branch/b.html")"
check "install: 組み立ての元には入れない" "" "$(loaded "${P_PAGES}/ses_tab/src/build.html")$(loaded "${P_PAGES}/ses_tab/model/chart-template.html")"
check "install: 階層に部品の写しを作らない" "0" "$(find "${AGENT}/projects" -name 'toc-sidebar.js' | wc -l | tr -d ' ')"

# --- install_toc.py: 2 回流しても増えない ---
before="$(find "${AGENT}/pages" "${AGENT}/projects" -name '*.html' -exec cksum {} + | sort)"
out="$(python3 -I "${INSTALL}" "${ROOT_PAGES}" "${AGENT}/projects" 2>&1)"
check "install: 2 回目は全部 ok (組み立ての元の 2 本は skipped)" "9 2" "$(printf '%s\n' "${out}" | grep -c '^ok: ') $(printf '%s\n' "${out}" | grep -c '^skipped: ')"
check "install: 2 回目はページを書き換えない" "${before}" "$(find "${AGENT}/pages" "${AGENT}/projects" -name '*.html' -exec cksum {} + | sort)"
check "install: 部品を読む行は 1 本に 1 行" "1" "$(grep -c 'toc-sidebar.js' "${P_PAGES}/ses_tab/model/a.html")"

# --- install_toc.py: 階層の写しを指す古い行を直す ---
sed -i.bak 's#src="[^"]*"#src="../_common/toc-sidebar.js"#' "${P_PAGES}/ses_tab/model/a.html" && rm -f "${P_PAGES}/ses_tab/model/a.html.bak"
out="$(python3 -I "${INSTALL}" "${P_PAGES}/ses_tab/model/a.html" 2>&1)"
check "install: 古い行は fixed と出す" "fixed: ${P_PAGES}/ses_tab/model/a.html" "${out}"
check "install: 古い行を根の部品への path に直す" "../../../../../pages/_common/toc-sidebar.js" "$(loaded "${P_PAGES}/ses_tab/model/a.html")"

# --- check-tab-links.py: 正しい形は 0 件 ---
for tab in "${ROOT_PAGES}/ses_root" "${P_PAGES}/ses_tab" "${S_PAGES}/ses_sub"; do
    out="$(python3 -I "${CHECK}" "${tab}" 2>&1)"
    check "check: 正しい形は 0 件 (${tab#"${AGENT}/"})" "0 ok: ${tab} のトップページから全部辿れる" "$? ${out}"
done

# --- check-tab-links.py: 誤った path と、 階層に残った写しを名指す ---
sed -i.bak 's#src="[^"]*"#src="../_common/toc-sidebar.js"#' "${P_PAGES}/ses_tab/model/deep/c.html" && rm -f "${P_PAGES}/ses_tab/model/deep/c.html.bak"
mkdir -p "${P_PAGES}/_common"
cp "${COMPONENT}" "${P_PAGES}/_common/toc-sidebar.js"
out="$(python3 -I "${CHECK}" "${P_PAGES}/ses_tab" 2>&1)"
code=$?
check "check: 誤った path と写しの残りがあれば 1 で終わる" "1" "${code}"
check "check: 誤った path のページと、 その path と正しい path を名指す" \
    "横の目次を読む path が違う: model/deep/c.html は ../_common/toc-sidebar.js、正しくは ../../../../../../pages/_common/toc-sidebar.js (install_toc.py で直す)" \
    "$(printf '%s\n' "${out}" | grep '横の目次を読む path が違う')"
check "check: 階層に残った写しを名指して消すよう言う" \
    "階層に横の目次の部品の写しが残っている: ${P_PAGES}/_common/toc-sidebar.js (消す。ページは根の部品を直に読む)" \
    "$(printf '%s\n' "${out}" | grep '写しが残っている')"
check "check: 名指すのはその 2 件だけ" "2" "$(printf '%s\n' "${out}" | grep -c .)"

# 直して写しを消せば、 また 0 件
python3 -I "${INSTALL}" "${P_PAGES}/ses_tab" > /dev/null 2>&1
rm -r "${P_PAGES}/_common"
out="$(python3 -I "${CHECK}" "${P_PAGES}/ses_tab" 2>&1)"
check "check: 直して写しを消すと 0 件に戻る" "0 ok: ${P_PAGES}/ses_tab のトップページから全部辿れる" "$? ${out}"

# --- _archive/ の下: 在る行は直し、 無い行は足さない。 check は写しを指す行を名指す ---
page "${P_PAGES}/ses_tab/_archive/old.html"
printf '<html><body><script src="../../_common/toc-sidebar.js" defer></script>\n</body></html>\n' > "${P_PAGES}/ses_tab/_archive/kept.html"
out="$(python3 -I "${CHECK}" "${P_PAGES}/ses_tab" 2>&1)"
check "check: _archive/ の下で写しを指すページを名指す" \
    "\`_archive/\` のページが横の目次を違う path で読む: _archive/kept.html は ../../_common/toc-sidebar.js、正しくは ../../../../../pages/_common/toc-sidebar.js (install_toc.py で直す。写しを消す前に)" \
    "$(printf '%s\n' "${out}" | grep '_archive')"
# 組み立ての元 (`src/` の下の雛形) は、 書き出し先から見た path を持つので、 _archive/ の下でも数えない
mkdir -p "${P_PAGES}/ses_tab/_archive/x/src"
printf '<html><body><script src="../../../../../pages/_common/toc-sidebar.js" defer></script>\n</body></html>\n' > "${P_PAGES}/ses_tab/_archive/x/src/template.html"
check "check: _archive/ の下の組み立ての元は名指さない" "" "$(python3 -I "${CHECK}" "${P_PAGES}/ses_tab" 2>&1 | grep 'template.html')"
python3 -I "${INSTALL}" "${P_PAGES}/ses_tab" > /dev/null 2>&1
check "install: _archive/ の下の在る行を根の部品へ直す" "../../../../../pages/_common/toc-sidebar.js" "$(loaded "${P_PAGES}/ses_tab/_archive/kept.html")"
check "install: _archive/ の下の行の無いページには足さない" "" "$(loaded "${P_PAGES}/ses_tab/_archive/old.html")"
out="$(python3 -I "${CHECK}" "${P_PAGES}/ses_tab" 2>&1)"
check "check: _archive/ を直すと 0 件に戻る" "0 ok: ${P_PAGES}/ses_tab のトップページから全部辿れる" "$? ${out}"

# --- 部品: タブのトップをページ自身の URL から決める (= 部品の置き場に依らない) ---
if command -v node > /dev/null 2>&1; then
    out="$(node - "${COMPONENT}" <<'JS'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");
// 部品の中から、 INDEX_PAGE・PAGES_FOLDER・pageUrl・topPage だけを取り出して動かす (= 部品は DOM が無いと全体を動かせない)
const pick = (pattern, name) => {
  const found = source.match(pattern);
  if (!found) { console.log(`FAIL 部品の中に ${name} が見つからない`); process.exit(0); }
  return found[0];
};
const parts = [
  pick(/var INDEX_PAGE = [^;]+;/, "INDEX_PAGE"),
  pick(/var PAGES_FOLDER = [^;]+;/, "PAGES_FOLDER"),
  pick(/  function pageUrl\([\s\S]*?\n  }\n/, "pageUrl"),
  pick(/  function topPage\([\s\S]*?\n  }\n/, "topPage"),
].join("\n");
const topPage = new Function(parts + "\nreturn topPage;")();
const host = "https://host.example/agent";
const cases = [
  ["根のタブ直下", "/pages/ses_a/x.html", "/pages/ses_a/index.html", true],
  ["根のタブの枝の中", "/pages/ses_a/model/deep/x.html", "/pages/ses_a/index.html", true],
  ["別の階層のタブの枝の中", "/projects/AP/pages/ses_a/model/x.html", "/projects/AP/pages/ses_a/index.html", true],
  ["サブプロジェクトの階層のタブの枝の中", "/projects/AP/subprojects/S/pages/ses_a/b/x.html", "/projects/AP/subprojects/S/pages/ses_a/index.html", true],
  ["/pages/ の無いページ", "/projects/AP/research/explainer/x.html", "/projects/AP/research/explainer/index.html", false],
  ["階層の pages/ 直下のページ", "/projects/AP/pages/index.html", "/projects/AP/pages/index.html", false],
];
for (const [name, path, wantPath, wantIsTab] of cases) {
  const got = topPage(host + path);
  const ok = got.url === host + wantPath && got.isTab === wantIsTab;
  console.log(ok ? `ok ${name}` : `FAIL ${name}: want ${wantPath} ${wantIsTab}, got ${got.url.slice(host.length)} ${got.isTab}`);
}
JS
)"
    check "部品: topPage の 6 場面" "6 0" "$(printf '%s\n' "${out}" | grep -c '^ok ') $(printf '%s\n' "${out}" | grep -c '^FAIL')"
    printf '%s\n' "${out}" | grep '^FAIL'
else
    echo "SKIP: node が無いので、 部品の topPage() の試験を飛ばす"
fi

echo "explainer-pages-toc: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
