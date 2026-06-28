---
title: profile フォルダ
description: user プロファイル (= profile-core.md 常時 load + profile-* シチュエーション別 lazy 群) の書き方ルール
updated: 2026-06-28
capacity: 5KB
---

> 容量上限: 5KB (= `wc -c` で測定)。 超過時は重複削除で圧縮。

# profile/

エージェントが user との協働に使うユーザープロフィール置き場。 常時 load 1 file + lazy 5 file 構造 (= 2026-06-28 改定、 旧 profile-extended.md 15KB を 5 シチュエーション別 file に分裂):

- `profile-core.md` (= 常時 load、 15KB cap) — user の核 / 現職・スキル / 思考 / 思考の質 / 出力の質 / 操作・実行スタイル / 読み込みコスト
- `profile-technical-judgment.md` (= lazy、 3KB) — 技術選定 / ライブラリ判断時
- `profile-design-impl.md` (= lazy、 5KB) — 設計・実装作業時
- `profile-ui-ux.md` (= lazy、 3KB) — UI / UX 関連時
- `profile-destructive-ops.md` (= lazy、 2KB) — 破壊操作前
- `profile-docs.md` (= lazy、 6KB) — commit / 計画書 / docs 編集 / 完成判定 / 機材 spec 時
- `_template.md` — 新規プロファイル追加時の雛形

## 分裂設計の意図

旧 profile-extended.md (= 15KB) は「技術判断 + 設計実装 + UI + 破壊操作 + docs 運用」 を 1 file に積んでいた。 lazy として Read される時、 該当しない section も同時に流入。

分裂後は エージェント が**該当シチュエーションの file だけ Read** できる (= 例 = 設計実装作業中は `profile-design-impl.md` のみで OK、 docs 編集まで進んだら追加で `profile-docs.md`)。 各 file の `triggers:` がシチュエーションを自然言語で明示。

## profile-core / 各 profile-* lazy の書き方ルール (= 厳守)

全 profile file 共通の抽象化ルール。 容量上限はそれぞれ。

### 抽象化ルール

1. **個別事例を書かない**: 日付・セッション番号・コミットハッシュ・特定リポ名・特定機能名は禁止。 「2026-04-29 BA で〜」 のような書き方は NG
2. **「行動ルール」 で書く**: 「user は X を嫌う」 ではなく「X はしない」 (= エージェント の挙動指示として読める形に)
3. **1 項目 1〜2 行**: 補足・経緯・例示は禁止。 理由を 1 行で添えるのは可
4. **同種ルールは統合**: 似た指摘は 1 項目に圧縮する

### 取捨選択基準

**残す**:
- 反復している失敗パターン (= 2 回以上同じ指摘を受けたもの)
- user の核・思考様式・価値観
- エージェント の判断軸として常時参照するもの

**捨てる**:
- 1 度だけの事例 (= 再発したら復活させる)
- 特定プロジェクト・特定機能の固有判断
- セッション固有の経緯描写
- profile というより journal に書くべき出来事ログ

### core vs lazy 5 file の振り分け

- **core 行き**: 全 session で発動する判断軸、 エージェント 挙動の基本 (= 思考 / 出力 / 操作スタイル / 思考の質 / 読み込みコスト設計)
- **lazy 各 file 行き**: 特定シチュエーションで発動する判断軸 (= 技術選定 → technical-judgment / 設計実装 → design-impl / UI → ui-ux / 破壊操作 → destructive-ops / docs → docs)
- 迷ったら **lazy 側**に倒す (= 容量圧縮を優先)、 「全 session 必要か?」 を自問
- どの lazy file かも迷ったら trigger シチュエーションが一番具体的に書ける file 1 つに置く (= 複数 file への重複記述禁止)

### 特定プロジェクト固有のルールが出てきた場合

profile には書かない。 以下のどちらかに入れる:

- 該当プロジェクトの `projects/<mode>/_README.md`
- 該当箇所 (= プロジェクト配下のドキュメント・ルールファイル等)

profile はあくまで横断的な普遍ルールだけ持つ。

## ライフサイクル

- **読む**: セッション開始時に `profile-core.md` を全文読む (= 省略禁止)。 各 `profile-*` lazy file は `triggers:` 該当シチュエーション時に 自発 Read
- **追記**: セッション中に新しい一面・好み・癖が見えたらセッション終了時に 判断で追記 (= 事前確認不要)。 書く時は上記ルールで抽象化する。 core vs lazy 5 file のどこに置くかは エージェント が判断
- **圧縮**: `wc -c` で確認、 上限超過時は**セッション終了時に 判断で必ず圧縮・削除を完遂** (= user 承認不要、 翌セッション持ち越し禁止)。 重要度の判断がつかない項目は「捨てる」 側に倒す (= 再発したら復活させれば良い)。 抽象化・統合の判断は上記「書き方ルール」 に従う
