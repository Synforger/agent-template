---
title: journal/ の運用 (= 全階層共通の真値)
description: session の記録の置き場。 file 名 / 書き方 / 追記のみの原則 / _archive の基準
updated: 2026-11-29
capacity: 3KB
---

# journal/ の運用

> **全階層共通の真値**。 `projects/<P>/journal/` も `subprojects/<S>/journal/` も同じ運用で、 **下の階層に本 file の写しは置かない**。 フォルダの意味 = 本 file の `description` と § 何を入れる / 入れない、 毎 session 効く判断 (= 残すか片付けるか / 新規作成の可否) = `rules/always.md § git`。

## 何を入れる / 入れない

- **入れる**: session の記録。 **触れた階層全部に 1 本ずつ** (= 階層自己完結。 親 + サブ両方触ったら両方に 1 本)
- **入れない**: 計画 / 調査そのもの (= それぞれ `plans/` `research/`。 journal が持つのは「その session で何が起きたか」)

## file 名と書き方

- `YYYY-MM-DD/session-NN.md` (= 日付フォルダは**締めた日**、 作業期間が跨るなら本文の見出しに書く)
- NN は階層ごとに独立、 採番は終了時 Step 0 の出力をそのまま使う
- **続きのある仕事は journal に書かず、 票 (client の `tabs ticket`) が持つ**。 締めで何を書くかは skill `session-end`
- 書式 = `_template.md`。 発火記録は隣に `session-NN-rule-hits.jsonl` (= 書式 = `.claude/skills/rule-registry/SKILL.md`)
- 機械が作る触跡は `session-NN-auto-index.jsonl` (= PC ローカル、 `git` に載せる階層と載せない階層がある)
- 頭の欄の `tab:` (書いたタブ)・`forked_from:` (fork の元のタブ)・`description:` (一覧に 1 文目が出る) の書き方は skill `session-end`

## 起動で読む物 = 全文 1 本と一覧

エージェントの根で `python3 .tooling/startup/journal_index.py` を打つ。 `journal_full:` の 1 本 (= 自分のタブの最新、 無ければ階層の最新) は全文を読み、 `journal_others:` の一覧 (= ほかのタブと fork が書いた物) は 1 文を見て要る物だけ開く。 選び方と出力の形の真値は script の頭書き。

## 追記のみ

**既に書いた journal は上書きしない**。 訂正が要るなら次の session の journal に書く (= 過去の記録はその時点で何が見えていたかの一次資料)。

例外は 1 つ: **客先の中身が境界の外に書かれていた時は、過去の journal でも書き換える** (= 客先に固有の段落をその案件の階層の journal へ移し、元の場所には 1 行の参照を残す。何をどこへ移したかは、書き換えた session の journal に書く)。

## _archive

日付フォルダが増えて一覧が読めなくなったら、 古い分を `_archive/` へ日付ごと移す (= 中身は消さない)。 機械検査 (= `docs-check` step 9) は `_archive/` も file 名と frontmatter を見る。
