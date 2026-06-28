---
title: <subproject> サブプロジェクト
description: 起動キーワード「<キーワード>」 で入る <subproject> サブプロジェクト
updated: "{{YYYY-MM-DD}}"
capacity: 3KB
---

# <subproject> サブプロジェクト

> 親プロジェクト規約は `<親 project>/_README.md` および `<agent-repo-root>/CLAUDE.md` 参照、 ここは本サブプロジェクト固有部分のみ。

## 判定キーワード (= サブプロジェクト動的切替用、 user 発話に部分一致)

- `<キーワード>`

## このサブプロジェクトは何か

<射程を 1-3 文で書く>。

### 含む / 含まない
- 含む: <活動・対象>
- 含まない: <親プロジェクト直下作業 or 別 subproject 送り>

## 判定時に追加読込するもの

- `rules/always/*.md` 全部 (= サブプロジェクト固有必読 rule)
- `journal/` の最新 1 件 (= サブプロ独立 journal、 親 journal は読まない)
- <その他、 本サブプロジェクト固有に毎回必要な md>

## エージェント の役割 (= 本サブプロジェクト時)

- <親プロジェクト時から変わる部分のみ明記、 一般は親参照>

## 親プロジェクトとの関係

- **journal は階層自己完結** (= 2026-06-22 改定): 本サブプロジェクト作業の journal は `<親 project>/subprojects/<self>/journal/` に書く。 親+サブ両方触った session は両階層に 1 本ずつ
- 完了タスクの archive は本サブプロジェクト内 `todos/_archive/` / `plans/_archive/`
