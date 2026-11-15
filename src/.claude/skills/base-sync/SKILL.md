---
title: 型と器の取り込み (型との同期と、新しい機械での立ち上げ)
description: 型 (agent-template) と `.tooling` を同期する正規経路と、新しい機械で器を建ててエージェントを動かすまでの順番
updated: "2026-10-26"
when_to_use: 型から取り込む・型へ上げる直前 / 型に file を足した直後 / 新しい機械でエージェントを初期構築する時
---

# 型と器の取り込み

2 つの取り込みを持つ。**型** = このエージェントの機構・雛形・共通 skill の出どころ (agent-template)。**器** = 道具・エージェントの体・設定・記録を 1 か所に置く folder。その一番上の folder を根と呼び、環境変数 `AGENT_PLATFORM_ROOT` が指す。器の形と置き場の真値は、器の設計図の repo (manifest) の README が持つ。

## 型と `.tooling` を同期する

### 正規経路

- 型との `.tooling` の同期は `sync-from-base.sh` / `promote-to-base.sh` を通す
  - Why: 手 cp は synced-paths 契約と履歴を素通りし、drift の出所が追えなくなる
  - **例外は sync 機構自身の 2 file** (`sync-from-base.sh` / `promote-to-base.sh`)。`.synced-paths.txt` の対象外で自分を運べないため、型の checkout からの手 cp が唯一の更新経路になる。これは bootstrap 問題で、init 時にのみ配布される
  - How to apply: 手 cp したら commit message に型の版 (tag or sha) を明記する。履歴が追えなくなる Why への最小の埋め合わせである
- **昇格は、器の型の clone (`<器の根>/tools/agent-template`) から worktree を切って上げる**。`promote-to-base.sh` は、その clone があれば `<clone>.worktrees/<branch>` を切り、そこで commit と push をして、PR の案内もその中で出す。器の外の一時の folder へ clone すると、道具の folder にだけ当てた commit の名前が効かず、番人の commit の検査が名前の食い違いで止める
  - Why: 一時の folder へ clone する形で、昇格が 2 つのタブで続けて番人に止められた (2026-11-16)
- **上げた PR は、型の worktree の中で、エージェントの `.tooling/work/pr-land.sh <番号> --squash` を打って merge する**。直に `gh pr merge --delete-branch` を打つと、worktree で開いている branch は消えずに残り、消せなかった知らせは 1 行のエラーだけで流れる
  - Why: 2026-11-06 に型へ上げた PR 5 本の branch が remote に残った。消せなかったエラーの行を、出力の絞り込みで自分で隠していた
- **型の PR を作る・merge する `gh` と `pr-land.sh` は、`direnv exec <器の根>/tools …` を頭に付けて打つ**。型の口座の token は器の `tools/.envrc` が当てるが、エージェントの Bash は direnv を読まないので、付けないとエージェントの口座の token で打ち、PR の作成が権限で断られる (2026-11-15)
- 昇格時の匿名化 (操作者固有記述の除去) は promote 前に派生側 file で済ませる。型側で直すと次の promote で戻るためだ
- **中身が派生ごとに違う file は `!` 除外へ置く**。索引 / 機構の表 / allow-list が当たる。列挙したままにすると、昇格のたびに他の派生へ他人の実 file 名が流れる
- **型に payload file を足したら `.synced-paths.txt` に列挙か `!` 除外宣言のどちらかを必ず書く**。制御 file 自身は sync 対象外なので、忘れると「型は出荷しているのに派生に降りない」が無検出で成立する
  - Why: 型の CI の `synced-paths-check.sh` が両方向 (死に entry / 宣言漏れ) を機械検出する
- **何を降ろすかは型の宣言が決め、派生の `.synced-paths.txt` には例外だけを書く**。取り込みは、型が列挙する path と派生が足した path を、派生が `!` で外した物を除いて写す。型が後から足した file は、派生が何も書かなくても次の取り込みで降りる
  - **型が列挙する path を外す時は、`!<path>  # <理由>` で理由を書く**。理由の無い `!` 行は、`sync-from-base.sh` が名指して何も写さずに止まる。外している物は取り込みのたびに理由つきで並ぶ
  - Why: 理由の要らない `!` で共通の skill を黙って外した派生があり、その skill が持つ決まりがその派生にだけ無いまま動いた
