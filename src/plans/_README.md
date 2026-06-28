---
title: plans フォルダ (= 横断計画書プール)
description: プロジェクトに属さない横断的な計画書の置き場 + 書き方ルール
updated: 2026-06-21
capacity: 5KB
---

> 容量上限: 5KB (= `wc -c` で測定)。 超過時は エージェント が要約・重複削除を行う。
> 個別計画書 (`<plan-name>.md`) は無制限。

# plans/ (= 横断プール)

## このフォルダは何か

エージェント が管理する**横断的な計画書の直下プール** (= 2026-06-21 新設、 todos/ research/ と並列)。

「**何をどう進めるか**」 を 1 ファイル単位で管理する場所。 **特定プロジェクトに属さない**計画をここに置く。

## todos / research / plans の違い

| フォルダ | 中身 | 例 |
|---|---|---|
| `todos/` | やること、 タスクの置き場所 | 「Y を完了する」「Z を fix」 |
| `plans/` | **どう進めるか**、 計画 / 段取り / 設計 | 「X 機能の実装計画」「フォルダ整理の段取り」「アーカイブ運用設計」 |
| `research/` | 調査結果、 育てる前提の技術知識 | 「flowchart best practices」「ライブラリ比較」 |

## 何を入れる

- **横断的なテーマ**の計画 (= 複数プロジェクトに跨る、 特定プロジェクトに属さない)
- エージェント配下構造の改訂計画 / 整理段取り / 運用設計
- 採用方針 / 設計選択肢 / 段階的移行プラン

## 何を入れない (= 別場所)

- **特定プロジェクトの計画** → `projects/<project>/plans/`
- 単一タスクの実行管理 → `todos/`
- 技術知識の蓄積 → `research/`
- 個人 secret / credential / セットアップ手順 → エージェント配下に置かない

## 命名

- ファイル名 = `<plan-name>.md` (= snake-case or kebab-case、 内容を 3-5 単語で表現)
- 内容が膨らんで複数 file になる場合 = `<plan-name>/` サブフォルダ + 配下に `_README.md` + 計画書群
- 完了 (= 実装着地 or 不採用確定) は `_archive/` へ移送、 履歴保存

## 構成

```
plans/
├── _README.md              # このファイル
├── _template.md            # 雛形
├── <未着手・進行中>.md
├── <大型計画>/             # サブフォルダ化した計画
└── _archive/               # 完了済 / 不採用確定
```

## 書き方

- `_template.md` をコピーして使う
- 計画書のヘッダに frontmatter (= title / description / status / created / updated) を必ず付ける
- status は `not-started` / `in-progress` / `completed` / `archived` / `superseded` のいずれか
- 進行中は updated を都度更新

## 改訂運用

- 自発で改訂・追加・archive 可
- 完了済は速やかに `_archive/` 移送 (= 直下のノイズを減らす)
- 古い計画 (= 3 ヶ月以上 status 変化なし) は 自発で user に「これまだ?」 1 行打診
