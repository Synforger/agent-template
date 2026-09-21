---
title: plans/ の運用 (= 全階層共通の真値)
description: どう進めるかの置き場。 何を入れるか / 命名 / 書き方 / _archive の基準
updated: 2026-09-21
capacity: 3KB
---

# plans/ の運用

> **全階層共通の真値**。 `projects/<P>/plans/` も `subprojects/<S>/plans/` も同じ運用で、 **下の階層に本 file の写しは置かない**。 フォルダの意味 = 直下の `CLAUDE.md § ディレクトリ`、 毎 session 効く判断 (= 残すか片付けるか / 新規作成の可否) = `rules/always.md § git`。

## 何を入れる / 入れない

- **入れる**: やること と どう進めるか (= 計画 / 段取り / 設計 / 採用方針 / 単発の作業)。 やることは file の中の見出しで持つ
- **入れない**: 技術知識の蓄積 → `research/`、 trigger を持つ手順書 → `rules/lazy/`、 secret / credential / 個人のセットアップ手順 → エージェント配下に置かない
- 直下プール (= repo 直下の `plans/`) は**どのプロジェクトにも属さない**もの。 プロジェクトのものは `projects/<P>/plans/`

## 命名と書き方

- file 名 = `kebab-case-name.md` (= 内容を 3-5 語で)。 複数 file になる計画は `<plan-name>/` サブフォルダ + 配下に `_README.md`
- `_template.md` をコピーする。 frontmatter = `title` / `description` / `status` / `created` / `updated`
- status = `not-started` / `in-progress` / `completed` / `superseded` のいずれか。 進行中は `updated` を都度更新
- 大きな計画の刻み方 (= 段の表と持ち場の表) は、 実装計画の lazy が真値 (= 索引 = `rules/lazy/_README.md`)

## まとめる / 分ける

- **重複や被りが出たらまとめる** (= 同じことを 2 本が書き始めたら 1 本に寄せ、 片方は `_archive/` へ。 真値が 2 か所に割れると、 次に読む方が古い側を読む)
- **1 つの目標に対して file が分かれる時は、 フォルダに入れてまとめる** (= `<goal-name>/` を作って配下に置く。 直下に兄弟として並べると、 どれが同じ目標のものか読めなくなる)

## _archive

終了時の棚卸しで、 **次の session でエージェントが手を動かせないものを `_archive/` へ移す** (= 判断軸 = `rules/always.md § git`)。 work repo の `docs/` へ反映し終えた計画書もここへ。 archive は削除ではなく履歴の置き場で、 中身は消さない。
