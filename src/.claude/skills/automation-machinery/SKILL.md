---
title: 自動化機構運用
description: 自動化 script の発火経路 / 出力 / 反応規律 (機構改修時の参照)
updated: "2026-10-26"
stable: true
when_to_use: 自動化機構 (`.tooling/*`) を改修する直前 / settings.json の hook 配列を編集する直前
---

# 自動化機構運用

出荷する自動化は全部 LLM 不使用で、`git log` + `regex` + `grep` で機械抽出する。token の自動消費はゼロである。

## 機構と発火

下の表は base が出荷する script。**派生で script を足したらこの表に 1 行足す**。`.tooling/_README.md` は表を持たず、本 file を真値として指すだけである。

| script | 発火 | 出力 |
|---|---|---|
| `.tooling/startup/startup-status.sh` | 起動時 Phase B-共通 | stdout 1 ブロック。冒頭は `PC: <label>` 行である |
| `.tooling/startup/check-launch-pins.py` | startup-status から (`step_launch_pins`) | `model_pin: ok` / `PINNED <場所>` / `UNPINNED`、`effort_pin: ok` / `OVERRIDDEN <場所>` / `UNPINNED`。起動の経路が model の版を名指ししていないか、launcher の `--effort` が環境変数に上書きされていないかを測る。起動 launcher を持つ派生でだけ測り、無ければ `skipped` である |
| guard deploy (startup-status 内蔵) | 起動時 startup-status | `guard_deploy: ok` / `STALE` / `UNKNOWN`。動いている番人の clone が origin/develop と揃っているかを見る。番人の直しは merge しただけでは効かない |
| `.tooling/distribute/guard-update.sh` | 手動。`guard_deploy STALE` が出た時に流す | repo の pull・番人の clone を develop に揃えて導入し直す・設定の配布。配る script を持つ派生だけが持つ |
| `.tooling/startup/check-deployed-clones.sh` | startup-status から (`step_clone_deploys`) | `clone_deploy(<名前>): ok` / `BEHIND <n>` / `UNKNOWN`。この機械が手元の clone から配備している repo が、追う branch の origin より遅れていないかを見る。見るのは派生が `.tooling/startup/deployed-clones.txt` に宣言した clone だけで、file が無ければ何も出さない。雛形は `deployed-clones.example.txt`、test は `tests/test-deployed-clones.sh` である |
| `.tooling/startup/pc-labels.txt` | startup-status から | PC 識別。雛形は `pc-labels.example.txt` である |
| `.tooling/startup/detect-stale-rules.sh` | startup-status から | 7 日無更新 rule 一覧。`stable: true` と `_README.md` は除外する |
| `.tooling/startup/detect-duplicates.py` | startup-status + 終了時 Step 2 | `.tooling/_output/duplicates.md` |
| `.tooling/session-end/extract-artifact-index.sh` | 終了時 Step 2。引数に当 session の journal 階層を取る | `journal/<date>/session-NN-auto-index.jsonl`。commit subject は 100 字で切る。引数の階層へ書けない session では、書かずに exit 1 する |
| `.tooling/commit/precommit-conflict-check.sh` | git pre-commit hook | stderr で重複警告を出す。blocking はしない |
| `.tooling/docs-check/docs-check.sh` | 終了時 Step 2 + 手動 | PASS / WARN / FAIL。FAIL ≥ 1 は同 session で fix する |
| `.tooling/docs-check/docs-scan.py` | docs-check step 1-5 | `step \| level \| message` の TSV。文言は docs-check.sh と 1 対 1 で対応する |
| `.tooling/docs-check/journal-integrity.py` | docs-check step 9 | 違反 1 行ずつ。単一パスで数百 file を捌く |
| `.tooling/docs-check/check-rule-references.py` | docs-check step 12 | 実在しない参照 1 行ずつ。常時 load / skill に加えて `_README.md` と `vision.md` も見る。階層が `## repo` で宣言した repo は、実在する入口 dir で始まる綴りだけ測る。裸の file 名 / placeholder / `external-paths: true` の file は対象外である |
| `.tooling/docs-check/check-rule-hits.py` | docs-check step 13 | 記録を書き漏らした session 1 行ずつ。その階層が記録を始めた日以降のみ対象である |
| `.tooling/docs-check/check-vision-shape.py` | docs-check step 14 | 必須節の欠落と段落数超過 1 行ずつ。上限の根拠は script の docstring が持つ |
| `.tooling/rules/build-rule-registry.py` | 手動 + docs-check step 11 (`--check`) | **階層ごと**の `<tier>/rules/registry.jsonl`。ID 台帳で、ID は階層内で一意かつ不変である。中身が変わる台帳だけ書き、書けない階層は書かずに exit 1 する。書式と使い方は `.claude/skills/rule-registry/SKILL.md` が持つ |
| `.tooling/rules/rule-hits-summary.py` | startup-status + 手動 | 発火実績 1 行 summary。全階層の台帳と `*-rule-hits.jsonl` を読む。`--detail` は内訳、`--drift` は出自、`--unresolved` は寄らなかった記録、`--find` は ID 検索である。容量超過時の候補出しもこの集計を借りる。test は `tests/test-rule-hits-summary.sh` である |
| `.tooling/startup/check-static-capacity.sh` | startup-status から | `static_capacity: OK` / 超過した階層と削減候補。階層ごとの常時 load と skill の一覧を数える。上限の真値は script 冒頭にあり、超過は exit 1 である |
| `.tooling/lib/guard-may-write.py` | 引数や走査で決まる階層へ書く script が、書く前に呼ぶ。extract-artifact-index と build-rule-registry が当たる | exit 0 = 書いてよい。番人が無い機械 / session の外 / 訊く口の無い古い番人もここに入る。exit 1 = 入口の番人が拒んだ。番人の 1 行を stderr に出す。判定は番人が持ち、ここは訊くだけである |
| `.tooling/lib/skill-listing.py` | check-static-capacity (階層ごと) + `--list` | 1 行 1 file の一覧バイト数 (`description` + `when_to_use`)。`--list` はその階層の一覧で、ハーネスが gitignored な folder を探さない分の代わりになる |
| `.tooling/docs-check/check-positive-form.py` | docs-check step 15 | 否定形の主文 1 行ずつ。書式の真値は `.claude/skills/rule-registry/SKILL.md § 表現形式` が持つ |
| `.tooling/startup/capacity-candidates.py` | check-static-capacity の超過時 | バイト数降順の削減候補 + 発火実績。「少し削って測り直す」の往復を作らないための出力である |
| `.tooling/hooks/go-gate-reminder.sh` | UserPromptSubmit hook | GO 判定リセットの極短注入。判定本体は `rules/always.md § forbidden` にあり、hook は再武装のみ行う |
| `.tooling/hooks/skill_gate.py` (+ `skill_triggers.py`・`skill_reads.py`・表 `skill-triggers.toml`) | PreToolUse (全部の道具)・UserPromptSubmit・SessionStart hook | 表の操作に当たり、会話の記録にその skill を呼んだ跡か Read で読んだ跡が無ければ、道具を 1 回止めて全部まとめて名指す。表の操作は、道具・path・命令・作業の folder・発話・起動の環境である。サブエージェントは自分の記録を見る。発話と起動は止めず、1 行の注意で済ませる。skill ごとに 1 session に 1 回で、読めない時は通す。test は `tests/test-skill-gate.sh` である |
| git hook guard (startup-status 内蔵) | 起動時 startup-status | `armed` / `DISARMED` / repo 名一覧。git は hooksPath を 1 つしか見ず、local 上書き 1 個で scan が丸ごと死ぬ |

