#!/usr/bin/env bash
# Agent docs 鮮度チェッカー (= agent-template 由来、 派生エージェント repo で使用)
# 走らせ方: <agent-repo-root>/.tooling/docs-check.sh
# 用途: 派生エージェント repo 配下の .md を機械検査 (frontmatter / capacity / 索引 / dead link / placeholder / 動的検索 / プロジェクト整合 / synced-paths)
# rules/lazy/docs-sweep の docs sweep を repo 全体に適用する。 セッション終了 Step 2 で必須実行
set -uo pipefail

# script 位置から repo root を決定 (= 派生 repo で動く前提、 エージェント 固有 path を持たない)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || { echo "repo root not found: $ROOT"; exit 2; }

PASS=0
FAIL=0
WARN=0
# 自分がどれだけ待たせたかを最後に名乗る (= 遅くなったことに気づけるのは数字が出ている時だけ。
# 閾値で止めはしない ― 仕方ないのか壊れているのかは、数字を見てから中身を読んで決める)
_T0="${EPOCHREALTIME:-$(date +%s)}"

red()    { printf "\033[31m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }

fail() { red   "  FAIL: $*"; FAIL=$((FAIL+1)); }
warn() { yellow "  WARN: $*"; WARN=$((WARN+1)); }
pass() { PASS=$((PASS+1)); }

# 走査系 5 step (= frontmatter / capacity / 索引整合 / dead link / placeholder) は
# 同じ .md を何度も開き直し、 対象列挙のために ツリーを何周もしていた。 走査も読み込みも
# 1 回で足りるので docs-scan.py に集約し、 ここでは結果を受け取るだけにする。
#
# 検査対象 = 全 .md から以下を除いたもの:
#   CLAUDE.md (= 根本 config、 frontmatter なし設計) / journal (= 履歴、 遡及修正しない)
#   _template (= 雛形) / drafts (= 作業中ドラフト) / _scratch (= 残す前提の無い一時 file)
# 派生固有除外: .tooling/local-excludes.txt (= 1 行 1 path pattern、 base に混入させない)
SCAN_OUT=$(mktemp)
trap 'rm -f "$SCAN_OUT"' EXIT
python3 .tooling/lib/docs-scan.py --local-excludes "$ROOT/.tooling/local-excludes.txt" > "$SCAN_OUT"

# scan 結果のうち指定 step の行だけを元の loop 順で出す
emit_step() {
  local want="$1" s lvl msg
  while IFS=$'\t' read -r s lvl msg; do
    [ "$s" = "$want" ] || continue
    case "$lvl" in
      fail) fail "$msg" ;;
      warn) warn "$msg" ;;
      pass) PASS=$((PASS + msg)) ;;
    esac
  done < "$SCAN_OUT"
}

# ===== 1. frontmatter 検査 =====
echo "[1/14] frontmatter check..."
# title / description は全 .md 必須 (= journal も含む)
emit_step 1

# ===== 2. capacity チェック (= frontmatter capacity 宣言に一元化) =====
echo "[2/14] capacity check..."
# CLAUDE.md 自身は frontmatter なし設計なので 17KB をハードコード、 他全 file は
# frontmatter `capacity:` の自己宣言 (= 真値分散ゼロ)。 lazy 文書庫と profile lazy は
# 目安 (= WARN)、 常時 load 層はハード FAIL。 階層合計は startup-status.sh が担当。
emit_step 2

# ===== 3. _README.md 索引整合 (= フォルダ内 .md を全部言及) =====
echo "[3/14] index consistency check..."
# 明示的な索引セクションがある _README のみチェック対象
# (policy 系 _README は同フォルダ内ファイルを列挙しないのが正常)
emit_step 3

# ===== 4. dead link 検出 (= 相対参照の実在性) =====
echo "[4/14] dead link check..."
# 過去記録は対象外 (= link は当時の状態、 遡及修正しない)。 path 慣習 (= archive /
# history 配下) と frontmatter 宣言 (= status: snapshot) の 2 経路。
# .staledocs.yaml の docs スコープは staledocs がアンカー生存を担当 (= 二重検証禁止)。
# 判定は「$dir/$ref → $ref → repo 内同名 file」 の 3 段で、 最後の段は file 名引用を
# dead 扱いしないための false positive 対策。
emit_step 4

# ===== 重複検出は detect-duplicates.py に集約 (= section 単位 LCS、 project / subproject まで拡張済) =====
# 旧 step 5 (= CLAUDE.md ↔ rules/always の 15 字連続日本語 fragment 検出) は廃止
# 理由 = detect-duplicates.py が全 rule file を section 単位で網羅検出、 機能重複のため
# (= 2026-06-30 docs-check スリム化、 step 5 削除で 9→8 step)

