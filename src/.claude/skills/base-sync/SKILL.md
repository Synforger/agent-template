---
title: 型と器の取り込み (= 型との同期と、 新しい機械での立ち上げ)
description: 型 (= agent-template) と `.tooling` を同期する正規経路と、 新しい機械で器を建ててエージェントを動かすまでの順番
updated: "2026-10-22"
when_to_use: 型から取り込む・型へ上げる直前 / 型に file を足した直後 / 新しい機械でエージェントを初期構築する時
---

# 型と器の取り込み

2 つの取り込みを持つ。 **型** = このエージェントの機構・雛形・共通 skill の出どころ (= agent-template)。 **器** = 道具・エージェントの体・設定・記録を 1 か所に置く folder。 その一番上の folder を根と呼び、 環境変数 `AGENT_PLATFORM_ROOT` が指す。 器の形と置き場の真値は、 器の設計図の repo (= manifest) の README が持つ。

## 型と `.tooling` を同期する

### 正規経路

- 型との `.tooling` の同期は `sync-from-base.sh` / `promote-to-base.sh` を通す
  - Why: 手 cp は synced-paths 契約と履歴を素通りし、 drift の出所が追えなくなる
  - **例外は sync 機構自身の 2 file** (= `sync-from-base.sh` / `promote-to-base.sh`)。 `.synced-paths.txt` の対象外で自分を運べないため、 型の checkout からの手 cp が唯一の更新経路 (= bootstrap 問題、 init 時にのみ配布される)
  - How to apply: 手 cp したら commit message に型の版 (= tag or sha) を明記する (= 履歴が追えなくなる Why への最小の埋め合わせ)
- 昇格時の匿名化 (= 操作者固有記述の除去) は promote 前に派生側 file で済ませる (= 型側で直すと次の promote で戻る)
- **中身が派生ごとに違う file は `!` 除外へ置く** (= 索引 / 機構の表 / allow-list。 列挙したままにすると、 昇格のたびに他の派生へ他人の実 file 名が流れる)
- **型に payload file を足したら `.synced-paths.txt` に列挙か `!` 除外宣言のどちらかを必ず書く** (= 制御 file 自身は sync 対象外なので、 忘れると「型は出荷しているのに派生に降りない」 が無検出で成立する)
  - Why: 型の CI の `synced-paths-check.sh` が両方向 (= 死に entry / 宣言漏れ) を機械検出する
- **派生の宣言は型の宣言に揃える** (= 取り込みは派生自身の `.synced-paths.txt` だけを読む。 型が宣言していて派生に列挙も `!` も無い path が在ると、 `sync-from-base.sh` は全部名指して何も写さずに止まる。 型と同じ行か、 降ろさないなら理由つきの `!` 行を足して流し直す)
- **型から消した file は、 `.synced-paths.txt` の行も同じ変更で消す** (= 死に entry は同じ検査が赤にする。 派生の側の同名 file は、 受け取った派生が自分で消す)

## 新しい機械で動かす

器を建てて、 その中でエージェントを動かすまでの順番。 機械ごとの値 (= 口座・port・機械の名前・番人の設定) は repo に載せず、 その機械の設定に置く。

1. **git の口座の認証を通す**: SSH key を作って口座ごとに登録する。 口座ごとの host 名は `~/.ssh/config` に書く。 clone の URL の書き換えは器の `config/platform/clone.toml` (= 書式は manifest の README)
2. **エージェントの体を器の中へ clone する**: `git clone <エージェントの repo> $AGENT_PLATFORM_ROOT/agents/<名前>` (= 根を決めていなければ `~/agent-platform`)
3. **manifest を器の中へ clone する**: `git clone <manifest の repo> $AGENT_PLATFORM_ROOT/manifest`
4. **器を建てる**: `$AGENT_PLATFORM_ROOT/manifest/bin/platform build` → `platform check` で欠けた物が無いこと (= 道具の clone・uv の環境・入口の命令・常駐の plist を器の中に作る。 home に入口を差し込むのは `platform cutover`。 命令の使い方は manifest の README)
5. **道具の口座と名前を当てる**: 道具の repo を触る口座の token は器の `secrets/` に置き (= 権限 600)、 git の名前は `~/.gitconfig` の `includeIf "gitdir:<器>/tools/"` で道具の folder にだけ当てる
6. **その機械を真値へ登録する**: `.tooling/startup/pc-labels.txt` に `<LocalHostName> <label>` を 1 行 (= 起動時の `PC:` 行の出どころ。 書き方 = `pc-labels.example.txt`)。 機械ごとに違う path (= 家の folder 名など) は、 設定を配る真値の中のその機械の欄に 1 行足してから配る
7. **shell の設定に器の根と起動の alias を足す** (= git の外なので機械ごとに手作業): `export AGENT_PLATFORM_ROOT=$HOME/agent-platform` と、 エージェントを起動する alias。 画面の配信を既定と別の port で起動する機械は、 同じ file に port の環境変数も足す
8. **番人を配備する** (= git を触る機械は必須): 導入も更新も `.tooling/distribute/guard-update.sh` の 1 本 (= 番人の置き場は器の根の下、 一覧は番人の README)。 番人の設定は機械ごとに操作者が置く (= repo に載せない物。 エージェントは中身を提案するところまで): 境界の一覧・境界の中で資料を持たない folder・公開の文とコードの folder・形で決まる識別子の正規表現・送ってよい言い回し・送り先ごとの扱い。 書式は番人の README
   - 番人の対象外にする repo は `git config guard.scope exempt` (= 私物の記録の木は明示の exempt が要る)
9. **動作確認**: エージェントを起動して 1 発話し、 `[go-gate] ...` の行が context に出ること。 起動の点検の `guard_deploy` と `clone_deploy` が `ok`

- 前の置き場で動いている機械は、 新しく建てずに `platform cutover` で器へ切り替える (= 戻すのは `platform rollback`。 使い方は `platform --help`)
