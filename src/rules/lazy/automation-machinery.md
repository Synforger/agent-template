---
title: 自動化機構運用 + 文書庫運用 (= lazy)
description: 自動化 script の発火経路 / 出力 / 反応規律 + lazy 文書庫の設計原則 (= 機構改修 / 新 lazy 追加時の参照)
updated: 2026-06-29
triggers: 自動化機構 (`.tooling/*`) を改修する直前 / 新 lazy file を追加する直前 / settings.json の hook 配列を編集する直前
capacity: 7KB
---

# 自動化機構運用 + 文書庫運用

> **必要な瞬間**: `.tooling/` 配下の script を新規追加 / 改修する時、 `~/.claude/settings.json` の hook を編集する時、 新しい lazy file を `rules/lazy/` or `projects/<proj>/rules/lazy/` に追加する時。

agent-template が出荷する自動化は全部 LLM 不使用、 `git log` + `regex` + `grep` で機械抽出。 token 自動消費ゼロ。

## 機構と発火

| script | 発火 | 入力 | 出力 |
|---|---|---|---|
| `.tooling/startup-status.sh` | エージェント起動時 Phase B-共通 | 各 utility summary 集約 + PC 識別 (= `.tooling/pc-labels.txt` lookup) | stdout 1 ブロック (= 冒頭 `PC: <label>` 行) |
| `.tooling/pc-labels.txt` | 起動時 startup-status から | `scutil --get LocalHostName` → label mapping | PC 識別 (= 新 PC 追加は 1 行追記) |
| `.tooling/detect-stale-rules.sh` | startup-status から | 全 rule file の git log | 7 日無更新 rule 一覧 (= `stable: true` + `_README.md` は除外) |
| `.tooling/detect-duplicates.py` | startup-status から + SessionEnd hook | rule file 全 H2/H3 section の LCS 比較 | `.tooling/_output/duplicates.md` (= 上書き) |
| `.tooling/extract-artifact-index.sh` | SessionEnd hook | git log (= 当 transcript の最初 ts 以降) + gh pr | `journal/<date>/session-NN-auto-index.jsonl` (= 上書き、 NN = `.md` 最大 + 1) |
| `.tooling/precommit-conflict-check.sh` | git pre-commit hook | 改訂 file vs 既存 rule file | stderr で重複警告 (= blocking なし) |
| `.tooling/docs-check.sh` | 終了時 Step 2 + 任意手動起動 | 全 .md 機械検査 (9 step) | PASS / WARN / FAIL カウント (= FAIL ≥ 1 で同 session fix 必須) |
| `.tooling/go-gate-reminder.sh` | Claude Code UserPromptSubmit hook | 毎発話 | GO 判定リセットの極短注入 (= 判定本体は rules/always.md § forbidden が真値、 hook は再武装の 1 行のみ) |
| `staledocs` (= 外部 CLI + `.staledocs.yaml`) | startup-status.sh から | 起動 + 終了 | rules 層 + CLAUDE.md の code<->docs 整合 (= pair 台帳 + アンカー生存。 同スコープの dead link は docs-check step 4 が skip、 warn 運用) |

## 反応規律

| timing | 反応すべき出力 | 行動 |
|---|---|---|
| 起動時 | `docs-check FAIL ≥ 1` | 同 session fix |
| 起動時 | `PC: unknown` (= 新規 PC、 pc-labels.txt 未登録) | `.tooling/pc-labels.txt` に `<LocalHostName> <label>` 追記、 即報告 |
| 終了時 Step 2 | `stale_rules ≥ 1` | 真の dead rule のみ退役 commit (= 打診禁止、 自走) |
| 終了時 Step 2 | `dup_pairs ≥ 1` | 中身確認して集約 commit (= 真値分散なら集約 / reference なら残置) |
| 終了時 Step 2 | `docs-check FAIL ≥ 1` | 即 fix |

起動時 `stale_rules` / `dup_pairs` は無視 (= 終了時走り切りで起動時クリーン前提)。 終了時は判断で走り切り、 失敗は revert で戻す。 SessionEnd hook (= extract-artifact-index + detect-duplicates) は触らず、 hook install は `setup-hooks.sh`。

## 文書庫運用 (= lazy 設計原則)

`rules/lazy/*.md` + 派生で追加する `profile/profile-*.md` lazy + `projects/<proj>/rules/lazy/*.md` は**文書庫**。 hook 自動 inject は採用しない、 該当シチュエーションを認識したら作業開始の直前に自発 Read する設計。

### 設計原則

- 各文書の frontmatter に `triggers:` で**シチュエーション**を自然言語記述 (= 「Agent tool を起動する直前」「commit / push を作る直前」 等)
- 特定発話依存 trigger 禁止 (= 「特定キーワードを打ったら」 系、 自然な作業文脈で認識できるシチュエーションのみ可)
- シチュエーション該当を見落とすことが形骸化の温床、 常時 load の rule で「該当作業前に必ず Read」 等の明示ルール集約
- 文書庫を新規追加する時は frontmatter `triggers:` 必須 + 該当シチュエーションを参照する常時 load file からのリンクも必須 (= 「読まれない可能性のある rule」 は作らない)

## 新 script 追加手順

1. **置き場所** = `.tooling/<name>.sh` or `.tooling/<name>.py`。 LLM 不使用が原則、 token 自動消費ゼロを死守
2. **発火経路** を 3 つから選ぶ (= PreToolUse hook 系は「tool 発火時 = 判断後で手遅れ」 構造欠陥のため非推奨):
   - **起動時 Phase B-共通** (= `startup-status.sh` 内に集約) → 軽量で 1 行 summary 出すものに限る
   - **SessionEnd hook** (= `~/.claude/settings.json` の SessionEnd 配列に append) → session 終わり毎に走る
   - **git pre-commit hook** (= `.git/hooks/pre-commit` 経由、 `precommit-conflict-check.sh` 参照) → commit 前のゲート
3. **失敗は fail-open**: `exit 0` で main 処理を止めない、 stderr に 1 行ログのみ
4. **出力先**:
   - 1 行 summary → stdout (= startup-status から呼ばれる)
   - session 毎の生成物 → `.tooling/_output/<name>.md` (= 上書き、 gitignore 済で追跡しない)
   - 履歴 → `journal/<date>/session-NN-<name>.jsonl` (= 上書き、 session 単位スナップショット)
5. **本 file と `.tooling/_README.md` の表に追記**
6. **`setup-hooks.sh` 更新** (= 新 hook を install すべき手順を idempotent に追加)
7. **docs-check FAIL 0 維持確認**

## 継続的自己強化ループ

真値 = `rules/always/meta.md § 継続的自己強化ループ` 参照。 本 file からは機構の具体実装 (= 上記 § 機構と発火 / 反応規律 / 新 script 追加手順) に集中し、 弱点パターン発見時の運用フローは meta.md に集約。
