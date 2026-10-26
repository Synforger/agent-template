---
title: 公開の repo の作法 (利用者視点の文書と、検査の置き場)
description: 公開 repo の README・docs・PR の読者像と OK・NG のトーン、docs の 2 層構造、検査は local が真値で CI はその入口を呼ぶだけ
updated: "2026-10-26"
when_to_use: 公開 repo の README・docs を書く・直す直前 / 公開 PR の body を書く直前 / 公開 repo に検査や CI の workflow を足す・変える直前
---

# 公開の repo の作法

対象 = 公開 repo のどれでも、そこで公開される全文書 (README / docs 配下 / NOTICE / LICENSE / SECURITY / ROADMAP / commit message / PR title・body / 公開 `.github/`) と、その repo の検査。文中の docs は、書いている公開 repo の中の folder。

## 公開 docs を利用者視点で書く

Why: 書き手が自分用にメモった調子で公開 docs に書くと、利用者と contributor が読めない。「過去の苦労話」が表に出ると利用者は引く。

### 読者像

「その道具を install して使いたい初見の第三者」(操作者自身でも contributor でもない):

- 用語の前提知識ゼロ。段取りの番号・設計記録の番号・内部の記号は意味不明になる
- 「自分の機械で動かしたい」動線優先
- 「これは何ができる / どう使う / 詰まったらどこ見る」の 3 点で完結したい
- 内部実装 (画面の部品の分解・状態の置き場・競合の経緯・履歴の書き換えの経緯) は不要、「過去の苦労話」を表に出されると引く

### OK / NG

| トーン | OK / NG | 例 |
|---|---|---|
| **利用者向け** (表に出す) | OK | 「スマホで使える Claude Code のクライアント。macOS で `task setup` 1 発で起動」 |
| **contributor 向け** (docs/ 配下の限定 page のみ、README 表の外) | 限定 OK | 「新しいイベントの追加手順は `<repo>/docs/internals/` の拡張の page を参照」 |
| **書き手の作業メモ** | NG | 「段取り W2 の J-9 で状態を単一にまとめた、旧実装は J-12 で掃除」「設計記録の末尾の 2 件目」 |
| **過去の経緯 / 苦労話** | NG | 「監査で依存の脆弱性 17 件を発見、強制 upgrade で解消」 |
| **個人由来情報** (匿名性違反、禁止語の検査が別途止める) | NG | 操作者・エージェント・個人の account の名前 (禁止語の真値は番人の設定) |

### 構造で外すもの

- README の目次が「ディレクトリ構成」「開発フロー」を冒頭近くに出す = 利用者は `.githooks/` や `.tooling/` の中身を聞いていない、これらは末尾 section か `<repo>/docs/internals/` に隔離
- docs の索引の冒頭が「architecture」や「protocol」から始まる = 利用者は setup / ops を最初に見たい
- release note / changelog 風の経緯記述を README 本文に混ぜる = git log + GitHub Releases で代用
- 段取りの番号・設計記録の番号・内部の記号を README / docs 本文で参照 = 内部 implementation 文書からのみ参照可、利用者文書では撤去

### docs の構造 = 2 層物理分離

1. **利用者向け** (`<repo>/docs/` 直下 + `<repo>/docs/setup/` + `<repo>/docs/troubleshooting/` + `<repo>/docs/reference/`)
   - 「これは何 / どう使う / どう運用 / 設定 schema」のみ
   - 内部実装の話 (状態の置き場 / イベント / 拡張手順) は出さない
2. **contributor 向け** (`<repo>/docs/internals/`、別階層隔離)
   - architecture / protocol / extending / state-stores / data-schemas
   - 「読まないと PR 出せない」系のみ、「読まなくても install 動かせる」もの

利用者向け → contributor 向けへの link は OK、「これは contributor 向けです」明示。

### 書き手の自己抑制

- 公開 docs を書く時、まず「この 1 行は初見の利用者が読んで意味がわかるか」を 1 step 自問
- 段取りの番号・設計記録の番号・commit hash・修正経緯を書きそうになったら停止、内部 implementation docs に隔離 or 削除
- 「過去の苦労話」を表に出したい衝動 = 書き手が自分の労力をアピールする癖、利用者は興味なし、出さない
- README / docs の索引の冒頭は「利用者最短経路」で始める、contributor 向け section は末尾 or 別 page

## 公開 repo の検査の置き場 (local が真値、CI は鏡)

**検査の実体は local (repo の Taskfile と `.tooling/`、または repo の test の入口) が真値で、CI の workflow はその入口を呼ぶ薄い trigger だけにする**。その workflow は `ci.yml` とし、visibility ガードを付ける。

- Why: CI にしか無い検査を作った瞬間、offline で完結できなくなる。手元で緑なら CI も緑、の対応が崩れる
- 匿名性 / identity の scan はマシン常駐の番人 (guard-dispatcher) に任せる。CI は push の後で手遅れなので、local で止める
- 検査を伴わない機能 workflow (build / deploy / bot commit) は作らない
- `.github/` は ISSUE_TEMPLATE / PULL_REQUEST_TEMPLATE / SECURITY.md 等の markdown テンプレ用途で使う
- 新しい検査は local の入口へ足す。「CI で走らせよう」と考えた時点で、この決まりから外れている。repo ごとの入口と検査の一覧は、その repo の plugin の skill が持つ
