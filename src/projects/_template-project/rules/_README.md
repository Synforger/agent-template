---
title: <project>/rules — プロジェクト固有 rule
description: 本プロジェクト時に適用される rule 群。 always (= 起動時必読) と lazy (= hook 機械 inject) の 2 層
updated: "{{YYYY-MM-DD}}"
capacity: 3KB
---

# <project>/rules

エージェント直下 `rules/` と同じ原則を踏襲 (= 親 `<agent-repo-root>/rules/_README.md` 参照)、 本プロジェクト固有部分のみ。

## 構造

- `always/` = プロジェクト起動時に全文 Read される必読 rule
- `lazy/` = シチュエーション該当時に エージェント が作業開始直前に自発 Read (= 文書庫運用)、 frontmatter `triggers:` 必須 (= シチュエーション自然言語)

## 追加ルール (= 親 `<agent-repo-root>/rules/_README.md` § エージェント 挙動ルール からの差分)

- **本プロジェクトに入ってる時だけ発火**: `lazy/` の hook は エージェント が本プロジェクトの context にいる時のみ trigger 照合される (= 他プロジェクト起動中は無視)
- **always 追加判断**: 「本プロジェクト起動毎に必ず読む価値あるか」 で判定、 サブ作業時のみ要なら lazy へ
- **lazy 追加時**: `lazy/_template.md` をコピーして frontmatter `triggers:` をシチュエーション自然言語で埋める、 該当時の Read 漏れが起きる構造なら always 昇格 or 削除
