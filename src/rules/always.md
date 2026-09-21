---
title: メタ運用 統合 rule (= 容量 / 書き方 / 増やし方 / 検出機構、 形態 D 基底)
description: agent-template 出荷時の常時 load 単一 file (= 形態 D)。 派生は本 file に「§ git / § quality / § style / § forbidden 等」 の personal section を追記して統一運用
updated: 2026-09-21
capacity: 13KB
---

# メタ運用 統合 rule

形態 D: 全階層で `rules/always.md` 1 file 統合。 詳細は本 file の section、 シチュエーション別詳細は `rules/lazy/*.md` 参照。

出荷時は本 file = メタ section のみ。 派生は同 file に personal section (= git flow / style / forbidden 等) を追記して 1 file 統合運用、 各階層 (= project / subproject) も同構造。

---

## § meta

### 常時 load は読み切れる量に保つ

**常時 load される 1 file は 200 行未満に収める**。 超えた分は trigger を持つ `rules/lazy/` へ降ろす。

- Why: 長い file は context を食うだけでなく**守られる率そのものを下げる** (= 公式ガイドの推奨値。 原文 "Longer files consume more context and reduce adherence")
- How: 押し出す対象は**発火実績の下位から選ぶ** (= 行数が稼げる節から選ばない)。 降ろした先に同じことが書かれていないか先に確かめる

### 静的容量上限 (= 階層別合計)

派生で階層別合計上限を frontmatter `capacity:` の合計で管理する。 例:

| 階層 | 上限例 | 内訳例 |
|---|---|---|
| 派生親 | 40 KB | `CLAUDE.md` + `profile/profile.md` + `rules/always.md` |
| プロジェクト固有 | 20 KB | `projects/<P>/_README.md` + `projects/<P>/rules/always.md` |
| サブプロ固有 | 10 KB | `projects/<P>/subprojects/<S>/_README.md` + 同 `rules/always.md` |

Why: 際限ない rule 増殖を物量で止める、 常時 load で全体把握できる量に固定。

### 動的読込 = 上限外

`ls` / journal / plans / messages / startup-status / lazy file の Read 等は上限に含めない。 監視 script (= `.tooling/startup-status.sh`) は frontmatter `capacity:` 宣言 file の静的合計のみ計算。

### 形態 D

```
<階層>/rules/always.md       ← 1 file 統合 (= 全 always section)
<階層>/rules/lazy/*.md       ← 個別維持 (= シチュエーション別 trigger)
```

Why: always = 1 file で構造美 + 容量管理が `wc -c` 1 発、 lazy = 個別 trigger 機能維持。

### 書き方

- **やることで書く** (= 「X はするな」 でなく「Y をする」)。 対で意味を持つ列挙は肯定側を先に並べ、 具体は `(= ...)` に入れて残す
  - Why: 否定形の指示は肯定形より通りにくく、 長い禁止リストは読み飛ばされる側に回る
- 基本ペア = 短文 1 行 + `Why: ...` 1 行、 必要時 `How: ...` 1 行
- 表は同種要素並列のみ、 3 列以内
- 散文は file 冒頭 1-2 行のみ

rule 本体に書かないもの:

- 過去失敗のラベル化 (= 「反復違反」「サボり」「いつもの」 等の自己卑下や反復事象への命名)
- 経緯付記 (= `(= 2026-06-30 確定)` / `(= PR #123 で...)`) — 履歴の真値は git log と journal
- 強調 3 連語 (= 「必須・例外なし・スキップ禁止」 → 「必須」)
- 弱表現 (= 「念のため」「一応」「場合があります」「かも」)
- コードを読めば分かること (= 構造の概要説明、 lint が既に守っている style)

### 違反時動作

- 起動時 `.tooling/startup-status.sh` が階層別静的合計を計算 (= 派生で階層別上限を script 内 or 別 config で調整)
- 上限超過 = WARN 出力、 同 session 内で削る (= 凝縮 / 統合 / 削除、 上限の緩和は最終手段)
- 緩和 commit = `.tooling/precommit-conflict-check.sh § 容量緩和 reflex 警告` で soft fail

### ルールを増やす / 減らす

**増やすのはユーザが明示した時**。 エージェントが「要る」 と思ったものは journal に候補として書き残し、 2 回目に同じ場面へ来た時にユーザへ 1 行で出す。

- Why: 常時 load は物量で効きが落ちる。 増やす判断を自分に許すと、 守られない文が積み上がって全体の遵守率が下がる
- **機構で守れるものは機構へ**: 文章で 2 回守れなかったものは detector / hook / 生成へ移す (= 文章と機構の二重化はしない)
- **減らす方は自走でよい**: 冗長 / 古い / 重複は削る、 真値が 2 箇所以上なら 1 箇所へ集約して残りは参照 1 行に圧縮

### 機械検出機構 (= LLM 不使用、 token ゼロ)