派生で足す例は、禁止語 detector (`detect-company-terms.sh`) / 起動 launcher / 終了時の事前検証 / 発火記録の集計である。置けば startup-status が拾い、無ければ skip する。台帳と記録は base が出荷し、どう集計するかは派生の持ち物である。

## 反応規律

| timing | 反応すべき出力 | 行動 |
|---|---|---|
| 起動時 | `docs-check FAIL ≥ 1` | 同 session fix |
| 起動時 | `PC: unknown` (pc-labels.txt 未登録) | `<LocalHostName> <label>` を追記、即報告 |
| 起動時 | `clone_deploy BEHIND` | ブリーフィングで伝え、その repo の配備の手順を踏む。手順は派生が持つ |
| 終了時 Step 2 | `stale_rules ≥ 1` | 真の dead rule のみ退役 commit。自走する |
| 終了時 Step 2 | `dup_pairs ≥ 1` | 中身確認。真値分散なら集約、reference なら残置する |
| 終了時 Step 2 | `docs-check FAIL ≥ 1` | 即 fix |
| 終了時 Step 2 | 発火記録 | 当 session で効いた / 違反した ID を `*-rule-hits.jsonl` へ |

起動時 `stale_rules` / `dup_pairs` は無視する。終了時に走り切るので、起動はクリーンが前提だからである。終了時は自走、失敗は revert。hook install = `setup-hooks.sh`。

