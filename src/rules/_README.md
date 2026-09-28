---
title: rules/ の運用 (= 全階層共通の真値)
description: 毎 session 効くルールの置き場 / 置き場と書式の真値 / 台帳とワード master
updated: 2026-09-26
capacity: 3KB
---

# rules/ の運用

> **全階層共通の真値**。 `projects/<P>/rules/` も `subprojects/<S>/rules/` も同じ運用で、 **下の階層に本 file の写しは置かない**。

## 常時 load

- `always.md` 1 file (= 全階層同じ形)。 起動時に全文 Read
- 特定の作業中にだけ効く手順は skill が持つ (= 運用 = `.claude/skills/_README.md`)

## 置き場 / 書式 / 容量 / 退役

**どの階層に置くか / どの層か / 表現形式 / 容量上限 / 押し出しと退役の判断は `.claude/skills/rule-registry/SKILL.md` が真値**。 ルールを足す / 改訂する直前に読む。

## その他の file

- `registry.jsonl` — ルール ID 台帳 (= 階層ごとに 1 本、 `build-rule-registry.py` が生成。 ID は階層内で一意かつ不変)
- `anon-words.txt` (= 親のみ) — 匿名性スキャンのワード master (= 単一真値、 1 行 1 PCRE)。 各 repo へは `~/.config/anon-words/` 経由で配る
