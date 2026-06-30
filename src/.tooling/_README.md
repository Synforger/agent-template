---
title: .tooling/ — 自動化スクリプト群
description: LLM 不使用、 token ゼロの自動化機構一覧
updated: 2026-06-29
---

# .tooling/ — 自動化スクリプト群

全 script は LLM 不使用、 token 自動消費ゼロ。 git log + regex + grep で機械抽出。

## script 一覧

真値は `rules/lazy/automation-machinery.md § 機構と発火` 参照 (= 役割 / 発火経路 / 出力 の詳細表)。 script 追加 / 廃止時はそちらを更新 (= 本 file に重複させない)。

## エージェントの責務

### 起動時 (= Phase B-共通)

- `startup-status.sh` を実行 → 出力 Read
- 前 session の `journal/<前 date>/session-NN-auto-index.jsonl` を Read
- 出力閾値に応じて打診:
  - `docs-check FAIL ≥ 1` → 同セッション内 fix
  - `duplicates.md` dup_pairs ≥ 1 → 横断昇格候補打診 (= `rules/lazy/rule-promotion-format.md` 書式)
- `stale_rules` / `dup_pairs` は起動時は無視 (= 終了時 Step 2 で走り切る運用)

### 終了時 (= Step 2)

何もしない。 SessionEnd hook が 2 script を自動発火する (= extract-artifact-index + detect-duplicates)。 hook install されてない時のみ手動起動。

### commit 時

`precommit-conflict-check.sh` が自動発火、 重複警告あれば内容確認 → 必要に応じて統合 / scope 整理。

## `_output/` (= 自動生成出力)

SessionEnd hook + 起動時 startup-status の出力先。 session 毎に丸ごと再生成される派生物なので **gitignore 済 (= 追跡しない)**。 各 PC ローカルで再生成、 複数 PC 同期の固定名衝突を避ける目的。 フォルダだけ `.gitkeep` で保持。

## docs-check.sh の検査ステップ (= 8/8)

1. **frontmatter チェック** — 全 .md に `---` 区切り + title 必須、 description 推奨
2. **capacity チェック** — CLAUDE.md 容量表 + 各 file の frontmatter `capacity:` 宣言に対する突き合わせ
3. **索引整合チェック** — `_README.md` に「索引 / ファイル / エントリ」 section があれば同フォルダ .md を全部言及してるか
4. **dead link チェック** — `` `*.md` `` 形式の相対参照が実在するか (= archive / 雛形 / 外部リポ参照は skip)
5. **placeholder 残し** — `projects/_template-project/` 配下の雛形から `{{...}}` と `<日本語 含む 文>` を**動的抽出**して禁止 list 化、 active file 内ヒットを FAIL (= 雛形 cp 後の埋め忘れ防止)
6. **動的検索パターン残骸** — `ls + head` 動線等の旧式参照パターン検出
7. **プロジェクト folder 整合** — `projects/<name>/_README.md` 不在 = プロジェクト未成立検出
8. **synced-paths 整合** — `.synced-paths.txt` 列挙 path が実在することをチェック (= 派生 repo の場合)、 `BASE_REPO_PATH` 環境変数指定時は base ↔ 派生 diff も検出

> 旧 step 5 (= CLAUDE.md ↔ rules/always 重複 = 15 字日本語 fragment) は 2026-06-30 廃止。 重複検出は `detect-duplicates.py` (= section 単位 LCS、 全 rule file 網羅) に集約。

## 新 script を追加する時 (= 拡張手順)

1. **置き場所** = `.tooling/<name>.sh` or `.tooling/<name>.py`。 LLM 不使用が原則、 token 自動消費ゼロを死守
2. **発火経路** を 3 つから選ぶ (= PreToolUse hook は「tool 発火時 = 判断後で手遅れ」 構造欠陥のため非推奨):
   - **起動時 Phase B-共通** (= `startup-status.sh` 内に集約) → 軽量で 1 行 summary 出すものに限る
   - **SessionEnd hook** (= `~/.claude/settings.json` の SessionEnd 配列に append) → session 終わり毎に走る
   - **git pre-commit hook** (= `.git/hooks/pre-commit` 経由、 `precommit-conflict-check.sh` 参照) → commit 前のゲート
3. **失敗は fail-open**: `exit 0` で main 処理を止めない、 stderr に 1 行ログのみ
4. **出力先**:
   - 1 行 summary → stdout (= startup-status から呼ばれる)
   - session 毎の生成物 → `.tooling/_output/<name>.md` (= 上書き、 gitignore 済で追跡しない)
   - 履歴 → `journal/<date>/session-NN-<name>.jsonl` (= 上書き、 session 単位スナップショット、 NN は `.md` 最大 NN + 1)
5. **本表に追記** + **`rules/lazy/automation-machinery.md § 機構と発火` の表に追記**
6. **`setup-hooks.sh` 更新** (= 新 hook を install すべき手順を idempotent に追加)
7. **エージェントの責務 section を更新** (= 起動時 / 終了時 / commit 時 のどこで反応するか明文化)
8. **docs-check FAIL 0 維持確認** (= 走らせて placeholder / frontmatter / capacity 通過確認)
