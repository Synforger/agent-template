---
title: <subproject> サブプロジェクト
description: <subproject> サブプロジェクト (= folder 名がそのまま判定キーワード)
updated: "{{YYYY-MM-DD}}"
capacity: 3KB
---

# <subproject> サブプロジェクト

> 親プロジェクトの規約は `<親 project>/_README.md` と `<親 project>/rules/always.md`、 ここは本サブプロジェクト固有部分のみ。

## このサブプロジェクトは何か

<射程を 1-3 文で書く>。

### 含む / 含まない
- 含む: <活動・対象>
- 含まない: <親プロジェクト直下作業 or 別 subproject 送り>

## repo

<この階層に紐づく repo の path。 無ければ「無し」 と書く>

## 起動時の追加読み

起動時に踏む共通 5 点は親 `CLAUDE.md § Phase B-階層固有` が真値 (= ここには書かない)。 **この階層でだけ追加で要る読み物**があれば列挙する、 無ければ「無し」。

## エージェントの役割 (= 本サブプロジェクト時)

- <親プロジェクト時から変わる立ち位置のみ明記。 行動制約は `rules/always.md` に書く>

## 親プロジェクトとの関係

- **journal は階層自己完結**: 本サブプロジェクト作業の journal は `<親 project>/subprojects/<self>/journal/` に書く。 親+サブ両方触った session は両階層に 1 本ずつ
- 片付いた計画の archive は本サブプロジェクト内 `plans/_archive/`
