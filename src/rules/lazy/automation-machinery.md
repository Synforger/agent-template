---
title: 自動化機構運用 + 文書庫運用 (= lazy)
description: 自動化 script の発火経路 / 出力 / 反応規律 + lazy 文書庫の設計原則 (= 機構改修 / 新 lazy 追加時の参照)
updated: 2026-09-21
stable: true
triggers: 自動化機構 (`.tooling/*`) を改修する直前 / 新 lazy file を追加する直前 / settings.json の hook 配列を編集する直前
capacity: 10KB
---

# 自動化機構運用 + 文書庫運用

出荷する自動化は全部 LLM 不使用、 `git log` + `regex` + `grep` で機械抽出 (= token 自動消費ゼロ)。

## 機構と発火 (= base 出荷分)

下の表は base が出荷する script。 **派生で script を足したらこの表に 1 行足す** (= `.tooling/_README.md` は表を持たず本 file を真値として指すだけ)。

| script | 発火 | 出力 |
|---|---|---|
| `.tooling/startup-status.sh` | 起動時 Phase B-共通 | stdout 1 ブロック (= 冒頭 `PC: <label>` 行) |
| `.tooling/pc-labels.txt` | startup-status から | PC 識別 (= 雛形 = `pc-labels.example.txt`) |
| `.tooling/detect-stale-rules.sh` | startup-status から | 7 日無更新 rule 一覧 (= `stable: true` + `_README.md` は除外) |
| `.tooling/detect-duplicates.py` | startup-status + SessionEnd hook | `.tooling/_output/duplicates.md` |
| `.tooling/extract-artifact-index.sh` | SessionEnd hook | `journal/<date>/session-NN-auto-index.jsonl` (= commit subject は 100 字で切る) |
| `.tooling/precommit-conflict-check.sh` | git pre-commit hook | stderr で重複警告 (= blocking なし) |
| `.tooling/docs-check.sh` | 終了時 Step 2 + 手動 | PASS / WARN / FAIL (= FAIL ≥ 1 は同 session fix) |
| `.tooling/lib/docs-scan.py` | docs-check step 1-5 | `step \| level \| message` の TSV (= 文言は docs-check.sh と 1 対 1) |
| `.tooling/lib/journal-integrity.py` | docs-check step 9 | 違反 1 行ずつ (= 単一パスで数百 file を捌く) |
| `.tooling/lib/check-rule-references.py` | docs-check step 12 | 実在しない参照 1 行ずつ (= 常時 load / lazy に加えて `_README.md` と `vision.md` も見る。 階層が `## repo` で宣言した repo は、 実在する入口 dir で始まる綴りだけ測る。 裸の file 名 / placeholder / `external-paths: true` の file は対象外) |
| `.tooling/lib/check-rule-hits.py` | docs-check step 13 | 記録を書き漏らした session 1 行ずつ (= その階層が記録を始めた日以降のみ対象) |
| `.tooling/lib/check-vision-shape.py` | docs-check step 14 | 必須節の欠落と段落数超過 1 行ずつ (= 上限の根拠は script の docstring) |
| `.tooling/build-rule-registry.py` | 手動 + docs-check step 11 (`--check`) | **階層ごと**の `<tier>/rules/registry.jsonl` (= ID 台帳、 ID は階層内で一意かつ不変。 書式と使い方 = `rules/lazy/rule-registry.md`) |
| `.tooling/lib/capacity-candidates.py` | 派生の容量 script が超過を出した時 | バイト数降順の削減候補 + 発火実績 (= 「少し削って測り直す」 の往復を作らない) |
| `.tooling/go-gate-reminder.sh` | UserPromptSubmit hook | GO 判定リセットの極短注入 (= 判定本体は `rules/always.md § forbidden`、 hook は再武装のみ) |
| `staledocs` (= 外部 CLI + `.staledocs.yaml`) | startup-status から | rules 層の code<->docs 整合 (= pair 台帳 + アンカー生存。 同スコープの dead link は docs-check step 4 が skip) |
| git hook guard (= startup-status 内蔵) | 起動時 startup-status | `armed` / `DISARMED` / repo 名一覧 (= git は hooksPath を 1 つしか見ず、 local 上書き 1 個で scan が丸ごと死ぬ) |

派生で足す例 (= 置けば startup-status が拾う / 無ければ skip): 禁止語 detector (`detect-company-terms.sh`) / 階層別容量 (`check-static-capacity.sh`) / 起動 launcher / 終了時の事前検証 / 発火記録の集計 (= 台帳と記録は base 出荷、 どう集計するかは派生の持ち物)。

## 反応規律

| timing | 反応すべき出力 | 行動 |
|---|---|---|
| 起動時 | `docs-check FAIL ≥ 1` | 同 session fix |
| 起動時 | `PC: unknown` (= pc-labels.txt 未登録) | `<LocalHostName> <label>` を追記、 即報告 |
| 終了時 Step 2 | `stale_rules ≥ 1` | 真の dead rule のみ退役 commit (= 自走) |
| 終了時 Step 2 | `dup_pairs ≥ 1` | 中身確認 (= 真値分散なら集約 / reference なら残置) |
| 終了時 Step 2 | `docs-check FAIL ≥ 1` | 即 fix |
| 終了時 Step 2 | 発火記録 | 当 session で効いた / 違反した ID を `*-rule-hits.jsonl` へ |

