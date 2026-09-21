---
title: <project>/subprojects — サブプロジェクト容器
description: 本プロジェクト配下のサブプロジェクト集約場所
updated: "{{YYYY-MM-DD}}"
capacity: 3KB
---

# <project>/subprojects

本プロジェクト配下のサブプロジェクト集約場所。 サブプロジェクトは親プロジェクトの中の独立した作業文脈で、 **folder 名がそのまま判定キーワード**になる (= 親プロジェクト起動後に動的切替で入る)。

## 構造

- `_template-subproject/` を `cp -R` して `subprojects/<sub>/` に置く
- 親と同じ形を内製する (= `_README.md` / `vision.md` / `rules/` / `plans/` / `research/` / `journal/`)
- **journal も独立して持つ** (= 階層自己完結。 親 + サブ両方触った session は両階層に 1 本ずつ書く)

## サブプロジェクト判定 (= 動的切替)

- 親プロジェクト起動後、 ユーザ発話に subproject の folder 名が部分一致したらエージェントが動的に切り替える
- 切替時は 1 行告知する (= 「subproject = X に入りました」)
- 切替後はその階層で共通 6 点を踏む (= 真値は親 `CLAUDE.md § Phase B-階層固有`)
- 同 session 内で複数 subproject を出入りしてよい

## 現在のサブプロジェクト

- (= 立ち上げ時に追記、 無ければ「なし」)
