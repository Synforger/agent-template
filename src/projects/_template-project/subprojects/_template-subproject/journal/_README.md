---
title: <subproject>/journal — サブプロジェクトセッションログ
description: 本サブプロジェクト固有の session log (= 親プロジェクト journal とは独立、 階層自己完結)
updated: "{{YYYY-MM-DD}}"
capacity: 3KB
---

# projects/<親project>/subprojects/<subproject>/journal/

このサブプロジェクトで動いたセッションの業務ログ。 **親プロジェクトの journal とは独立**、 サブプロに潜って作業した分はここに書く。

## 命名規則 / 書き方

- `YYYY-MM-DD/session-NN.md` (= 親 journal と同形式、 採番はこのフォルダ内で独立)
- フォーマットは `<agent-repo-root>/journal/_README.md` 参照 (= 全階層共通)

## 起動時読込

- **最新 1 件のみ**読む (= サブプロまで潜った session は親 journal を読まず、 ここから 1 件)
- 詳細動線は親 `<agent-repo-root>/CLAUDE.md` § Phase B-サブプロジェクト固有

## 書き込み

- 終了時、 本セッションで**触れた階層全部に 1 本ずつ**書く (= 親作業もあれば親 journal にも 1 本、 サブ作業もあればここにも 1 本)
- 採番は各階層独立 (= 親 NN とサブ NN は無関係)
