---
title: journal/ の運用 (= 全階層共通の真値)
description: session の記録の置き場。 file 名 / 書き方 / 追記のみの原則 / _archive の基準
updated: 2026-09-21
capacity: 3KB
---

# journal/ の運用

> **全階層共通の真値**。 `projects/<P>/journal/` も `subprojects/<S>/journal/` も同じ運用で、 **下の階層に本 file の写しは置かない**。 フォルダの意味 = 直下の `CLAUDE.md § ディレクトリ`、 毎 session 効く判断 (= 残すか片付けるか / 新規作成の可否) = `rules/always.md § git`。

## 何を入れる / 入れない

- **入れる**: session の記録。 **触れた階層全部に 1 本ずつ** (= 階層自己完結。 親 + サブ両方触ったら両方に 1 本)
- **入れない**: 計画 / 調査そのもの (= それぞれ `plans/` `research/`。 journal が持つのは「その session で何が起きたか」)

## file 名と書き方

- `YYYY-MM-DD/session-NN.md` (= 日付フォルダは**締めた日**、 作業期間が跨るなら本文の見出しに書く)
- NN は階層ごとに独立、 採番は終了時 Step 0 の出力をそのまま使う
- 書式 = `_template.md`。 発火記録は隣に `session-NN-rule-hits.jsonl` (= 書式 = `rules/lazy/rule-registry.md`)
- 機械が作る触跡は `session-NN-auto-index.jsonl` (= PC ローカル、 `git` に載せる階層と載せない階層がある)

## 追記のみ

**既に書いた journal は上書きしない**。 訂正が要るなら次の session の journal に書く (= 過去の記録はその時点で何が見えていたかの一次資料)。

## _archive

日付フォルダが増えて一覧が読めなくなったら、 古い分を `_archive/` へ日付ごと移す (= 中身は消さない)。 機械検査 (= `docs-check` step 9) は `_archive/` も file 名と frontmatter を見る。