# ===== 5. placeholder 残し検査 (= 雛形 cp 後の埋め忘れ防止) =====
echo "[5/14] leftover placeholder check..."
# 真値 = projects/_template-project/ 配下の全 .md から自動抽出 (= 構造ベース、 exact 一致 list を hard-code しない)
# 検出対象 = 雛形に登場する文字列のうち、 path 例示 false positive を構造的に分離:
#   - 二重中括弧 {{...}} = 全部 (= path 例示で {{...}} は普通使われない、 強 signal)
#   - 山括弧 <...> = 日本語文字 含むもののみ (= `<rule タイトル>` 等)。 短い英語識別子
#     (= `<project>` `<sub>` 等) は path 例示で多用されるため除外
# fenced code block 内は例示用 placeholder の慣習なので除外する
emit_step 5

# ===== 6. 動的検索パターン検出 (= ls + head 動線残骸の機械検出) =====
echo "[6/14] dynamic-search-pattern check..."
# エージェント 親 rule (= CLAUDE / always / lazy / 索引 _README) に「動的検索 / ls + head」 残骸がないか
# 過去事故 = 「ls projects/ + 各 _README head」 で全プロジェクト走査 → mapping 集約で潰した (2026-06-29)
# 今後同じ動線が エージェント 親 rule に紛れ込まないよう機械検出
# 除外: CLAUDE.md / projects/_README.md (= 判定動線説明の真値 file、 ls projects/ 言及は設計の中核説明として必要)
# 対象外: `ls projects/<P>/...` の placeholder 形 (= 確定済 1 プロジェクト配下の列挙、
# 事故動線は「全プロジェクト走査」 なので placeholder 経由は構造的に別物)
DYN_TARGETS="rules/always.md rules/always/*.md rules/lazy/*.md rules/_README.md profile/_README.md .tooling/_README.md"
for pat in 'ls\s+(projects|rules)/[^_<]' 'head\s+[^|]+_README' '各.*_README\.md.*(冒頭の|head する|を順次)' '順次走査' '動的検索方式'; do
  hits=$(grep -rlnE "$pat" $DYN_TARGETS 2>/dev/null | grep -v '/journal/' | grep -v '/_archive/' || true)
  if [ -n "$hits" ]; then
    while IFS= read -r hit; do
      [ -n "$hit" ] && warn "dynamic-search residue: $hit (pattern '$pat', consider consolidating into a mapping)"
    done <<< "$hits"
  fi
done
pass

