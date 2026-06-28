---
title: <project>/subprojects — サブプロジェクト容器
description: 本プロジェクト配下のサブプロジェクト集約場所
updated: "{{YYYY-MM-DD}}"
capacity: 3KB
---

# <project>/subprojects

本プロジェクト配下のサブプロジェクト集約場所。 サブプロジェクトは親プロジェクトの中の独立した作業文脈で、 独自の判定キーワード + 固有 rule を持つ (= 親プロジェクト起動後に動的切替で入る)。

## 構造

- 各サブプロジェクトは `_template-subproject/` を cp -R して `subprojects/<sub>/` で配置
- サブプロジェクト固有の plans/research/todos/rules を持つ
- **journal は持たない** (= 親プロジェクトの `<project>/journal/` に集約、 session 本文で「subproject = X」 明示)

## サブプロジェクト判定 (= 動的切替)

- 親プロジェクト起動後、 user の発話に subproject 判定キーワードが部分一致したら エージェント が動的に切替
- 切替時 エージェントは 1 行告知 (= 「subproject = X に入りました」)
- 切替後は `<sub>/rules/always/*.md` 全文 Read、 `<sub>/rules/lazy/*.md` は hook 機械 inject
- 同 session 内で複数 subproject を出入り可能

## 現在のサブプロジェクト

- (= 立ち上げ時に追記、 無ければ「なし」)
