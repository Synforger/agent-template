---
title: rules/ の運用 (= 全階層共通の真値)
description: 常時 load と lazy の 2 層 / 置き場と書式の真値 / 台帳とワード master
updated: 2026-09-21
capacity: 3KB
---

# rules/ の運用

> **全階層共通の真値**。 `projects/<P>/rules/` も `subprojects/<S>/rules/` も同じ運用で、 **下の階層に本 file の写しは置かない**。 例外は `lazy/_README.md` (= 索引は中身が階層ごとに違うので各階層が持つ)。

## 2 層

- **常時 load** = `always.md` 1 file (= 形態 D、 全階層同じ形)。 起動時に全文 Read
- **lazy** = `lazy/*.md`。 frontmatter `triggers:` のシチュエーションに入る直前に自発 Read。 一覧 = `lazy/_README.md` (= 各 file 1 文 summary、 起動時に索引だけ Read)

## 置き場 / 書式 / 容量 / 退役

**どの階層に置くか / どの層か / 表現形式 / 容量上限 / 押し出しと退役の判断は `rules/lazy/rule-registry.md` が真値**。 ルールを足す / 改訂する直前に読む。

## その他の file

- `registry.jsonl` — ルール ID 台帳 (= 階層ごとに 1 本、 `build-rule-registry.py` が生成。 ID は階層内で一意かつ不変)
- `anon-words.txt` (= 親のみ) — 匿名性スキャンのワード master (= 単一真値、 1 行 1 PCRE)。 各 repo へは `~/.config/anon-words/` 経由で配る

## lazy を足す時

`lazy/_template.md` をコピーする。 `triggers:` 必須 (= 自然な作業文脈で認識できるシチュエーション)、 常時 load 側からのリンク必須 (= 読まれない rule を作らない)、 `capacity` 宣言。
