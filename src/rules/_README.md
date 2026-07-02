---
title: rules フォルダ
description: 派生エージェントが従う作業ルール (= 形態 D = always.md 1 file + lazy/*)
updated: 2026-07-03
capacity: 3KB
---

# rules フォルダ

**形態 D**: 全階層で `rules/always.md` 1 file 統合 + `rules/lazy/*.md` (= シチュエーション別 trigger)。

## 常時 load (= 起動時 Phase B で全文 Read)

- `always.md` — メタ運用 (= 容量 / 改訂文化 / 検出機構) + 派生追記 section (= git / style / forbidden 等)

## lazy = 文書庫 (= シチュエーション該当時に自発 Read)

出荷時 必須 file:

| file | 呼び出すシチュエーション |
|---|---|
| `lazy/_template.md` | 新 lazy file 作成時の雛形 |
| `lazy/automation-machinery.md` | `.tooling/*` script 改修 / settings.json hook 編集 / 新 lazy file 追加の直前 |

各 file の frontmatter `triggers:` にシチュエーションを自然言語記述、 該当作業を始める直前に必ず Read。

## 派生で追加する時

- **always 追記は本 file 内**: 派生 personal rule (= git / style / forbidden 等) は `always.md` に section 追加、 別 file 分割は 容量圧迫時のみ
- **lazy 追加は自発 OK**: `triggers:` 必須 + 常時 load からのリンクも必須 (= 「読まれない可能性のある rule」 は作らない)

## 改訂運用

- `always.md § meta` の容量上限 + 改訂文化を遵守
- agent-template 側で改訂が入った時は `sync-from-base.sh` で取り込む
- 派生で発見した機構改善は `promote-to-base.sh` で base へ昇格
