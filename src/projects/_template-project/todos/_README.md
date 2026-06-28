---
title: <project>/todos — プロジェクト固有タスク
description: 本プロジェクトのタスク + 完了済 _archive
updated: "{{YYYY-MM-DD}}"
capacity: 3KB
---

# projects/<project>/todos/

このプロジェクト固有のタスク・やることリスト。

## ここに置くもの

- このプロジェクトの開発タスク・次アクション・進捗管理
- user からの明示依頼で発生したプロジェクト固有のタスク

## ここに置かないもの

- 横断的・運用改善・単発のタスク → `<agent-repo-root>/todos/`（直下プール）
- repo に残す計画書・設計ドキュメント → 対象 repo の `docs/` 配下（user の VS Code workspace と整合させるため）

## 運用方針

- **新規作成は user の明示指示時のみ**（エージェント が空気を察して勝手に作らない）
- 書き方・命名は `<agent-repo-root>/todos/_README.md` の共通ルールに従う
