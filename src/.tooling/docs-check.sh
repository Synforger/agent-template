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

red()    { printf "\033[31m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }

fail() { red   "  FAIL: $*"; FAIL=$((FAIL+1)); }
warn() { yellow "  WARN: $*"; WARN=$((WARN+1)); }
pass() { PASS=$((PASS+1)); }

# 対象 .md 全列挙
# 除外: CLAUDE.md (= 根本 config、 frontmatter なし設計) / journal (= 履歴、 遡及修正しない)
# 除外: _template (= 雛形、 docs 未実装) / messages (= 別系統)
# 除外: drafts/ (= 作業中ドラフト + Issue/notes 本文コピー、 frontmatter 不要)
#
# 派生固有除外: .tooling/local-excludes.txt があれば 1 行 1 path pattern を読んで動的追加
# (= 派生固有の dir を派生で宣言、 base には混入させない)
FIND_ARGS=(. -name "*.md"
  -not -path "./.git/*"
  -not -path "./.tooling/*"
  -not -path "./.claude/worktrees/*"
  -not -path "*/journal/*"
  -not -path "*/drafts/*"
  -not -path "*/_template*"
  -not -name "CLAUDE.md")
LOCAL_EXCLUDES="$ROOT/.tooling/local-excludes.txt"
if [ -f "$LOCAL_EXCLUDES" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    FIND_ARGS+=(-not -path "$line")
  done < "$LOCAL_EXCLUDES"
fi
ALL_MD=$(find "${FIND_ARGS[@]}" | sort)

# ===== 1. frontmatter 検査 =====
echo "[1/9] frontmatter check..."
for f in $ALL_MD; do
  if ! head -1 "$f" | grep -q '^---$'; then
    fail "$f: no frontmatter (missing leading ---)"
    continue
  fi
  # frontmatter ブロック抽出
  fm=$(awk '/^---$/{c++; if(c==2) exit; next} c==1' "$f")
  # title / description は全 .md 必須 (= journal も含む)
  echo "$fm" | grep -qE '^title:' || fail "$f: frontmatter title missing"
  echo "$fm" | grep -qE '^description:' || warn "$f: frontmatter description missing (recommended)"
  pass
done

# ===== 2. capacity チェック (= frontmatter capacity 宣言に一元化) =====
echo "[2/9] capacity check..."

# CLAUDE.md 自身 (= frontmatter なし設計、 ハードコード)
size=$(wc -c < CLAUDE.md)
[ "$size" -gt 17408 ] && fail "CLAUDE.md: $size bytes > 17KB limit"

# 他全 file は frontmatter `capacity:` 宣言で自己宣言 (= 真値分散ゼロ)
# 旧 _README.md ハードコード配列は 2026-06-30 廃止 (= 全 _README が frontmatter capacity 宣言済)
for f in $ALL_MD; do
  cap_decl=$(awk '/^---$/{c++; if(c==2) exit; next} c==1 && /^capacity:/' "$f" | head -1)
  [ -z "$cap_decl" ] && continue
  # "capacity: 10KB" or "10KB上限" 等 から数値抽出
  num=$(echo "$cap_decl" | grep -oE '[0-9]+' | head -1)
  [ -z "$num" ] && continue
  size=$(wc -c < "$f")
  declared=$((num * 1024))
  if [ "$size" -gt "$declared" ]; then
    # lazy 文書庫 + profile lazy = 目安 (WARN、 肥大許容、 byte 潰し強制しない)。
    # 常時 load 層 (= always.md / profile core / _README / CLAUDE) はハード FAIL。
    # 階層合計のハード制限は startup-status.sh static_capacity が担当。
    case "$f" in
      */profile/profile-core.md) fail "$f: $size bytes > declared capacity ${num}KB" ;;
      */lazy/*|*/profile/profile-*.md) warn "$f: $size bytes > soft capacity ${num}KB (目安)" ;;
      *) fail "$f: $size bytes > declared capacity ${num}KB" ;;
    esac
  fi
done

