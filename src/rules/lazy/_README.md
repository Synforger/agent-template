---
title: rules/lazy 索引 (= 起動時 Read)
description: 各 lazy file の 1 文 summary。 起動時に本 file を Read → 該当 trigger 時に本体を Read
updated: 2026-07-16
capacity: 2KB
stable: true
---

# rules/lazy 索引

起動時にこの索引だけ Read。 trigger 該当時に対応 file 本体を Read。 新 lazy 追加時は本 file に必ず 1 行追記 (= 索引漏れは「知らないから読まない」 の再発源)。

- `automation-machinery.md` — 自動化機構 (`.tooling/*` script / hook) 改修 + 新 lazy 追加時の設計原則
- `rule-promotion-format.md` — 複数プロジェクト共通の反復違反 / 重複を横断 rule へ昇格提案する書式
