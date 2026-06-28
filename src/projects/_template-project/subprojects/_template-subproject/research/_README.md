---
title: <subproject>/research — サブプロジェクト固有調査
description: 本サブプロジェクトに関する調査・参考資料の集約
updated: "{{YYYY-MM-DD}}"
capacity: 3KB
---

# projects/<project>/subprojects/<subproject>/research/

このプロジェクト固有のリサーチ・調査結果を置く場所。

## ここに置くもの

- このプロジェクトの題材・道具を選定 / 比較する調査
- このプロジェクトの背景知識・参考資料
- このプロジェクトの実装に関わる技術調査

## ここに置かないもの

- **複数プロジェクトをまたぐ汎用知識** → `<agent-repo-root>/research/`（直下）
- **業務固有 (= 会社プロジェクト等) の調査** → 業務リポ側 (= 親 rule 外)

## 命名規則

- `kebab-case-topic.md`
- 大きい調査は 1 トピック = 1 ファイル
- 書き方は `<agent-repo-root>/research/_README.md` の共通ルールに従う（情報源 URL 必須 / 結論セクション必須）
