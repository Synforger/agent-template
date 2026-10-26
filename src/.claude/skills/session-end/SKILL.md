---
title: session の締め (終了手順 Step 0〜3)
description: 終了発話か入れ替えの引き金から push (引き金なら起動し直し) までの手順
updated: "2026-10-26"
when_to_use: 操作者が断定形で終了を示した直後 (「終わり」「締めよう」「寝る」) / `<session-rollover phase="close">` が届いた時
---

# session の締め

Step 0〜3 を全部、この順で踏む。発動の判断 (断定形の終了発話か) は `CLAUDE.md § 終了時` が真値。

## Step 0 (発動前検証、最初に 1 回)

直近の操作者の発話に終了発話も引き金 (`Automatic session rollover` で始まる行) も無ければ幻なので終了せず作業継続。容量残と journal の採番も同時に取り、以降の Step で同じ探索を繰り返さない。検証の script を持つ派生は、それを journal の階層を引数にして流す。

## Step 1 (直列、操作者承認不要)

**その session で初めて見えた** 一面 / 好み / 癖だけ `profile/profile.md` に **エージェント判断で追記**。**有った時だけ書く**。毎 session の更新義務はなく、既出の言い換えは対象外。書く時は Step 0 の headroom に収まる形で**1 回で書く**。

## Step 2 (並列一括、エージェント自走で完遂)

- **自動抽出 script 実行**: journal .md 書く**前に**実行。jsonl は当 session の触跡記録で、PC ローカルの artifact
  - `bash .tooling/session-end/extract-artifact-index.sh <journal-dir> --nn <NN>`: 引数は当 session が touch した階層の journal dir で、親とサブの両方なら引数を変えて 2 回流す。NN は Step 0 が出した採番をそのまま渡す。そうすると、同じ日の別の機械の journal を取り込んだ後でも番号がずれない
  - `python3 .tooling/startup/detect-duplicates.py` (重複 section cache 更新)
- **型へ返していない物の洗い出し** (必須): この session で作った形・道具の足りない所の回避・手順のうち、他でも使う物を 1 つずつ挙げ、型 (道具・テンプレ・親の skill) へ返したか、持ち主のタブへ依頼を出し切ったかを見る。どちらでもない物は締める前に出し切る。別のタブとの連絡の決めは、そのエージェントの `rules/always.md` が持つ
- **plan の棚卸し** (必須、触れた階層全部): `plans/` の生きている file を 1 本ずつ見て、**plan として終わった物だけ `_archive/` へ移す**。操作者待ちが plan の最後なら移し、途中なら残す。判断軸と手順は `rules/always.md § git` が持つ。残す file は最新化する。完了マークの付与、新規の残タスクの追加、state snapshot (develop/main の tip・open PR・branch) の更新、古い時点の記述の掃除をする。横断は `plans/` 直下、プロジェクト固有は `projects/<P>/plans/` に置く
- **vision 更新** (現在地が動いた session のみ): 触れた階層の `vision.md` を**上書き**し、動いた時だけ書き換える。毎 session の更新義務はない。中身は状態だけで、やることは `plans/` と journal が持つ。無ければ作る。**既にある行を書き換える**。段落は増やさない。節と段落数は `.tooling/docs-check/docs-check.sh` step 14 が見る
- **発火記録**: 効いた/違反 ID を `journal/<date>/session-NN-rule-hits.jsonl` へ書く。手順は `.claude/skills/rule-registry/SKILL.md` が持つ
- **ジャーナル記入**: **書く前に階層を起動 keyword から再導出**。compaction で階層文脈が消えるためで、サブプロ起動ならサブプロ journal が正、採番アンカーは自階層の .md から取る。**触れた階層全部に 1 本ずつ書く**。階層は自己完結している。`normal` は `journal/YYYY-MM-DD/session-NN.md`、project は `projects/<P>/journal/YYYY-MM-DD/session-NN.md`、subproject は `projects/<P>/subprojects/<S>/journal/YYYY-MM-DD/session-NN.md` に書く。親とサブの両方を触ったら両階層に 1 本ずつ。NN は Step 0 出力の採番をそのまま使い、階層ごとに独立している。規律は `journal/_README.md`、フォーマットは `journal/_template.md` が持つ。**続きが在る時は先頭に `## 生きている依頼`** を置く。操作者の「やって」を言葉のまま、その範囲、次の 1 手を書く。次の 1 手はエージェントが打つ手で書き、「操作者を待つ」と書くのは、答えで次の 1 手が決まる問いを出している時だけ。前の journal から運ばれて来た依頼も、終わるか操作者が取り下げるまで毎回運ぶ
- **操作者が答えた物は「決めた事」として書き、書く前に真値 (操作者のメモ・plan) へ入れる**。答えは「はい」の形に限らない。方向を言った時も、操作者自身が案を出した時も答えで、例えば「〜の方が絶対良くね」「〜してもいいよ」が当たる。決めた日時と操作者の言葉を添える
  - **`操作者の返事待ち` に書くのは、訊いた後の操作者の発話にその問いへの言及が 1 つも無い物だけ**。書く前に、この session の操作者の発話を問いごとに照らす。context に在るうちに行う
  - Why: 答えの出た問いを「返事待ち」と書くと、次の session が同じ問いを訊き直すか、確かめるために会話の記録を全部読み直して context を食う。journal だけで、何が決まって何が残っているかが読める形にする。操作者が 2 度答えた問いを 2 session 続けて「返事待ち」と書いた実例がある
- **`startup-status.sh` 実行 → 全指標走り切り**: docs-check を内包するので 1 回で済む。エージェント判断で commit まで完遂する。報告は Step 3 締めで 1 行のみ

