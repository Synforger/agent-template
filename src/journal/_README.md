---
title: journal フォルダ (= normal + 全階層共通定義)
description: normal の session log + 全階層 (project / subproject) 共通の書式・読み込みルール
updated: 2026-06-22
capacity: 5KB
---

> 個別 `session-NN.md` は無制限。

# journal/ (= normal 専用 + 全階層共通定義)

エージェントが**前回セッションの続きを思い出すための引き継ぎノート**。 normal の log はここ、 project / subproject は各自フォルダ。 本 _README は**全階層共通の書式・読み込み運用**も定義 (= 各 project/subproject の `journal/_README.md` から参照される)。

## 配置 (= 階層自己完結、 2026-06-22 改定)

- `normal` → `journal/YYYY-MM-DD/session-NN.md`
- project → `projects/<P>/journal/YYYY-MM-DD/session-NN.md`
- subproject → `projects/<P>/subprojects/<S>/journal/YYYY-MM-DD/session-NN.md`
- 親+サブ両方触った session は両階層に 1 本ずつ書く (= 採番は各階層独立)
- `NN` は 2 桁 0 埋め / 日ごと 01 リセット / 日付境界はシステム日付 / 追記 OK・上書き禁止
- 起動時のプロジェクト判定は `CLAUDE.md` 参照
- `_archive/` = 2026-04-18 以前の旧 flat 形式 (`YYYY-MM-DD.md`) 退避先、 起動時 Read 対象外

## 書き方

`_template.md` を copy。 1 session = 1 file、 **箇条書き基本で簡潔に** (= 文章化しない、 技術判断ある行のみ 2-3 行に広げる)。

### セクション

**## やったこと** — 実装/修正、 技術判断と理由、 git 状態変化、 詰まりと解決
**## 次回** — 未完タスク・次セッション起点・残検討事項
**## branch snapshot (= コード作業を伴った session は必須・例外なし)** — 触った全 repo を 1 行ずつ:

```
- <repo>: develop tip = <hash> / open local branch: <name> (= develop+N commits, push 済 / 未 PR / PR #NNN merge 済 / etc)
```

- 「残ブランチなし」 1 行 OK / hash 主張前に `git log <branch> --oneline | grep <hash>` 確認 (= arayabrain-rules § 3.11)
- これが無い code-touching session は § 3.11 違反扱い (= 塩漬けブランチ事件の直接原因)

### 書かないもの

コード断片 (= git に残る) / user の感情・生活情報 / 抽象的な学び (= 具体に落とす)

## ライフサイクル

- **読む**: **最新 1 件のみ** (= 2026-06-22 改定で CLAUDE.md と整合)。 該当階層の最新日付フォルダの最大 NN を 1 file。 サブプロまで潜った session は親 journal を skip して**サブプロ journal の最新 1 件のみ**読む (= 階層自己完結 + context 節約)
- **書く**: session 終了時、 触れた階層全部に 1 本ずつ。 採番は各階層独立
- **編集・削除しない**: 履歴として残す

## 自動抽出 (= SessionEnd hook)

session 終了時に `.tooling/extract-artifact-index.sh` (= `git log` + `gh pr list`) が `session-NN-auto-index.jsonl` を上書き出力 (= 同 session 再発火で重複根絶)。 採番は `.md` 最大 NN + 1 (= jsonl は採番対象外)、 LLM 不使用 token ゼロ。 翌起動時 エージェント が前 session の jsonl を Read。 詳細 = `rules/always/meta.md § 自動化機構運用`。

## 過去形式

2026-04-18 以前は 1 日 1 file `YYYY-MM-DD.md`、 以降は日付フォルダ + `session-NN.md`。 旧 log は `_archive/` 保持。
