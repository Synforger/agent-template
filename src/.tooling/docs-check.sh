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
# (= 派生固有の dir = ARIA `feelings/` 等を派生で宣言、 base には混入させない)
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
echo "[1/9] frontmatter チェック..."
for f in $ALL_MD; do
  if ! head -1 "$f" | grep -q '^---$'; then
    fail "$f: frontmatter なし (= 先頭 --- 欠落)"
    continue
  fi
  # frontmatter ブロック抽出
  fm=$(awk '/^---$/{c++; if(c==2) exit; next} c==1' "$f")
  # title / description は全 .md 必須 (= journal も含む)
  echo "$fm" | grep -qE '^title:' || fail "$f: frontmatter title 欠落"
  echo "$fm" | grep -qE '^description:' || warn "$f: frontmatter description 欠落 (= 推奨)"
  pass
done

# ===== 2. capacity チェック (= CLAUDE.md 容量表に対する突き合わせ) =====
echo "[2/9] capacity チェック..."

# CLAUDE.md 自身
size=$(wc -c < CLAUDE.md)
[ "$size" -gt 16384 ] && fail "CLAUDE.md: $size byte > 16KB 上限"

# profile / rules / projects/<mode> 主要ファイル
# 注: ハードコード配列は廃止 (= frontmatter `capacity:` 宣言で全 file 自己宣言 = 真値分散ゼロ)
# 個別チェックが必要な最小限のみ列挙 (= frontmatter なし or 別 cap)
declare -a CAP_FILES=(
  "rules/_README.md:6144"
  "journal/_README.md:5120"
)
# profile/profile-core.md / profile/_README.md は派生ごとに存在有無 + cap が異なる (= ARK profile-core 採用 16KB / ARIA okg/aria 2 極構造で profile-core.md 自体存在しない・profile/_README.md は 25KB)
# → ハードコードから外し、 frontmatter capacity の自己宣言に委ねる (= 真値分散ゼロ原則)
for entry in "${CAP_FILES[@]}"; do
  f="${entry%:*}"; cap="${entry##*:}"
  [ -f "$f" ] || { warn "$f: capacity 表に列挙されてるが実在しない"; continue; }
  size=$(wc -c < "$f")
  if [ "$size" -gt "$cap" ]; then
    fail "$f: $size byte > $cap byte 上限"
  else
    pass
  fi
done

