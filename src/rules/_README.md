---
title: rules フォルダ
description: 派生エージェントが従う作業ルール (= always / lazy 構造)
updated: 2026-06-29
capacity: 5KB
---

# rules フォルダ

派生エージェントが従う作業ルールを **常時 load (= always)** と **シチュエーション該当時に自発 Read する文書庫 (= lazy)** の 2 層に分離。

## 常時 load (= 起動時 Phase B-共通で全文読む)

agent-template が出荷する **必須 1 file**:

- `always/meta.md` — メタ運用 (= ファイル容量管理 + ルール改訂文化 + 継続的自己強化ループ)

> 派生固有の always rule は派生先で自由に追加する (= 例: `always/git-basics-local.md` / `always/forbidden-local.md` 等)。 sync-from-base 対象外。

## lazy = 文書庫 (= シチュエーション該当時に自発 Read)

agent-template が出荷する **必須 3 file**:

| file | 呼び出すシチュエーション |
|---|---|
| `lazy/_template.md` | 新 lazy file 作成時の雛形 |
| `lazy/automation-machinery.md` | `.tooling/*` script 改修 / settings.json hook 編集 / 新 lazy file 追加の直前 |
| `lazy/rule-promotion-format.md` | 横断 rule 昇格 commit を作る直前 (= `detect-duplicates.py` の dup_pairs hit に反応する書式) |

各 file の frontmatter `triggers:` にシチュエーションを自然言語記述、 該当作業を始める直前に必ず Read。

## 派生で追加する時

- **always 追加は慎重に**: 常時 load 容量は限られる、 新規 rule は原則 lazy 推奨
- **lazy 追加は自発で OK**: ただし `triggers:` 必須 + 該当シチュエーションを参照する常時 load file からのリンクも必須 (= 「読まれない可能性のある rule」 は作らない)

## 改訂運用

- `always/meta.md` の容量上限 + 改訂文化を遵守
- agent-template 側で改訂が入った時は `sync-from-base.sh` で取り込む (= 派生で勝手に編集すると sync で上書きされる)
- 派生で発見した機構改善は `promote-to-base.sh` で base へ昇格
