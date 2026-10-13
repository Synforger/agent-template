#!/bin/bash
# .tooling/rules/build-rule-registry.py の test。 作り物の階層 (= 親 / project / subproject) で、
# ID の頭の文字が階層の深さで決まること (= 親 R- / project P- / subproject S-)、 文字を分ける前に
# R- で振られた階層の番号が、 番号はそのままで文字だけ直ること、 直した時刻が台帳の隣に 1 度だけ
# 書かれること、 検査だけの時は何も書かずに食い違いを報告することを確かめる。 FAIL 1 行ずつ。
#
#   bash .tooling/tests/test-build-rule-registry.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
pass=0
fail=0

# script は自分の置き場から階層の根を決めるので、 作り物の階層の中へ写して走らせる
PROJ="${T}/projects/demo"
SUB="${PROJ}/subprojects/sub"
mkdir -p "${T}/.tooling/rules" "${T}/.tooling/lib" "${T}/rules" "${PROJ}/rules" "${SUB}/rules"
cp "${HERE}/rules/build-rule-registry.py" "${T}/.tooling/rules/"
cp "${HERE}/lib/guard-may-write.py" "${T}/.tooling/lib/"
RUN="${T}/.tooling/rules/build-rule-registry.py"

printf '# rules\n\n## 基本\n\n- 親の決まり\n' > "${T}/rules/always.md"
printf '# demo\n\n## 基本\n\n- demo の決まり\n\n## 検証\n\n- demo の検証\n' > "${PROJ}/rules/always.md"
printf '# sub\n\n## 基本\n\n- sub の決まり\n' > "${SUB}/rules/always.md"
# project の階層は、 文字を分ける前に R- で振られた台帳を持つ (= 2 番は退役した節)
printf '%s\n' \
    '{"id": "R-0001", "file": "projects/demo/rules/always.md", "heading": "基本", "path": "基本", "level": 2, "retired": false}' \
    '{"id": "R-0002", "file": "projects/demo/rules/always.md", "heading": "昔の節", "path": "昔の節", "level": 2, "retired": true}' \
    > "${PROJ}/rules/registry.jsonl"
printf '%s\n' '{"by_id_since": "2026-01-02", "why": "test"}' > "${PROJ}/rules/hits-since.json"

# <説明> <file> <期待する正規表現> : file のどこかの行が一致すれば緑
holds() {
    if grep -qE -- "$3" "$2" 2>/dev/null; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$(tr '\n' '|' < "$2" 2>/dev/null)"
    fi
}
# <説明> <真になるはずの条件 (= 終了 code)>
ok() {
    if [ "$2" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; fi
}

before="$(cat "${PROJ}/rules/registry.jsonl")"
out="$(python3 "${RUN}" --check 2>&1)"; rc=$?
ok "検査だけの時は、 別の階層の文字を持つ台帳を食い違いとして返す (= exit 1)" "$([ "${rc}" -eq 1 ]; echo $?)"
ok "検査だけの時は、 何個の ID がどの文字であるべきかを言う" \
    "$(grep -qE "2 ids carry another tier's letter \(want P-\)" <<< "${out}"; echo $?)"
ok "検査だけの時は台帳を書き換えない" "$([ "$(cat "${PROJ}/rules/registry.jsonl")" = "${before}" ]; echo $?)"
ok "検査だけの時は、 直した時刻を書かない" "$(! grep -q lettered_since "${PROJ}/rules/hits-since.json"; echo $?)"

python3 "${RUN}" > /dev/null 2>&1
holds "親の ID は R-" "${T}/rules/registry.jsonl" '"id": "R-0001", "file": "rules/always.md", "heading": "基本"'
holds "project の ID は、 番号はそのままで文字だけ P- に直る" "${PROJ}/rules/registry.jsonl" \
    '"id": "P-0001", "file": "projects/demo/rules/always.md", "heading": "基本"'
holds "退役した行の ID も同じに直る (= 昔の記録の宛先が残る)" "${PROJ}/rules/registry.jsonl" \
    '"id": "P-0002", .*"heading": "昔の節", .*"retired": true'
holds "直した階層に足した節は、 続きの番号をその階層の文字で受け取る" "${PROJ}/rules/registry.jsonl" \
    '"id": "P-0003", .*"heading": "検証"'
ok "project の台帳に R- の行が残らない" "$(! grep -q '"id": "R-' "${PROJ}/rules/registry.jsonl"; echo $?)"
holds "subproject の ID は S-" "${SUB}/rules/registry.jsonl" '"id": "S-0001", .*"heading": "基本"'
holds "文字を直した階層は、 直した時刻を台帳の隣に持つ" "${PROJ}/rules/hits-since.json" \
    '"lettered_since": "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}"'
holds "既に在った宣言は残る" "${PROJ}/rules/hits-since.json" '"by_id_since": "2026-01-02"'
ok "最初から正しい文字で振った階層は、 直した時刻を持たない" "$([ ! -e "${SUB}/rules/hits-since.json" ]; echo $?)"

stamp="$(cat "${PROJ}/rules/hits-since.json")"
printf '\n## 後から足した節\n\n- 追記\n' >> "${PROJ}/rules/always.md"
python3 "${RUN}" > /dev/null 2>&1
ok "2 回目に回しても、 直した時刻は書き換わらない" "$([ "$(cat "${PROJ}/rules/hits-since.json")" = "${stamp}" ]; echo $?)"
out="$(python3 "${RUN}" --check 2>&1)"; rc=$?
ok "直した後の検査は緑" "$([ "${rc}" -eq 0 ] && grep -q 'in sync' <<< "${out}"; echo $?)"

echo "build-rule-registry: ${pass} ok, ${fail} FAIL"
[ "${fail}" -eq 0 ]
