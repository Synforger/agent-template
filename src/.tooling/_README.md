---
title: .tooling/ — 自動化スクリプト群
description: LLM 不使用、 token ゼロの自動化機構一覧
updated: 2026-09-26
---

# .tooling/ — 自動化スクリプト群

全 script は LLM 不使用、 token 自動消費ゼロ。 git log + regex + grep で機械抽出。

## script 一覧

真値は `.claude/skills/automation-machinery/SKILL.md § 機構と発火` 参照 (= 役割 / 発火経路 / 出力 の詳細表)。 script 追加 / 廃止時はそちらを更新 (= 本 file に重複させない)。

## エージェントの責務

いつ何に反応するか (= 起動時 / 終了時 / commit 時) は `.claude/skills/automation-machinery/SKILL.md § 反応規律` と `CLAUDE.md` の起動手順・skill `session-end` の終了手順が真値 (= 本 file に重複させない)。

## `_output/` (= 自動生成出力)

起動時 startup-status と終了時 Step 2 の出力先。 session 毎に丸ごと再生成される派生物なので **gitignore 済 (= 追跡しない)**。 各 PC ローカルで再生成、 複数 PC 同期の固定名衝突を避ける目的。 フォルダだけ `.gitkeep` で保持。

## docs-check.sh の検査ステップ (= 16/16)

1. **frontmatter チェック** — 全 .md に `---` 区切り + title 必須、 description 推奨 (= `journal/` / `drafts/` / `_scratch/` / `_template*` は対象外、 `_archive/` は description を求めない。 残す前提の無い file に体裁を求めない)
2. **capacity チェック** — CLAUDE.md 容量表 + 各 file の frontmatter `capacity:` 宣言に対する突き合わせ (= `_archive/` は読み込まれないので対象外。 同じ突き合わせを git pre-commit も回す)
3. **索引整合チェック** — `_README.md` に「索引 / ファイル / エントリ」 section があれば同フォルダ .md を全部言及してるか
4. **dead link チェック** — `` `*.md` `` 形式の相対参照が実在するか (= archive / 雛形 / 外部リポ参照 / `external-paths: true` 宣言 file は skip。 階層が `## repo` で宣言した work repo の file 名も在り扱い)
5. **placeholder 残し** — `projects/_template-project/` 配下の雛形から `{{...}}` と `<日本語 含む 文>` を**動的抽出**して禁止 list 化、 active file 内ヒットを FAIL (= 雛形 cp 後の埋め忘れ防止)
6. **動的検索パターン残骸** — `ls + head` 動線等の旧式参照パターン検出
7. **プロジェクト folder 整合** — `projects/<name>/_README.md` 不在 = プロジェクト未成立検出
8. **synced-paths 整合** — `.synced-paths.txt` 列挙 path が実在することをチェック (= 派生 repo の場合)、 `BASE_REPO_PATH` 環境変数指定時は base ↔ 派生 diff も検出
9. **journal 整合** — `lib/journal-integrity.py` で全 journal の file 名 / frontmatter / 階層を単一パス検査
10. **階層インターフェース** — project / subproject の必須 file (`_README.md` / `rules/always.md` / `vision.md`) + 必須 dir (`journal/` / `plans/`) の実在検査 (= 真値 = `projects/_README.md § 階層インターフェース`)。 起動した檻から読めない階層は点検せず、 最後に「未点検」 と名前を出す。 gitignored で skill を持つ階層は、 `_README.md` に一覧を出す行 (= `skill-listing.py --list`) も求める
11. **ルール台帳整合** — `build-rule-registry.py --check` で `rules/registry.jsonl` が全 rule section を網羅しているか (= 見出し改名 / section 増減で発火記録の宛先が切れるのを検出)
12. **ルール参照整合** — `lib/check-rule-references.py` で全階層の rule file が指す repo 内 path の実在検査 (= 外部 repo の path / 裸の file 名 / placeholder は測れないので対象外)
13. **発火記録の網羅** — `lib/check-rule-hits.py` で session の .md と隣の `-rule-hits.jsonl` を突合 (= 記録を書き漏らした session を検出、 その階層が記録を始めた日以降のみ対象)
14. **vision の形** — `lib/check-vision-shape.py` で全階層の `vision.md` の必須節欠落と段落数超過を検査 (= 上限は実測由来で script の docstring が根拠)
15. **主文の肯定形** — `lib/check-positive-form.py` で常時 load と skill の主文が「何をするか」 で書かれているかを検査 (= 書式の真値 = `.claude/skills/rule-registry/SKILL.md § 表現形式`)
16. **一時 file の置き場** — `.tooling` の `mktemp` が `"${TMPDIR:-/tmp}/<名前>.XXXXXX"` の形を指定しているか (= macOS は template 無しだと `/var/folders` に作り、 檻の中ではそこに書けない)

## 新 script を追加する時

手順の真値は `.claude/skills/automation-machinery/SKILL.md § 新 script 追加手順` (= 本 file に重複させない)。