- **取り込みが「files changed in this agent since the last sync」で止まったら、名指された file ごとに行き先を決める**。取り込みは前に写した型の版を `.synced-paths.txt` の `# synced from base:` の行に記録し、その後に派生だけが変えた・消した・足した file があると、何も写さずに止まる。記録が無い初めての取り込みでは、型の履歴に一度も無かった版を持つ file で止まる。他でも使う直しなら `promote-to-base.sh --file <path>` で型へ上げ、この派生だけの物なら `!<path>  # <理由>` で外し、要らない直しなら `SYNC_OVERWRITE=1` で取り込み直す。型も同じ file を変えていれば、手で合わせてから上げる
  - Why: 取り込みが、派生の方が新しかった skill 2 本を型の古い版で上書きした。commit の前の差分で気づいたが、見落とせば派生の直しが黙って消えていた
- **取り込みの最後の docs-check が赤なら、直してから commit する**。取り込みは赤の時に commit の案内を出さない。案内の命令は写した path だけを名指すので、同じ repo の別の作業を拾わない
- **型の取り込みも昇格も、既定は型の `develop`**。型の新しい物は develop に入り、main は release の時だけ進む
- **型から消した file は、`.synced-paths.txt` の行も同じ変更で消す**。死に entry は同じ検査が赤にする。派生の側の同名 file は、受け取った派生が自分で消す

## 新しい機械で動かす

器を建てて、その中でエージェントを動かすまでの順番。機械ごとの値 (口座・port・機械の名前・番人の設定) は repo に載せず、その機械の設定に置く。

1. **git の口座の認証を通す**: SSH key を作って口座ごとに登録する。口座ごとの host 名は `~/.ssh/config` に書く。clone の URL の書き換えは器の `config/platform/clone.toml` (書式は manifest の README)
2. **エージェントの体を器の中へ clone する**: `git clone <エージェントの repo> $AGENT_PLATFORM_ROOT/agents/<名前>` (根を決めていなければ `~/agent-platform`)
3. **manifest を器の中へ clone する**: `git clone <manifest の repo> $AGENT_PLATFORM_ROOT/manifest`
4. **器を建てる**: `$AGENT_PLATFORM_ROOT/manifest/bin/platform build` → `platform check` で欠けた物が無いこと。build は道具の clone・uv の環境・入口の命令・常駐の plist を器の中に作る。home に入口を差し込むのは `platform cutover` である。命令の使い方は manifest の README にある
5. **道具の口座と名前を当てる**: 道具の repo を触る口座の token は器の `secrets/` に置き (権限 600)、git の名前は `~/.gitconfig` の `includeIf "gitdir:<器>/tools/"` で道具の folder にだけ当てる
6. **その機械を真値へ登録する**: `.tooling/startup/pc-labels.txt` に `<LocalHostName> <label>` を 1 行足す。これが起動時の `PC:` 行の出どころになる。書き方は `pc-labels.example.txt` にある。機械ごとに違う path (家の folder 名など) は、設定を配る真値の中のその機械の欄に 1 行足してから配る
7. **shell の設定に器の根と起動の alias を足す**: `export AGENT_PLATFORM_ROOT=$HOME/agent-platform` と、エージェントを起動する alias。git の外なので機械ごとに手作業で行う。画面の配信を既定と別の port で起動する機械は、同じ file に port の環境変数も足す
8. **番人を配備する**: git を触る機械は必須である。導入も更新も `.tooling/distribute/guard-update.sh` の 1 本で行う。番人の置き場は器の根の下にあり、一覧は番人の README にある。番人の設定は機械ごとに操作者が置く。repo に載せない物で、エージェントは中身を提案するところまで行う。設定の中身は、境界の一覧・境界の中で資料を持たない folder・公開の文とコードの folder・形で決まる識別子の正規表現・送ってよい言い回し・送り先ごとの扱い。書式は番人の README にある
   - 番人の対象外にする repo は `git config guard.scope exempt` を設定する。私物の記録の木は明示の exempt が要る
9. **動作確認**: エージェントを起動して 1 発話し、起動の手順が最後まで通ること。起動の点検の `guard_deploy` と `clone_deploy` が `ok`

- 前の置き場で動いている機械は、新しく建てずに `platform cutover` で器へ切り替える。戻すのは `platform rollback` で、使い方は `platform --help` に出る
