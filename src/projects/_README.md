---
title: projects フォルダ
description: 自己完結プロジェクト群 + プロジェクト判定キーワード mapping (= 起動時 1 file Read で判定完了)
updated: 2026-06-29
capacity: 5KB
---

# projects/

エージェント が管理する**プロジェクト群**。 1 プロジェクト = 1 フォルダで自己完結。

## プロジェクト判定 (= folder 名 = 判定キーワード、 真値 = ls 結果)

エージェント は起動時に `ls projects/` で folder 名一覧取得、 最初の user 発話に **folder 名が部分一致するものを採用**。 マッチなし = `normal`。

**folder 名 = 判定キーワード** = 真値 1 箇所 (= ls 結果のみ)、 mapping 表 / 判定キーワード section は存在しない。 folder 作るだけで自動編入、 削除で自動退役、 改訂忘れが構造的に不可能。

照合順 (= 順序付き、 親 → サブの順):

1. `ls projects/` で親プロ folder 名取得 (= `_` prefix 除外)、 user 発話と**部分一致**で照合
2. 親プロ hit したら **発話の残り (= 親プロ folder 名以降の文字列)** で `ls projects/<親プロ>/subprojects/` の folder 名と照合
   - サブプロ hit → 親プロ + サブプロ両方採用 (= 並列 Read)
   - サブプロ miss → 親プロのみ採用
3. 親プロも miss なら `normal`

例:
- user 「ゲームの runpod 作業」 → 親「ゲーム」 hit → 残り「の runpod 作業」 で `ls projects/ゲーム/subprojects/` 照合
- user 「クライアントアプリの v2」 → 親「クライアントアプリ」 hit → 残り「の v2」 でサブプロ照合 (= subproject 実体なしなら親のみ採用)

folder 名規約 (= 親プロ / サブプロ共通):

- 日本語名 OK (= 例: `クライアントアプリ` / `ゲーム`)、 英語名 OK、 PC 別自由
- 雛形 / system folder は `_` prefix で除外 (= `_template-project` / `_template-subproject` / `_archive` 等)
- folder 名 = user が発話で使う識別子、 自然に発話に出る単語にする (= 親プロと組み合わせて自然な日本語になるサブプロ名が理想、 例 = `ゲーム/subprojects/runpod` で「ゲームの runpod」 がそのまま判定キーワード)

会社プロジェクト + サブプロ等は当該 PC で folder 作るだけで自動編入 (= 親 rule は folder 名に依存しない、 会社情報を エージェント配下に書き残さない設計と整合)。

## 標準構造

```
projects/<project>/
├── _README.md      ← 射程・起動時読込定義・エージェントの役割 (= 判定キーワードは本 file mapping)
├── rules/
│   ├── always/     ← プロジェクト起動時必読 (= Phase B-プロジェクト固有)
│   └── lazy/       ← シチュエーション該当時に エージェント が自発 Read (= 文書庫運用)
├── plans/          ← 計画書 (= 完了は `_archive/` へ)
├── research/       ← このプロジェクト固有の調査
├── todos/          ← このプロジェクト固有のタスク
├── journal/        ← セッションログ (YYYY-MM-DD/session-NN.md)
└── subprojects/    ← サブプロジェクト (= 同構造の子、 journal も独立 = 2026-06-22 改定)
```

## 新規プロジェクトの追加

```bash
cp -R projects/_template-project/ projects/<新名>/
```

で標準構造が一括で立つ。 folder 名 = 判定キーワードなので**ls で自動編入**、 mapping 編集等の追加操作不要。 `_README.md` の各 section を埋めれば即起動対象。

## `<project>/_README.md` の必須セクション (= 全プロジェクト統一)

順番固定:
1. このフォルダは何か (= 射程)
2. 起動時に読むもの (= Phase B-プロジェクト固有)
3. 必要時に引いてくる (= 任意)
4. エージェント の役割 / 挙動ルール
5. ライフサイクル
6. 関連 link

判定キーワードは folder 名そのものなので `_README.md` には書かない (= 真値分散禁止)。

## 汎用フォルダとの使い分け

- **プロジェクト固有** → `projects/<project>/{research,todos,journal}/`
- **横断・汎用** → `<agent-repo-root>/{research,todos}/` (直下プール)、 `normal` の journal は `<agent-repo-root>/journal/` 直下
- **repo に残す計画書・設計ドキュメント** → 対象 repo の `docs/` 配下

## ライフサイクル

- 作業前に該当プロジェクトの `_README.md` を読む (= 起動時は本 file mapping で自動判定)
- 設計判断・進捗はその場で該当ファイルに反映、 セッション終了時も最新化
- 完了は各ファイルの `status` で管理。 フォルダは削除せず履歴として残す

## エージェント の挙動ルール

- todos が体系的になったら「projects に昇格しますか?」 と提案
- 仕様の本体は repo 側 docs、 エージェント 側はプロジェクト運用文書だけ (= 混ざったら即移設)
- mapping 更新 = プロジェクト追加 / 削除 / キーワード変更時、 必ず本 file 更新 (= 真値ここ 1 箇所)
