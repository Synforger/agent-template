---
title: 横断昇格提案 出力 template (= lazy)
description: 複数プロジェクト共通の反復違反 / 重複が見つかった時、 横断 rule への昇格提案を書く書式
updated: 2026-06-29
triggers: 横断 rule (= CLAUDE.md / profile-core / rules/always/*) 昇格 commit を作る直前 / 横断昇格判断を出す時
capacity: 5KB
---

# 横断昇格提案 template

> `.tooling/_output/duplicates.md` (= detect-duplicates 出力) や、 複数 session で「同種の判断ミス」 を観測した時に、 「これは横断 rule に昇格すべき」 と判断した候補を本書式で整理してから commit する。

## 使い方

1. SessionEnd hook 出力 (`.tooling/_output/*.md`) を読む
2. 「2 プロジェクト以上で再発している反復違反」 「3 file 以上に重複している記述」 を候補化
3. 本 template に沿って整理し user レビュー打診
4. 承認分のみ既存 file (= CLAUDE.md / rules/always/* / profile-core 等) に commit、 不採用は journal に archive

## 候補書式 (= 1 候補 1 block)

### 候補 N: <短い見出し>

- **発生プロジェクト** (= 反復違反の場合): project-a / project-b / normal 等
- **発生 file** (= 重複の場合): `<path>:<section>`, `<path>:<section>` 形式
- **頻度** (= 過去 1 month 内): N 回 / N 日
- **既存 rule との接続**: 該当 rule (= H2 section path)、 無ければ「新規」
- **昇格先候補**: `CLAUDE.md` / `rules/always/<file>.md` / `rules/lazy/<file>.md` / 派生 profile 構造に応じた `profile/<core file>` のいずれか
- **提案 diff** (= 既存 file への追加 or 修正):

```diff
+ <追加する行 / 既存行の修正>
- <削除する行>
```

- **判断軸** (= なぜ昇格すべきか): 反復違反 N 回以上 / 真値分散 / 形骸化 retire / 等
- **レビュー観点**: 「ここを確認してほしい」 のポイント 1-2 行

## 出力例

### 候補 1: lazy file を起動前必読化

- 発生プロジェクト: project-a / project-b
- 発生 file: `<project-a journal>`, `<project-b journal>`
- 頻度: 2 回 / 2 日
- 既存 rule との接続: `rules/lazy/<対象 lazy>.md` (= 既存だが起動時必読外)
- 昇格先候補: `CLAUDE.md` (= 起動時必読の Phase B-共通で 1 行参照を追加)
- 提案 diff:

```diff
+ - 該当作業を始める前は `rules/lazy/<対象>.md` を Read (= 反復違反集約参照)
```

- 判断軸: 反復違反 2 プロジェクトで再発、 lazy 配置のままだと「作業前 Read 忘れ」 が起きる
- レビュー観点: 「lazy のまま起動時 Read を強制する書き方で OK か、 always 昇格すべきか」
