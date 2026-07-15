---
title: 自動化機構運用 + 文書庫運用 (= lazy)
description: 自動化 script の発火経路 / 出力 / 反応規律 + lazy 文書庫の設計原則 (= 機構改修 / 新 lazy 追加時の参照)
updated: 2026-07-16
stable: true
triggers: 自動化機構 (`.tooling/*`) を改修する直前 / 新 lazy file を追加する直前 / settings.json の hook 配列を編集する直前
capacity: 7KB
---

# 自動化機構運用 + 文書庫運用

出荷する自動化は全部 LLM 不使用、 `git log` + `regex` + `grep` で機械抽出 (= token 自動消費ゼロ)。 trigger 詳細は frontmatter 参照。

## 機構と発火

| script | 発火 | 入力 | 出力 |
|---|---|---|---|
| `.tooling/startup-status.sh` | 起動時 Phase B-共通 | 各 utility summary + PC 識別 | stdout 1 ブロック (= 冒頭 `PC: <label>` 行) |
| `.tooling/pc-labels.txt` | startup-status から | `scutil --get LocalHostName` → label | PC 識別 (= 新 PC は 1 行追記) |
| `.tooling/detect-stale-rules.sh` | startup-status から | 全 rule file の git log | 7 日無更新 rule 一覧 (= `stable: true` + `_README.md` は除外) |
| `.tooling/detect-duplicates.py` | startup-status から + SessionEnd hook | rule file 全 H2/H3 section の LCS 比較 | `.tooling/_output/duplicates.md` (= 上書き) |
| `.tooling/extract-artifact-index.sh` | SessionEnd hook | git log (= transcript 最初 ts 以降) + gh pr | `journal/<date>/session-NN-auto-index.jsonl` (= NN = `.md` 最大 + 1) |
| `.tooling/precommit-conflict-check.sh` | git pre-commit hook | 改訂 file vs 既存 rule file | stderr で重複警告 (= blocking なし) |
| `.tooling/docs-check.sh` | 終了時 Step 2 + 手動 | 全 .md 機械検査 (9 step、 dead link は `status: snapshot` / archive 配下を除外) | PASS / WARN / FAIL (= FAIL ≥ 1 は同 session fix) |
| `.tooling/go-gate-reminder.sh` | UserPromptSubmit hook | 毎発話 | GO 判定リセットの極短注入 (= 判定本体は `rules/always.md § forbidden`、 hook は再武装のみ) |
| `staledocs` (= 外部 CLI + `.staledocs.yaml`) | startup-status から | 起動 + 終了 | rules 層の code<->docs 整合 (= pair 台帳 + アンカー生存、 同スコープの dead link は docs-check step 4 が skip) |

## 反応規律

| timing | 反応すべき出力 | 行動 |
|---|---|---|
| 起動時 | `docs-check FAIL ≥ 1` | 同 session fix |
| 起動時 | `PC: unknown` (= pc-labels.txt 未登録) | `<LocalHostName> <label>` を追記、 即報告 |
| 終了時 Step 2 | `stale_rules ≥ 1` | 真の dead rule のみ退役 commit (= 自走) |
| 終了時 Step 2 | `dup_pairs ≥ 1` | 中身確認 (= 真値分散なら集約 / reference なら残置) |
| 終了時 Step 2 | `docs-check FAIL ≥ 1` | 即 fix |

起動時 `stale_rules` / `dup_pairs` は無視 (= 終了時走り切りで起動クリーン前提)。 終了時は自走、 失敗は revert。 hook install = `setup-hooks.sh`。

## 文書庫運用 (= lazy 設計原則)

`rules/lazy/*.md` + `profile/profile-*.md` + `projects/<P>/rules/lazy/*.md` は**文書庫**。 hook 自動 inject は不採用、 シチュエーション認識時に作業直前に自発 Read する設計。

### 設計原則

- frontmatter `triggers:` に**シチュエーション**を自然言語記述 (= 「Agent tool 起動の直前」 等)
- 特定発話依存 trigger 禁止 (= 自然な作業文脈で認識できるシチュエーションのみ)
- 該当見落としが形骸化の温床 → 常時 load 側に「該当作業前に必ず Read」 を集約
- 新規追加時は `triggers:` 必須 + 常時 load file からのリンク必須 (= 「読まれない rule」 を作らない)

## 新 script 追加手順

1. **置き場所** = `.tooling/<name>.{sh,py}`。 LLM 不使用 / token 自動消費ゼロを死守
2. **発火経路** を 3 つから選ぶ (= PreToolUse 系は「発火時 = 判断後で手遅れ」 で非推奨):
   - **起動時 Phase B-共通** (= `startup-status.sh` に集約) → 軽量 1 行 summary のみ
   - **SessionEnd hook** (= settings.json の SessionEnd 配列)
   - **git pre-commit hook** (= `precommit-conflict-check.sh` 参照)
3. **失敗は fail-open**: `exit 0` で main 処理を止めない、 stderr に 1 行ログのみ
4. **出力先**: 1 行 summary → stdout / session 毎の生成物 → `.tooling/_output/<name>.md` (= gitignore 済) / 履歴 → `journal/<date>/session-NN-<name>.jsonl`
5. **本 file と `.tooling/_README.md` の表に追記**
6. **`setup-hooks.sh` 更新** (= 新 hook を install すべき手順を idempotent に追加)
7. **docs-check FAIL 0 維持確認**

## 継続的自己強化ループ

真値 = `rules/always.md § meta` (= 弱点パターン発見時の機構自己拡張)。 本 file は機構の具体実装に集中し、 運用フローは always.md § meta に集約。

## base 同期の正規経路

- agent-template との `.tooling` 同期は `sync-from-base.sh` / `promote-to-base.sh` 経由、 手 cp 禁止
  - Why: 手 cp は synced-paths 契約と履歴を素通りし、 drift の出所が追えなくなる
  - **例外は sync 機構自身の 2 file** (= `sync-from-base.sh` / `promote-to-base.sh`)。 `.synced-paths.txt` の対象外で自分を運べないため、 base checkout からの手 cp が唯一の更新経路 (= bootstrap 問題、 init 時にのみ配布される)
  - How to apply: 手 cp したら commit message に base の版 (= tag or sha) を明記する (= 履歴が追えなくなる Why への最小の埋め合わせ)
- 昇格時の匿名化 (= 操作者固有記述の除去) は promote 前に派生側 file で済ませる (= base 側で直すと次の promote で戻る)
- **base に payload file を足したら `.synced-paths.txt` に列挙か `!` 除外宣言のどちらかを必ず書く** (= 制御 file 自身は sync 対象外なので、 忘れると「base は出荷しているのに派生に降りない」 が無検出で成立する)
  - Why: 出荷と配布経路が別 file に分かれている構造的な穴、 base CI の `synced-paths-check.sh` が両方向 (= 死に entry / 宣言漏れ) を機械検出する
