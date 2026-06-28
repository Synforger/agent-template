---
title: <subproject>/rules — サブプロジェクト固有 rule
description: 本サブプロジェクト時に適用される rule 群。 always + lazy 2 層
updated: "{{YYYY-MM-DD}}"
capacity: 3KB
---

# <subproject>/rules

親プロジェクトの `<親 project>/rules/_README.md` および エージェント 直下 `<agent-repo-root>/rules/_README.md` 参照、 ここは本サブプロジェクト固有部分のみ。

## 構造

- `always/` = サブプロジェクト判定時に全文 Read される必読 rule
- `lazy/` = シチュエーション該当時に エージェント が作業開始直前に自発 Read (= 文書庫運用)、 frontmatter `triggers:` 必須

## 追加ルール

- **本サブプロジェクトに入ってる時だけ発火**: `lazy/` の hook は エージェント が本サブプロジェクトの context にいる時のみ trigger 照合 (= 親プロジェクト直下 or 別 subproject 中は無視)
- lazy 雛形 = `lazy/_template.md`