| 検出対象 | 機構 | 発火 |
|---|---|---|
| frontmatter 欠落 / capacity / 索引 / dead link / placeholder / 動的検索 / プロジェクト整合 / synced-paths / journal 整合 / 階層インターフェース / 参照先の実在 / 発火記録の有無 / vision の形 | docs-check.sh (= 14 step) | 起動 + 終了 |
| code<->docs 乖離 (= pair 台帳 / アンカー生存、 rules 層スコープ) | staledocs (= 外部 CLI、 startup-status 経由) | 起動 + 終了 |
| section 単位重複 (= LCS、 雛形とその複製は構造で除外) | detect-duplicates.py | 同上 |
| 7 日無更新 (= 形骸化) | detect-stale-rules.sh | 同上 |
| 静的容量階層別 | startup-status.sh | 起動 |
| 容量緩和 commit | precommit-conflict-check.sh | git pre-commit |

エージェント反応:
- 起動時 `startup-status.sh` 出力に反応 (= FAIL ≥ 1 → 同 session 内 fix)
- WARN 累積 5 件以上 or 同 file 3 件以上 → 自発 sweep
- 終了時 Step 2 で再走、 残 FAIL = ユーザ報告 + 翌 session 最優先

### 発火記録 (= どの rule が効いたかを貯める)

session 終了時、 効いた / 違反した rule の ID を `journal/<date>/session-NN-rule-hits.jsonl` に 1 行ずつ書く。 書き漏らした session は docs-check step 13 が出す。

- ID の台帳は**階層ごとに 1 本** (= ID は階層内で一意かつ不変、 生成 = `.tooling/build-rule-registry.py`)
- 実績は 2 つに効く: 容量超過時に**どの節から押し出すか**、 そして**沈黙した rule の退役**
- 沈黙で退役を測れるのは trigger 待ちの層だけ (= 常時 load は「読まれた」 と「効いた」 が別物なので、 記録が無いことを死んだ証拠に使わない)

**記録の書式 / ID の引き方 / 押し出しと退役の判定 / どの階層に置くかは `rules/lazy/rule-registry.md` が真値**。 ルールを足す / 改訂する / 記録を書く直前に読む。

### 弱点パターン発見時の機構自己拡張

エージェント or ユーザが「過去 2 回同じパターン違反 / エージェント見落とし構造」 を見つけた時:

1. 機械検出可能性を評価する (= grep / awk / python で機械化できるか)
2. 可能なら `docs-check.sh` に step 追加 (= false positive 抑制パターン込)
3. 可能なら `detect-duplicates.py` / `detect-stale-rules.sh` の精度を上げる
4. 機械化できないものだけ本 file § meta に規律として足す (= 足す判断はユーザが持つ)
5. 既存 step が形骸化 (= hit 常時 0 で 1 month+) したら廃止 or 検出基準を調整

「detector 追加」 のハードルは意識して下げる = ユーザ指摘 2 回で detector 化、 エージェントは機械出力に反応するだけで品質が保てる形にする。

### detector 出力判別

**dup_pairs** = 真値分散 vs reference:
- 真値分散 = 同じ説明文 / ルール本体が複数 file → 集約 (= 1 file 真値、 他は参照 1 行)
- reference = 同じ command / path / file 名が複数 file から legitimate 参照 → 残置 (= 起動時即実行性 / 各 file 自己完結性のための意図的重複)

判別軸 = 「この共通部分は本体ルールか、 引用 reference か」。

**stale_rules** = 永続原則 vs 真の dead:
- frontmatter `stable: true` + path pattern (= `_README.md` 全般) 除外で機械分離済
- 残った stale 候補は真の改訂対象として自走判断

### 関連 lazy 文書庫

- 自動化機構 (= `.tooling/*` script / settings.json hook) 改修 → `rules/lazy/automation-machinery.md`
- 新 lazy file 追加時の設計原則 → 同上 § 文書庫運用
- 複数プロジェクト共通の反復を横断 rule へ上げる書式 → `rules/lazy/rule-promotion-format.md`
- ルール台帳 / 発火記録 / 配置と退役の判定 → `rules/lazy/rule-registry.md`

---

## 派生で追加する section (= 例、 personal rule)

派生エージェントは以下のような section を本 file 直下に追記して 1 file 運用:

- `## § git` = commit 規約 / branch flow / 匿名性 / merge 判断軸
- `## § quality` = build エラー扱い / test 網羅 / debug log 集約 / context rot 対策
- `## § style` = path 表記 / 出力簡潔 / 表現 / ツール呼び出し / ユーザ指示解釈
- `## § sub-agent` = Agent tool 起動方針 / prompt 構造 / エージェント責務
- `## § forbidden` = 第三者操作 / 破壊操作 / session 進行中断 / 規模理由の妥協 / 明示 GO まで読み取り専用 (= `go-gate-reminder.sh` hook と対で運用)

Why: personal rule を 1 file にまとめると `wc -c` で容量管理が単純、 § 見出しで section 検索性維持。 200 行に収まらなくなったら、 発火実績の下位から `rules/lazy/` へ降ろす (= `rules/always-<section>.md` への分割は、 降ろし先が無い時だけ)。
