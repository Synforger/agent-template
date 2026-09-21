---
title: research/ の運用 (= 全階層共通の真値)
description: 調べたことの置き場。 何を入れるか / 命名 / 書き方 / _archive の基準
updated: 2026-09-21
capacity: 3KB
---

# research/ の運用

> **全階層共通の真値**。 `projects/<P>/research/` も `subprojects/<S>/research/` も同じ運用で、 **下の階層に本 file の写しは置かない**。 フォルダの意味 = 直下の `CLAUDE.md § ディレクトリ`、 毎 session 効く判断 (= 残すか片付けるか / 新規作成の可否) = `rules/always.md § git`。

## 何を入れる / 入れない

- **入れる**: 一度書いたら参照され続ける調査 (= ライブラリ比較 / API・SDK の仕様まとめ / アーキテクチャパターン / 技術選定の検討)
- **入れない**: やること と 進め方 → `plans/`
- 直下プール (= repo 直下の `research/`) は**複数プロジェクトをまたぐ汎用知識**。 プロジェクト固有は `projects/<P>/research/`

## 命名と書き方

- file 名 = `kebab-case-topic.md`。 1 テーマ = 1 file
- `_template.md` をコピーする (= 目的 / 調査内容 / 結論 / 参考リンク)。 frontmatter = `title` / `created` / `status` / `tags`
- **情報源の URL は必ず残す**、 **要点は自分の言葉で書く**、 **結論セクションを必ず書く** (= 調査の意味は「で、 どうすればいい?」 が分かること)
- 技術選定なら 選択肢 + トレードオフ + 推奨案 (= 推奨は影響範囲を測ってから)

## _archive

調査は完了しても参照価値が残るので、 基本は `status` の変更だけで生存側に置く。 **参照先が消えた / 前提が覆って読むと誤解を生むものは `_archive/` へ移す** (= その理由を 1 行添える)。