## Step 3 (直列、必須)

**触った repo ごとに commit する**。親の repo から gitignore された階層の folder が自分の repo を持つ時 (folder 直下に `.git` があり、remote なしでこの PC の中だけの履歴を持つ) は、その階層の file を `git -C <階層> add -A && git commit` で先に閉じる。その repo は pull / push しない。remote が無いため。親の repo は、階層の外の file (親の `rules/` / `.claude/skills/` / `.tooling/` / `profile/` 等) を触った時だけ、下の連続実行で締める。

`git add -A && git commit` → `git pull --rebase --autostash` → `git push` **必ず連続実行**で締める。push の直前に再 pull するのは、session 中に他 PC が push して fast-forward できなくなった分を吸収するため。push が失敗したら、pull → rebase → push のリトライを 1 サイクル、エージェント自前で行う。2 度目も失敗して conflict が残ったら、操作者へ報告して手動解決する。

複数の PC で同じエージェントを clone している場合、**同期点は開始時の pull とこの Step 3 の 2 つ**。同時起動は避ける。共通基盤 (`profile/` / `rules/` / `.claude/skills/` / `CLAUDE.md` / `.tooling/`) を別 PC が同時に編集していると rebase が止まるので、その時は操作者へ報告。新しい PC の立ち上げは `.claude/skills/base-sync/SKILL.md` が持つ。

## 自動の入れ替えで締める時 (引き金が届いた時)

引き金は client の backend が打つ発話で、1 行目が `Automatic session rollover, sent by the client`、中に `<session-rollover phase="close" reason="context|idle" …>` が在る。context が 60% に届いた作業中のタブか、40% を超えて 50 分静かなタブに届く。締め方は上の Step 0〜3 のまま。違うのは次の 6 つ。

- **引き金だけで締めへ入る**。発動に操作者の了承は要らない
- **作業中なら、区切りまで進めてから締める**。区切りは、次の session が途中から拾える所を指す。書きかけの file を閉じた時、走っている検査の結果を読んだ時、開いた PR や branch の状態を書ける時が当たる。操作者に返していない報告が在れば、締めの前に出す
- **引き金の後に来た仕事は、次の session へ渡す**。まだ答えていない操作者の発話は、引き金と同時に来た物も、締めの途中に届いた物も、`操作者の最後の頼み` に言葉のまま書き、`continue` で起動し直す。新しい session がブリーフィングの後に答える
- **引き金の後の終わり方は、起動し直しの 1 つだけ**。道具が断った・push が通らない・番人が止めた・別のタブの道具が壊れている、のどれでも、このタブで原因を直して打ち直す。自分の道具は自分が直す。操作者や別のタブの返事を待って止まらない。60% を超えたタブが待つと、誰も動かない。直した事は journal に書く
- **journal の `## 入れ替えの時点` と `## 生きている依頼` が引き継ぎの本体**。`## 入れ替えの時点` は毎回書く。続ける物が無い時も書く。新しい session はこの節をブリーフィングで上から読み上げるので、操作者がそのまま読める文で書く
  - 引き金: 時刻 / context の割合 / 静かだったか作業中か。引き金の `reason` と `context_pct` から取る
  - 操作者の最後の頼み: 言葉のまま
  - 進み: 終わった物と途中の物を分けて
  - 操作者の返事待ち: 訊いたまま答えが来ていない問いと、出したまま反応が無い報告。無い時は「なし」と書く
  - 最後の出力: 操作者に出した最後の報告を全文そのまま写す。引き金が 60% でも 40% でも、操作者は見ていない物として扱う。新しい session がブリーフィングの最後に全文を出し、操作者はそこから続きを打てる
  - `## 生きている依頼` は続ける物が在る時だけ書く。新しい session はここの次の 1 手から続ける。無ければ、新しい session は読み上げた後に待つ
- **Step 4 (最後の 1 手)**: Step 3 の push が通り、最後の出力を書き終えてから打つ。打つとこのタブは約 1 秒で終了し、同じ階層で起動し直される。道具は、この会話が書いた journal に `## 入れ替えの時点` が無い・commit していない・push していない時は頼まずに止まり、足りない物を 1 行出す。その Step に戻って済ませてから打ち直す

  ```
  tabs rollover <continue|wait>
  ```

  journal は Write / Edit で書く。道具はこの会話の記録から、Write / Edit で書いた journal を探すので、Bash で書いた journal は見つからず、断られる。push は見ない。同じ clone で起動し直すので、push は次の会話の締めが運ぶ。

  **`continue` か `wait` かは、次の 1 手が操作者の答え無しに打てるかで決める**。打てるなら `continue` を使う。起動の後、最後の出力を出してから、生きている依頼の次の 1 手へ進む。作業の途中で区切った時と、続けろという言いつけが生きている間に区切りで報告を出した時がここに当たる。報告は区切りで、操作者待ちではない。操作者へ問いを出していて、その答えで次の 1 手が決まる時だけ、`reason="context"` でも `wait` を使う。起動の後、最後の出力を出して、操作者の答えから続ける。`reason="idle"` は `wait`。階層は道具が決める (`AGENT_TIER`、無い会話は最初の発話から)。session の途中で階層を切り替えた時だけ `--tier <階層>` を付ける

**同じ session で 2 度目の締めは、1 度目の journal に書き足す**。番号は 1 度目の物を使う。

**引き金の締めでは Step 3 の push が止まっても Step 4 を打つ**。commit まで済んでいれば道具は通す。止まった理由は journal に書き、次の session の締めで push する。Step 3 の「操作者報告 + 手動解決」は、操作者の終了発話で締める時だけの扱い。