### detector を書く時の実装規律

- **opt-out / suppress marker は「対象行の上」も見る**: 理由を書く長さのコメントは行末に収まらないので上に書かれる。同一行だけ見る実装は、既に打たれている marker を黙って無効化する
  - Why: path を見る gate が同一行限定で、数か月前から打たれていた marker が効かず fresh clone で常時赤だった実例がある。marker を同一行に押し込む対症より判定側を広げるのが正
- **検出は環境に依らず同じ色を出す形で作る**: build 生成物 / 実行時生成物への参照は「未 build なら赤」になる。opt-out を用意するだけでなく**既存の全該当箇所に打ってから** landed させる
- **allow-list は構造で書く**: exact 一致の行は次の 1 件で破れる。例えば雛形とその複製のような「構造上かならず一致する組」は、判定側で外す
- **baseline 方式の出力に「どこに残っているか」を含める**: 件数だけ出すと、1 箇所直しても数が減らない時に担当が判断できない。例えば basename 単位 dedup が当たる

### ドリフトの守り手を選ぶ

- **「完治」の定義 = 全 claim に守り手が割り当たり、無所属の文が無い状態**。守り手の優先順 = 生成 (手書き廃止) > 契約テスト (挙動主張はテスト名を pin) > 真値一冊化 > anchor 検査
  - Why: 検査 tool を強くする方向より、主張を強い守り手へ押し込む方向が効く
- **同じ事実を 2 箇所に書くのは運用上あり**。条件 = **宣言結線** (pair / mirror 化)。敵は複製そのものでなく**未宣言の複製**で、誰にも結線されず別々に育って割れる
- **恒常 WARN は 0 が定常**。掃除は「除外で黙らせる」でなく対象別に正しい形 (機械修正 / 参照修正 / 構造 skip) を選ぶ
- 操作者の「表示が違う」報告は、成果物より先に配信経路 (キャッシュ / 常駐 service) の故障を疑う

## 新 script 追加手順

1. **置き場所** = `.tooling/<役割の folder>/<name>.{sh,py}`。folder の意味の真値は `.tooling/_README.md § folder` が持つ。複数の役割から呼ばれる部品だけ `lib/` に置く。LLM 不使用 / token 自動消費ゼロを死守
2. **発火経路** = 起動時 `startup-status.sh` 集約 (軽量 1 行 summary のみ) / 終了時 Step 2 (階層を引数に取る物) / git pre-commit の 3 択。PreToolUse 系は「発火時 = 判断後で手遅れ」で非推奨である
3. **失敗は fail-open**: `exit 0` で main 処理を止めない、stderr に 1 行ログのみ
4. **重い script は最後に `elapsed: N.Ns` を出す**。対象は test / build / gate / CI と、それを束ねる入口である
   - Why: 遅くなったことに気づけるのは数字が出ている時だけ。出ていないと「そういうもの」として受け入れてしまう
   - 閾値で止めない。仕方ないのか壊れているのかは、数字を見てから**中身を読んで**決める。1 回の測定で決めつけない。初回はキャッシュが冷たく数倍出るためである
5. **出力先**: 1 行 summary → stdout / session 毎の生成物 → `.tooling/_output/<name>.md` (gitignore 済) / 履歴 → `journal/<date>/session-NN-<name>.jsonl`
6. **本 file の § 機構と発火 の表に追記**する。`.tooling/_README.md` は表を持たず、本 file を真値として指すだけである。出力に反応が要るなら § 反応規律 の表にも 1 行足し、起動時 / 終了時 / commit 時のどこで反応するかを書く
7. **`setup-hooks.sh` 更新**。新 hook を install すべき手順を idempotent に追加する
8. **docs-check FAIL 0 維持確認**

機構自己拡張の運用フローは `rules/always.md § meta` が持ち、本 file は具体実装に集中する。型との同期の経路は `.claude/skills/base-sync/SKILL.md` が真値で、`sync-from-base.sh` / `promote-to-base.sh` / `.synced-paths.txt` の書き方を持つ。
