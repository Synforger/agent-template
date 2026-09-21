---
title: projects フォルダ
description: 自己完結プロジェクト群の運用 (= 判定 / 標準構造 / 階層インターフェース / 使い分け)
updated: 2026-07-27
capacity: 6KB
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
- user 「<親プロ>の <サブプロ> 作業」 → 親 hit → 残り「の <サブプロ> 作業」 で `ls projects/<親プロ>/subprojects/` 照合

folder 名規約 (= 親プロ / サブプロ共通):

- 日本語名 OK、 英語名 OK、 PC 別自由
- 雛形 / system folder は `_` prefix で除外 (= `_template-project` / `_template-subproject` / `_archive` 等)
- folder 名 = user が発話で使う識別子、 自然に発話に出る単語にする (= 親プロと組み合わせて自然な日本語になるサブプロ名が理想、 「<親プロ>の <サブプロ>」 がそのまま判定キーワードになる形)

会社プロジェクト + サブプロ等は当該 PC で folder 作るだけで自動編入 (= 親 rule は folder 名に依存しない、 会社情報を エージェント配下に書き残さない設計と整合)。

## 標準構造

```
projects/<project>/
├── _README.md      ← 射程・repo・起動時の追加読み・エージェントの役割
├── vision.md       ← 現在地 (= 長期の状態 1 枚、 起動時必読。 やること・タスクは書かない)
├── rules/
│   ├── always.md   ← プロジェクト起動時必読 (= Phase B-プロジェクト固有、 形態 D = 1 file)
│   └── lazy/       ← シチュエーション該当時に エージェント が自発 Read (= 文書庫運用)
├── plans/          ← 計画書 (= 完了は `_archive/` へ)
├── research/       ← このプロジェクト固有の調査
├── journal/        ← セッションログ (YYYY-MM-DD/session-NN.md)
└── subprojects/    ← サブプロジェクト (= 同構造の子、 journal も独立)
```

## 階層インターフェース (= 必須セット、 機械検査 = docs-check step 10)

project / subproject が必ず持つ最小セット (= 雛形 cp で自動充足、 テンプレの形を暗黙仕様にしない):

- **必須 file**: `_README.md` / `rules/always.md` (= 形態 D、 固有 rule が無い間も空雛形を置く) / `rules/lazy/_README.md` (= lazy 索引、 lazy 0 件でも置く)
- **起動時必読**: `vision.md` (= 長期の状態 1 枚、 上限 4KB)。 未作成の階層は docs-check step 10 が WARN で出すので、 次にその階層で起動した session の終了時に作る
- **必須 dir**: `journal/` / `plans/`
- **任意**: `research/` / `subprojects/` / `tooling/` (= 使う階層のみ)
- **frontmatter 必須キー** (= `_README.md` + rules 層): `title` / `description` / `updated` / `capacity` (= 検査は docs-check step 1-2)

欠落は docs-check step 10 が FAIL で検出。

## 新規プロジェクトの追加

```bash
cp -R projects/_template-project/ projects/<新名>/
```

で標準構造が一括で立つ。 folder 名 = 判定キーワードなので**ls で自動編入**され、 他に触る file は無い。 `_README.md` の各 section を埋めれば即起動対象。

## `<project>/_README.md` の必須セクション (= 全プロジェクト統一)

順番固定:
1. このフォルダは何か (= 射程 / 含む・含まない)
2. `## repo` (= この階層に紐づく repo の path。 無ければ「無し」)
3. `## 起動時の追加読み` (= 共通 6 点の後に読むもの。 無ければ「無し」)
4. エージェント の役割 / 挙動ルール
5. 関連 link

**共通 6 点の真値は直下の `CLAUDE.md § Phase B-階層固有`**、 判定キーワードは folder 名そのもの。 どちらも `_README.md` には書かない (= 真値分散)。

## 汎用フォルダとの使い分け

- **プロジェクト固有** → `projects/<project>/{research,plans,journal}/`
- **横断・汎用** → `<agent-repo-root>/{research,plans}/` (直下プール)、 `normal` の journal は `<agent-repo-root>/journal/` 直下
- **repo に残す計画書・設計ドキュメント** → 対象 repo の `docs/` 配下

## ライフサイクル

- 作業前に該当プロジェクトの `_README.md` を読む (= 起動時は folder 名の部分一致で自動判定)
- 設計判断・進捗はその場で該当ファイルに反映、 セッション終了時も最新化
- 完了は各ファイルの `status` で管理。 フォルダは削除せず履歴として残す

## エージェント の挙動ルール

- `plans/` の 1 テーマが体系的になったら「projects に昇格しますか?」 と提案
- 仕様の本体は repo 側 docs、 エージェント 側はプロジェクト運用文書だけ (= 混ざったら即移設)
- プロジェクトの追加 / 削除は folder の作成 / 削除だけで完結する (= 判定の真値は `ls` 結果 1 箇所、 書き換える表は無い)