# ===== 3. _README.md 索引整合 (= フォルダ内 .md を全部言及) =====
echo "[3/9] index consistency check..."
for readme in $(find . -name "_README.md" -not -path "./.git/*" -not -path "./.claude/worktrees/*"); do
  # 明示的な索引セクションがある _README のみチェック対象
  # (policy 系 _README は同フォルダ内ファイルを列挙しないのが正常)
  if ! grep -qE '^##\s*(エントリ|ファイル|索引|各環境ファイル|エントリポイント)' "$readme"; then
    continue
  fi
  dir=$(dirname "$readme")
  for sibling in "$dir"/*.md; do
    [ -f "$sibling" ] || continue
    name=$(basename "$sibling")
    case "$name" in _README.md|_template.md|_template-*.md) continue;; esac
    base="${name%.md}"
    if ! grep -qF "$name" "$readme" && ! grep -qF "$base" "$readme"; then
      warn "$readme: sibling $name not mentioned (missing from the index?)"
    fi
  done
done

# ===== 4. dead link 検出 (= 相対参照の実在性) =====
echo "[4/9] dead link check..."
for f in $ALL_MD; do
  # 過去記録は dead link チェック対象外 (= link は当時の状態、 遡及修正しない)。
  # path 慣習 (= archive / history 配下) と frontmatter 宣言 (= status: snapshot)
  # の 2 経路。 後者は「削除せず status で管理する」 運用 (= research 等) の逃げ道
  case "$f" in
    *archive/*|*history/*) continue;;
  esac
  if awk '/^---$/{c++; if(c==2) exit; next} c==1' "$f" 2>/dev/null | grep -qE '^status: *snapshot'; then
    continue
  fi
  # .staledocs.yaml の docs スコープは staledocs がアンカー生存を担当
  # (= 同一 file の二重検証禁止)。 skip 範囲は .staledocs.yaml docs.include と
  # 対で保守する (= スコープ拡大時はここも広げる)
  if [ -f "$ROOT/.staledocs.yaml" ]; then
    case "$f" in
      ./rules/*|./profile/profile-core.md) continue;;
    esac
  fi
  # `path/to/file.md` 形式の参照を抜く (= バックティック内)
  refs=$(grep -oE '`[a-zA-Z0-9_/.~-]+\.md`' "$f" 2>/dev/null | tr -d '`' | sort -u)
  for ref in $refs; do
    # placeholder / 雛形パターン + 自動生成出力は skip
    # (= .tooling/_output/* は .gitignore 対象で派生で run 前は不在、 false positive 抑制)
    case "$ref" in
      *kebab-case*|*session-NN*|*_template*|*YYYY-MM*|*0000-*|*000X-*) continue;;
      *.tooling/_output/*) continue;;
    esac
    case "$ref" in
      # 外部絶対 path (= `~/...` / `/...`) は info、 警告しない
      "~/"*|"/"*) continue;;
      *)
        # エージェント 内部相対参照: $dir/$ref → $ref (リポルート) → リポ内同名ファイル
        # 最後の段は「ファイル名引用が dead 扱いされる」 false positive 対策
        # (= 切離済 file 名を inline-code で引用しただけのケース等)
        dir=$(dirname "$f")
        if [ ! -f "$dir/$ref" ] && [ ! -f "$ref" ]; then
          refname=$(basename "$ref")
          # 外部 repo の root 慣習 file 引用 (= エージェント配下は _README.md 慣習で
          # これらを持たない設計、 単体 file 名での引用は外部 repo 指しと確定)
          case "$refname" in
            README.md|CONTRIBUTING.md|SECURITY.md|ROADMAP.md|CHANGELOG.md|THIRD_PARTY_NOTICES.md) continue;;
          esac
          if [ -z "$(find . -name "$refname" -not -path "./.git/*" -not -path "./.claude/worktrees/*" -not -path "./.tooling/*" -print -quit 2>/dev/null)" ]; then
            # 第 1 階層 segment が エージェント配下に無い path は外部 repo 引用と推定 skip
            # (= work repo の `sdk/...` `app/...` `docs/...` `prototypes/...` 等、
            #  エージェント 内には該当階層がない引用は警告しない)
            first_seg="${ref%%/*}"
            if [ "$ref" = "$first_seg" ] || [ -d "$first_seg" ]; then
              warn "$f: dead link → $ref"
            fi
          fi
        fi
        ;;
    esac
  done
done

# ===== 重複検出は detect-duplicates.py に集約 (= section 単位 LCS、 project / subproject まで拡張済) =====
# 旧 step 5 (= CLAUDE.md ↔ rules/always の 15 字連続日本語 fragment 検出) は廃止
# 理由 = detect-duplicates.py が全 rule file を section 単位で網羅検出、 機能重複のため
# (= 2026-06-30 docs-check スリム化、 step 5 削除で 9→8 step)

# ===== 5. placeholder 残し検査 (= 雛形 cp 後の埋め忘れ防止) =====
echo "[5/9] leftover placeholder check..."
# 真値 = projects/_template-project/ 配下の全 .md から自動抽出 (= 構造ベース、 exact 一致 list を hard-code しない)
# 検出対象 = 雛形に登場する文字列のうち、 path 例示 false positive を構造的に分離:
#   - 二重中括弧 {{...}} = 全部 (= path 例示で {{...}} は普通使われない、 強 signal)
#   - 山括弧 <...> = 日本語文字 含むもののみ (= `<rule タイトル>` 等)。 短い英語識別子
#     (= `<project>` `<sub>` 等) は path 例示で多用されるため除外
# 除外: ALL_MD は既に _template* / journal / drafts 除外済、 追加で _archive / _output を除外
TEMPLATE_PLACEHOLDERS_RAW=$(find projects/_template-project -name "*.md" 2>/dev/null \
  -exec grep -hoE '\{\{[^}]+\}\}|<[^>]{1,80}>' {} \; \
  | sort -u)
ph_tmpfile=$(mktemp)
echo "$TEMPLATE_PLACEHOLDERS_RAW" | while IFS= read -r ph; do
  [ -z "$ph" ] && continue
  case "$ph" in
    '{{'*) echo "$ph" ;;
    '<'*)
      if echo "$ph" | grep -qE '[一-龯ぁ-んァ-ヶ]'; then
        echo "$ph"
      fi
      ;;
  esac
done > "$ph_tmpfile"
if [ -s "$ph_tmpfile" ]; then
  for f in $ALL_MD; do
    case "$f" in
      */_archive/*) continue ;;
      */_output/*)  continue ;;
    esac
    # fenced code block (= ```...```) 内は除外 (= 例示用 placeholder 慣習)。
    # 行番号付きで fenced 外行のみ抽出してから grep
    hits=$(awk 'BEGIN{infence=0} /^```/{infence=!infence; next} !infence {print NR ":" $0}' "$f" 2>/dev/null \
      | grep -Ff "$ph_tmpfile" 2>/dev/null || true)
    if [ -n "$hits" ]; then
      while IFS= read -r line; do
        fail "$f: leftover placeholder -> $line"
      done <<< "$hits"
    fi
  done
else
  warn "placeholder truth (projects/_template-project) is empty, skipping"
fi
rm -f "$ph_tmpfile"

# ===== 6. 動的検索パターン検出 (= ls + head 動線残骸の機械検出) =====
echo "[6/9] dynamic-search-pattern check..."
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
echo "[7/9] project folder consistency check..."
# folder 名 = 判定キーワード方式に移行済 (= mapping 表廃止)、 本 step は「_README.md ある folder は判定対象」 「無い folder は死蔵 or 未成立」 を識別
for d in projects/*/; do
  name=$(basename "$d")
  case "$name" in _*) continue ;; esac  # _template-project / _archive 等は除外
  if [ ! -f "$d/_README.md" ]; then
    # tracked file 0 (= gitignore 切離済 e.g. 会社プロジェクト残骸) は除外
    if git ls-tree -r HEAD --name-only 2>/dev/null | grep -q "^projects/$name/"; then
      warn "folder consistency: projects/$name/ has no _README.md (not a project yet — add _README or move to _archive)"
    fi
  fi
