---
title: <project>/journal — プロジェクトセッションログ
description: 本プロジェクトの session log + sub セッション ログも集約
updated: "{{YYYY-MM-DD}}"
capacity: 3KB
---

# projects/<project>/journal/

この <project> プロジェクトで動いたセッションの業務ログ。

## 命名規則

- 日付フォルダ `YYYY-MM-DD/` の中にセッションファイル `session-NN.md`（2 桁 0 埋め、その日の最初から 01）
- 日付境界はシステム日付基準（0 時で切り替わる）

## 書き方・読み方

- フォーマットと運用は `<agent-repo-root>/journal/_README.md` を参照（全プロジェクト共通定義）
- 一度書いたら編集しない・削除しない（履歴として残す）

## このフォルダだけのもの

なし。journal の運用は全プロジェクト共通。**置き場所だけプロジェクト内に閉じる**ことで、
プロジェクトフォルダを 1 か所開けば research / todos / journal / vision が全部揃う構造にしている（2026-05-31 改定）。