起動時 `stale_rules` / `dup_pairs` は無視 (= 終了時走り切りで起動クリーン前提)。 終了時は自走、 失敗は revert。 hook install = `setup-hooks.sh`。

### detector を書く時の実装規律

- **opt-out / suppress marker は「対象行の上」も見る**: 理由を書く長さのコメントは行末に収まらないので上に書かれる。 同一行だけ見る実装は、 既に打たれている marker を黙って無効化する
- **環境で赤くなる検出を作らない**: build 生成物 / 実行時生成物への参照は「未 build なら赤」になる。 opt-out を用意するだけでなく**既存の全該当箇所に打ってから** landed させる
- **allow-list は構造で書く**: exact 一致の行は次の 1 件で破れる (= 雛形とその複製のような「構造上かならず一致する組」 は、 判定側で外す)
- **baseline 方式の出力に「どこに残っているか」を含める**: 件数だけ出すと、 1 箇所直しても数が減らない時 (= basename 単位 dedup 等) に担当が判断できない

### ドリフトの守り手を選ぶ

- **「完治」 の定義 = 全 claim に守り手が割り当たり、 無所属の文が無い状態**。 守り手の優先順 = 生成 (= 手書き廃止) > 契約テスト (= 挙動主張はテスト名を pin) > 真値一冊化 > anchor 検査
  - Why: 検査 tool を強くする方向より、 主張を強い守り手へ押し込む方向が効く
- **同じ事実を 2 箇所に書くのは運用上あり**。 条件 = **宣言結線** (= pair / mirror 化)。 敵は複製そのものでなく**未宣言の複製** (= 誰にも結線されず別々に育って割れる)
- **恒常 WARN は 0 が定常**。 掃除は「除外で黙らせる」 でなく対象別に正しい形 (= 機械修正 / 参照修正 / 構造 skip) を選ぶ

## 文書庫運用 (= lazy 設計原則)

`rules/lazy/*.md` + `projects/<P>/rules/lazy/*.md` は**文書庫**。 hook 自動 inject は不採用、 シチュエーション認識時に作業直前に自発 Read する設計。

### 設計原則

- frontmatter `triggers:` に**シチュエーション**を自然言語記述 (= 「Agent tool 起動の直前」 等)
- trigger は自然な作業文脈で認識できるシチュエーションで書く (= 特定の発話に依存させない)
- 該当見落としが形骸化の温床 → 常時 load 側に「該当作業前に必ず Read」 を集約
- 新規追加時は `triggers:` 必須 + 常時 load file からのリンク必須 (= 「読まれない rule」 を作らない)

## 新 script 追加手順

1. **置き場所** = `.tooling/<name>.{sh,py}`。 LLM 不使用 / token 自動消費ゼロを死守
2. **発火経路** = 起動時 `startup-status.sh` 集約 (= 軽量 1 行 summary のみ) / SessionEnd hook / git pre-commit の 3 択 (= PreToolUse 系は「発火時 = 判断後で手遅れ」 で非推奨)
3. **失敗は fail-open**: `exit 0` で main 処理を止めない、 stderr に 1 行ログのみ
4. **重い script は最後に `elapsed: N.Ns` を出す** (= test / build / gate / CI と、 それを束ねる入口)
   - Why: 遅くなったことに気づけるのは数字が出ている時だけ。 出ていないと「そういうもの」 として受け入れてしまう
   - 閾値で止めない (= 仕方ないのか壊れているのかは、 数字を見てから**中身を読んで**決める)。 1 回の測定で決めつけない (= 初回はキャッシュが冷たく数倍出る)
5. **出力先**: 1 行 summary → stdout / session 毎の生成物 → `.tooling/_output/<name>.md` (= gitignore 済) / 履歴 → `journal/<date>/session-NN-<name>.jsonl`
6. **本 file の § 機構と発火 の表に追記**
7. **`setup-hooks.sh` 更新** (= 新 hook を install すべき手順を idempotent に追加)
8. **docs-check FAIL 0 維持確認**

機構自己拡張の運用フロー = `rules/always.md § meta` (= 本 file は具体実装に集中)。

## base 同期の正規経路

- agent-template との `.tooling` 同期は `sync-from-base.sh` / `promote-to-base.sh` を通す
  - Why: 手 cp は synced-paths 契約と履歴を素通りし、 drift の出所が追えなくなる
  - **例外は sync 機構自身の 2 file** (= `sync-from-base.sh` / `promote-to-base.sh`)。 `.synced-paths.txt` の対象外で自分を運べないため、 base checkout からの手 cp が唯一の更新経路 (= bootstrap 問題、 init 時にのみ配布される)
  - How to apply: 手 cp したら commit message に base の版 (= tag or sha) を明記する (= 履歴が追えなくなる Why への最小の埋め合わせ)
- 昇格時の匿名化 (= 操作者固有記述の除去) は promote 前に派生側 file で済ませる (= base 側で直すと次の promote で戻る)
- **中身が派生ごとに違う file は `!` 除外へ置く** (= 索引 / 機構の表 / allow-list。 列挙したままにすると、 昇格のたびに他派生へ他人の実 file 名が流れる)
- **base に payload file を足したら `.synced-paths.txt` に列挙か `!` 除外宣言のどちらかを必ず書く** (= 制御 file 自身は sync 対象外なので、 忘れると「base は出荷しているのに派生に降りない」 が無検出で成立する)
  - Why: base CI の `synced-paths-check.sh` が両方向 (= 死に entry / 宣言漏れ) を機械検出する