# ===== 7. プロジェクト folder 整合 (= folder 名 = 判定キーワード方式、 _README 不在 folder の検出) =====
echo "[7/14] project folder consistency check..."
# folder 名 = 判定キーワード方式に移行済 (= mapping 表廃止)、 本 step は「_README.md ある folder は判定対象」 「無い folder は死蔵 or 未成立」 を識別
# tracked file 一覧は 1 度だけ取る。 パイプの後段に grep -q を置くと、 早期終了が
# 前段を SIGPIPE で殺し pipefail が非ゼロを返すので、 判定が常に false になる
# (= 索引を引く側の条件が丸ごと死ぬ)。 here-string で受けてパイプを挟まない。
TRACKED_FILES=$(git ls-tree -r HEAD --name-only 2>/dev/null || true)
for d in projects/*/; do
  name=$(basename "$d")
  case "$name" in _*) continue ;; esac  # _template-project / _archive 等は除外
  if [ ! -f "$d/_README.md" ]; then
    # tracked file 0 (= gitignore 切離済 e.g. 会社プロジェクト残骸) は除外
    if grep -q "^projects/$name/" <<< "$TRACKED_FILES"; then
      warn "folder consistency: projects/$name/ has no _README.md (not a project yet — add _README or move to _archive)"
    fi
  fi
done
pass

echo "[8/14] synced-paths consistency check..."
# agent-template 由来の派生 repo であれば .synced-paths.txt が root にある。
# 列挙された path が repo に実在することをチェック、 および base ↔ 派生 diff を検出。
# base 側比較は BASE_REPO_PATH 環境変数があれば実施 (= ローカル比較)、 無ければ skip。
SP_FILE="$ROOT/.synced-paths.txt"
if [ -f "$SP_FILE" ]; then
  missing=0
  drift=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    # `!` prefix = sync 対象外の明示宣言 (= 派生に降ろさない file、 実在検査の対象外)
    case "$line" in "!"*) continue ;; esac
    target="$ROOT/$line"
    if [ ! -e "$target" ]; then
      warn "synced-paths: $line missing (possibly deleted after a sync)"
      missing=$((missing+1))
      continue
    fi
    if [ -n "${BASE_REPO_PATH:-}" ]; then
      base_target="$BASE_REPO_PATH/src/$line"
      if [ -e "$base_target" ]; then
        if ! diff -rq "$target" "$base_target" > /dev/null 2>&1; then
          warn "synced-paths: $line differs from base (consider sync or promote)"
          drift=$((drift+1))
        fi
      fi
    fi
  done < "$SP_FILE"
  if [ "$missing" -eq 0 ] && [ "$drift" -eq 0 ]; then
    pass
  fi
else
  # .synced-paths.txt が無い = agent-template 本体 or 派生でない repo、 skip
  pass
fi


# ===== [9/14] journal 整合 =====
# 検査軸: filename session-NN ↔ frontmatter session / 日付フォルダ ↔ frontmatter date /
#         normal 階層に mode≠normal (= 階層自己完結違反) / project 階層に mode=normal
echo "[9/14] journal integrity check..."
j_fail=0
while IFS= read -r v; do
  [ -z "$v" ] && continue
  fail "$v"
  j_fail=$((j_fail+1))
done < <(python3 .tooling/lib/journal-integrity.py 2>/dev/null)
[ "$j_fail" -eq 0 ] && pass

# ===== 10. 階層インターフェース =====
# project / subproject の必須 file / dir 検査 (= 真値 = projects/_README.md § 階層インターフェース)
# _ prefix folder (= 雛形 / system) は除外。 gitignore 済み project も同一契約 (= 存在するものは検査)
echo "[10/14] hierarchy interface check..."
h_fail=0
for p in projects/*/ projects/*/subprojects/*/; do
  [ -d "$p" ] || continue
  h_base="$(basename "$p")"
  case "$h_base" in _*) continue ;; esac
  case "$p" in */_template-project/*) continue ;; esac
  for req in _README.md rules/always.md rules/lazy/_README.md; do
    [ -f "${p}${req}" ] || { fail "$p: hierarchy interface missing file → $req"; h_fail=1; }
  done
  for req in journal todos; do
    [ -d "${p}${req}" ] || { fail "$p: hierarchy interface missing dir → $req"; h_fail=1; }
  done
  # vision.md は移行中のため WARN (= 既存階層は次にその階層で起動した session で作る)
  [ -f "${p}vision.md" ] || warn "$p: vision.md not created yet (write it at session end for this tier)"
done
[ "$h_fail" -eq 0 ] && pass

# ===== 11. ルール台帳の整合 =====
# rules/registry.jsonl が全 rule section を網羅しているか (= 発火記録の宛先が切れていないか)。
# 見出しの改名 / section の増減で紐付けが切れるので、 本体を触った session 内で検出する。
echo "[11/14] rule registry check..."
reg_out=$(python3 .tooling/build-rule-registry.py --check 2>/dev/null)
if [ -n "$reg_out" ] && ! printf '%s' "$reg_out" | grep -q "in sync"; then
  while IFS= read -r rl; do
    [ -n "$rl" ] && warn "$rl"
  done <<< "$reg_out"
else
  pass
fi

# ===== 12. ルール参照先の実在 =====
# ルールが指す repo 内 file が消えた / 改名された時に、 書いた場所で落とす
# (= 陳腐化した記述は「在る」 と思って探す時間を奪う。 真値 = rules/always.md § meta ③)
# work repo の path / 裸の file 名 / placeholder はこの repo から実在を測れないので対象外
echo "[12/14] rule reference check..."
r_fail=0
while IFS=$'\t' read -r rfile rref; do
  [ -z "$rfile" ] && continue
  fail "rule reference: $rfile → $rref (not found — fix the path or drop the line)"
  r_fail=$((r_fail+1))
done < <(python3 .tooling/lib/check-rule-references.py 2>/dev/null)
[ "$r_fail" -eq 0 ] && pass

# ===== 13. 発火記録の書き漏らし =====
# 発火実績は「どのルールを捨てるか」 の唯一の根拠なので、 書かれない session があると
# 根拠が欠け、 容量が詰まった時に「古いものから捨てる」 へ戻る。
# その階層が記録を書き始めた日以降だけを見る (= 機構より前の journal は遡って責めない)
echo "[13/14] rule-hits coverage check..."
m_warn=0
while IFS= read -r mj; do
  [ -z "$mj" ] && continue
  warn "rule-hits missing: $mj (no session-NN-rule-hits.jsonl beside it)"
  m_warn=$((m_warn+1))
done < <(python3 .tooling/lib/check-rule-hits.py 2>/dev/null)
[ "$m_warn" -eq 0 ] && pass

# ===== 14. vision の形 =====
# vision は「長期の状態」 を 1 枚で持つ file だが、 実作業が毎日走る階層ほど
# 「その日わかったこと」 が段落として積まれ、 journal の要約に化ける。
# 文章側には既に「段落を増やさず既にある行を書き換える」 と書いてあり、
# 守られなかったので機械で赤くする (= 節名と上限の根拠は script の docstring)。
echo "[14/14] vision shape check..."
v_fail=0
while IFS=$'\t' read -r vfile vmsg; do
  [ -z "$vfile" ] && continue
  fail "$vfile: $vmsg"
  v_fail=$((v_fail+1))
done < <(python3 .tooling/lib/check-vision-shape.py 2>/dev/null)
[ "$v_fail" -eq 0 ] && pass

# ===== サマリ =====
echo ""
echo "===== docs-check results ====="
green "PASS: $PASS"
[ "$WARN" -gt 0 ] && yellow "WARN: $WARN" || echo "WARN: 0"
[ "$FAIL" -gt 0 ] && red "FAIL: $FAIL" || green "FAIL: 0"
awk -v a="$_T0" -v b="${EPOCHREALTIME:-$(date +%s)}" 'BEGIN{printf "elapsed: %.1fs\n", b-a}'

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