# 会社プロジェクト配下 dev-env/<env>.md 群 (= gitignore 切離済の場合は this PC で空走、 OK)
for f in projects/*/rules/dev-env/*.md; do
  [ "$(basename "$f")" = "_README.md" ] && continue
  size=$(wc -c < "$f")
  cap=12288
  if [ "$(basename "$f")" = "windows-vm.md" ]; then
    cap=18432
  fi
  if [ "$size" -gt "$cap" ]; then
    cap_label="$((cap / 1024))KB"
    fail "$f: $size byte > $cap_label 上限"
  fi
done

# _README.md 系 (= 5KB)
for f in research/_README.md projects/_README.md todos/_README.md; do
  [ -f "$f" ] || continue
  size=$(wc -c < "$f")
  [ "$size" -gt 5120 ] && fail "$f: $size byte > 5KB 上限"
done

# frontmatter で capacity: 宣言してるファイルの突き合わせ
for f in $ALL_MD; do
  cap_decl=$(awk '/^---$/{c++; if(c==2) exit; next} c==1 && /^capacity:/' "$f" | head -1)
  [ -z "$cap_decl" ] && continue
  # "capacity: 10KB" or "10KB上限" 等 から数値抽出
  num=$(echo "$cap_decl" | grep -oE '[0-9]+' | head -1)
  [ -z "$num" ] && continue
  size=$(wc -c < "$f")
  declared=$((num * 1024))
  if [ "$size" -gt "$declared" ]; then
    fail "$f: $size byte > frontmatter 宣言 ${num}KB"
  fi
done

# ===== 3. _README.md 索引整合 (= フォルダ内 .md を全部言及) =====
echo "[3/9] 索引整合チェック..."
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
      warn "$readme: 同フォルダの $name に言及なし (= 索引漏れ?)"
    fi
  done
done

# ===== 4. dead link 検出 (= 相対参照の実在性) =====
echo "[4/9] dead link チェック..."
for f in $ALL_MD; do
  # archive 配下の md は dead link チェック対象外 (= 過去記録、 link は history snapshot)
  case "$f" in
    *archive/*) continue;;
  esac
  # `path/to/file.md` 形式の参照を抜く (= バックティック内)
  refs=$(grep -oE '`[a-zA-Z0-9_/.~-]+\.md`' "$f" 2>/dev/null | tr -d '`' | sort -u)
  for ref in $refs; do
    # placeholder / 雛形パターンは skip
    case "$ref" in
      *kebab-case*|*session-NN*|*_template*|*YYYY-MM*|*0000-*|*000X-*) continue;;
    esac
    case "$ref" in
      # 外部絶対 path (= ~/work/ ~/repos/ ~/Downloads/ ~/Library/ 等) は info、 警告しない
      "~/"*|"/"*) continue;;
      *)
        # エージェント 内部相対参照: $dir/$ref → $ref (リポルート) → リポ内同名ファイル
        # 最後の段は「ファイル名引用が dead 扱いされる」 false positive 対策
        # (= 切離済 file 名を inline-code で引用しただけのケース等)
        dir=$(dirname "$f")
        if [ ! -f "$dir/$ref" ] && [ ! -f "$ref" ]; then
          refname=$(basename "$ref")
          # README.md 引用は _README.md 慣習との対応 (= エージェント配下は _README.md
          # を使う、 README.md は外部 repo の引用慣習)
          if [ "$refname" = "README.md" ]; then continue; fi
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

# ===== 5. CLAUDE.md ↔ rules/always 重複検出 =====
echo "[5/9] CLAUDE.md ↔ rules/always 重複チェック..."
# 同じ文 (= 30 文字以上の連続文字列) が両方に存在するかをざっくり検出
# 完全自動化は難しいので、 大きいキーワード重複の存在感知レベルで止める
for always_f in rules/always/*.md; do
  [ -f "$always_f" ] || continue
  common=$(comm -12 \
    <(grep -oE '[一-龯ぁ-んァ-ヶ]{15,}' CLAUDE.md | sort -u) \
    <(grep -oE '[一-龯ぁ-んァ-ヶ]{15,}' "$always_f" | sort -u))
  if [ -n "$common" ]; then
    echo "$common" | while read -r line; do
      [ -n "$line" ] && warn "重複候補: \"$line\" が CLAUDE.md と $always_f 両方にあり"
    done
  fi
done

# ===== 6. placeholder 残し検査 (= 雛形 cp 後の埋め忘れ防止) =====
echo "[6/9] placeholder 残し チェック..."
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
        fail "$f: placeholder 残し → $line"
      done <<< "$hits"
    fi
  done
else
  warn "placeholder 真値 (= projects/_template-project) が空、 検査 skip"
fi
rm -f "$ph_tmpfile"

# ===== 7. 動的検索パターン検出 (= ls + head 動線残骸の機械検出) =====
echo "[7/9] 動的検索パターン チェック..."
# エージェント 親 rule (= CLAUDE / always / lazy / 索引 _README) に「動的検索 / ls + head」 残骸がないか
# 過去事故 = 「ls projects/ + 各 _README head」 で全プロジェクト走査 → mapping 集約で潰した (2026-06-29)
# 今後同じ動線が エージェント 親 rule に紛れ込まないよう機械検出
DYN_TARGETS="CLAUDE.md rules/always/*.md rules/lazy/*.md rules/_README.md profile/_README.md projects/_README.md .tooling/_README.md"
for pat in 'ls\s+(projects|rules)/[^_]' 'head\s+[^|]+_README' '各.*_README\.md.*(冒頭の|head する|を順次)' '順次走査' '動的検索方式'; do
  hits=$(grep -rlnE "$pat" $DYN_TARGETS 2>/dev/null | grep -v '/journal/' | grep -v '/_archive/' || true)
  if [ -n "$hits" ]; then
    while IFS= read -r hit; do
      [ -n "$hit" ] && warn "動的検索パターン残骸: $hit (= '$pat'、 mapping 集約候補)"
    done <<< "$hits"
  fi
done
pass

# ===== 8. プロジェクト folder 整合 (= folder 名 = 判定キーワード方式、 _README 不在 folder の検出) =====
echo "[8/9] プロジェクト folder 整合 チェック..."
# folder 名 = 判定キーワード方式に移行済 (= mapping 表廃止)、 本 step は「_README.md ある folder は判定対象」 「無い folder は死蔵 or 未成立」 を識別
for d in projects/*/; do
  name=$(basename "$d")
  case "$name" in _*) continue ;; esac  # _template-project / _archive 等は除外
  if [ ! -f "$d/_README.md" ]; then
    # tracked file 0 (= gitignore 切離済 e.g. 会社プロジェクト残骸) は除外
    if git ls-tree -r HEAD --name-only 2>/dev/null | grep -q "^projects/$name/"; then
      warn "folder 整合: projects/$name/ は _README.md 無し (= プロジェクト未成立、 _README 作成 or _archive 移送)"
    fi
  fi
done
pass

echo "[9/9] synced-paths 整合 チェック..."
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
    target="$ROOT/$line"
    if [ ! -e "$target" ]; then
      warn "synced-paths: $line 不在 (= sync 後に消えた可能性)"
      missing=$((missing+1))
      continue
    fi
    if [ -n "${BASE_REPO_PATH:-}" ]; then
      base_target="$BASE_REPO_PATH/src/$line"
      if [ -e "$base_target" ]; then
        if ! diff -rq "$target" "$base_target" > /dev/null 2>&1; then
          warn "synced-paths: $line が base と diff あり (= sync or promote 検討)"
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

# ===== サマリ =====
echo ""
echo "===== docs-check 結果 ====="
green "PASS: $PASS"
[ "$WARN" -gt 0 ] && yellow "WARN: $WARN" || echo "WARN: 0"
[ "$FAIL" -gt 0 ] && red "FAIL: $FAIL" || green "FAIL: 0"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