done
pass

echo "[8/9] synced-paths consistency check..."
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


# ===== [9/9] journal 整合 =====
# 検査軸: filename session-NN ↔ frontmatter session / 日付フォルダ ↔ frontmatter date /
#         normal 階層に mode≠normal (= 階層自己完結違反) / project 階層に mode=normal
echo "[9/9] journal integrity check..."
j_fail=0
while IFS= read -r jf; do
  base="$(basename "$jf")"
  nn="$(printf '%s' "$base" | sed -nE 's/^session-0*([0-9]+)\.md$/\1/p')"
  [ -z "$nn" ] && continue
  dir_date="$(basename "$(dirname "$jf")")"
  fm="$(awk '/^---$/{c++; next} c==1{print} c>=2{exit}' "$jf")"
  fm_session="$(printf '%s\n' "$fm" | sed -nE 's/^session: *"?0*([0-9]+)"?.*/\1/p' | head -1)"
  fm_date="$(printf '%s\n' "$fm" | sed -nE 's/^date: *"?([0-9]{4}-[0-9]{2}-[0-9]{2})"?.*/\1/p' | head -1)"
  fm_mode="$(printf '%s\n' "$fm" | sed -nE 's/^mode: *"?([^"]*)"?$/\1/p' | head -1)"
  if [ -n "$fm_session" ] && [ "$fm_session" != "$nn" ]; then
    fail "$jf: filename NN ($nn) does not match frontmatter session ($fm_session)"
    j_fail=$((j_fail+1))
  fi
  if [ -n "$fm_date" ] && [ "$fm_date" != "$dir_date" ]; then
    fail "$jf: date folder ($dir_date) does not match frontmatter date ($fm_date)"
    j_fail=$((j_fail+1))
  fi
  case "$jf" in
    ./projects/*/journal/*|./projects/*/subprojects/*/journal/*)
      if [ "$fm_mode" = "normal" ]; then
        fail "$jf: project-tier journal carries mode: normal (tier mix-up)"
        j_fail=$((j_fail+1))
      fi
      ;;
    ./journal/*)
      if [ -n "$fm_mode" ] && [ "$fm_mode" != "normal" ]; then
        fail "$jf: normal-tier journal carries mode: $fm_mode (tier self-containment violation)"
        j_fail=$((j_fail+1))
      fi
      ;;
  esac
done < <(find . -path ./.git -prune -o -type f -name 'session-*.md' -path '*/journal/*' -print 2>/dev/null)
[ "$j_fail" -eq 0 ] && pass

# ===== サマリ =====
echo ""
echo "===== docs-check results ====="
green "PASS: $PASS"
[ "$WARN" -gt 0 ] && yellow "WARN: $WARN" || echo "WARN: 0"
[ "$FAIL" -gt 0 ] && red "FAIL: $FAIL" || green "FAIL: 0"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
