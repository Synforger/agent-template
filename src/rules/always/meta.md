---
title: メタ運用 (= 容量管理 + ルール改訂文化 + 継続的自己強化ループ)
description: エージェント配下 file の容量上限表 + 改訂運用ルール + 機械検出 detector 群と反応規律
updated: 2026-06-29
triggers: 常時 load
capacity: 11KB
---

# メタ運用

## ファイル容量管理

- **指標は バイト に統一** (= `wc -c` で測定)。 行数は使わない (= Markdown は 1 行に無限に詰め込めて行数が指標にならない)
- **上限超過時は同セッション内で圧縮完結**。 翌セッション持ち越し禁止
- **圧縮・削除はエージェント判断で実行**。 「開発に必要そう」 を判断軸に重要項目を抜粋して残す方針。 重要度判断つく項目は積極的に残す、 重要度低い / 1 回限り / 再現可能な情報は捨てる側に倒す
- 抽象化・統合・捨てる判断は各ファイルの `_README.md` に従う
- **`profile/profile-core.md` はセッション終了時 Step 1 で必ず圧縮を完遂** (= 持ち越し禁止)。 抽象化・統合・捨てる判断は `profile/_README.md` のルールに従う

### 容量上限一覧 (= 派生で調整、 ここは agent-template 出荷時 default)

| ファイル | 上限 | 備考 |
|---|---|---|
| `CLAUDE.md` | 16KB | 索引 + 人格 + Phase A/B/C 骨格 |
| `profile/profile-core.md` | 16KB | 常時 load = ユーザの核 + 判断軸 |
| `profile/profile-*.md` (lazy 群) | 3-6KB | lazy = シチュエーション別 (= 派生で定義) |
| `profile/_README.md` | 5KB | profile の書き方ルール本体 |
| `rules/always/meta.md` | 11KB | 常時 load: メタ運用 (本ファイル) |
| `rules/always/*-local.md` | 派生定義 | 派生固有の常時 load rule |
| `rules/lazy/automation-machinery.md` | 6KB | lazy: 自動化機構 + 文書庫運用 |
| `rules/lazy/rule-promotion-format.md` | 5KB | lazy: 横断昇格提案 書式 |
| `rules/lazy/_template.md` | 5KB | lazy 新規作成時の雛形 |
| `rules/lazy/*.md` (派生追加分) | 5KB (= 例外あり、 frontmatter `capacity:` 優先) | use 時 Read 群 |
| `rules/_README.md` | 5KB | rules フォルダ説明 |
| `{research,projects,todos,plans}/_README.md` | 5KB | |
| `projects/<project>/_README.md` | 20KB | プロジェクト判定キーワード + Phase B-プロジェクト固有 読み込み手順 |
| `projects/<project>/rules/_README.md` | 3KB | プロジェクト固有 rule の always / lazy 配置説明 |
| `projects/<project>/subprojects/_README.md` | 3KB | サブプロジェクト集約場所 + 動的切替の説明 |
| `projects/<project>/subprojects/<sub>/_README.md` | 8KB | サブプロジェクト判定キーワード + 起動時読込手順 |
| `journal/_README.md` | 5KB | 全階層共通定義 |
| `projects/<project>/journal/_README.md` | 3KB | プロジェクト journal 案内 |
| `projects/<project>/subprojects/<sub>/journal/_README.md` | 3KB | サブプロ独立 journal 案内 |
| `journal/.../YYYY-MM-DD/session-NN.md` | 無制限 | 履歴は残す |
| `projects/<project>/` 配下 | 無制限 | プロジェクト固有判断 |
| `research/<topic>.md` | 無制限 | 調査成果は育てる前提 |
| `todos/<task>.md` | 無制限 | タスク粒度に応じる |

各ファイルのフロントマターに `capacity:` で明示している場合はそちらを優先。

## ルール改訂文化

エージェント配下の rules / profile / CLAUDE.md は**気軽に見直す**。 完成形と扱わず、 セッション中の違和感・反復違反・効率悪さは**その場で打診 → 即合意 → 即 commit** のループで育てる。 セッション終了時に「あとでやっておきます」 で持ち越さない。

### 何を見直すか

- 反復違反 (= 2 回同じミス) → 3 回目を防ぐ仕組みを即書く
- 冗長 / 古い / 重複ルール → 削る (= 「念のため残す」 禁止、 使われないルールは認知負荷だけ増やす)
- 真値が 2 箇所以上 → 1 箇所に集約、 残りは「参照」 1 行に圧縮
- ユーザの反応で察した違和感 → 「もしかしてこのルールが原因では?」 と自発打診

### どう見直すか

- **自発打診**: ユーザ指摘待ちでなく、 「ここ古い」「重複」 と気づいた瞬間に提案
- **セッション内で完結**: 「終了時にまとめて」 禁止、 改訂は当該セッションで即 commit
- **容量上限緩和も打診 OK**: 必要なら「20KB → 25KB に上げませんか」 と提案、 即決
- **頻繁な改訂を恐れない**: rules ファイルが週単位で改訂される状態が健全、 **1 週間 (= 7-10 session) 触らないルール群は形骸化サイン**、 運用後に閾値再調整

### 改訂対象 file の役割

`CLAUDE.md` = 索引 + 人格 + Phase 骨格 / `rules/always/*` = 常時 load 横断 / `rules/lazy/*` = use 時参照 (= 文書庫) / `projects/<project>/rules/*` = プロジェクト固有 / `profile/profile-core.md` = ユーザプロファイル核 / `profile/profile-*.md` lazy = ユーザプロファイル詳細 (= シチュエーション別)

### 改訂運用

- 改訂は当該セッション内で即 commit、 終了時持ち越し禁止
- 改訂提案は自発で出す
- 改訂 commit は単独 PR / 単独 commit
- 容量上限緩和より圧縮優先
- 「セッション終了時にまとめてやります」 禁止

## 継続的自己強化ループ (= 機械検出 + 規律の併走)

改訂の品質は「逐次 grep で見に行く」 のでなく**機械検出で自動 sweep + 出力に反応のみ**で確保 (= context 食わない、 規律依存を最小化)。 新たな弱点パターンを発見したら detector を増強 (= 機構が自己拡張するループ)。

### 機械検出機構の担当範囲

| 検出対象 | 機構 | 発火タイミング |
|---|---|---|
| frontmatter 欠落 | docs-check step 1 | 起動時 + 終了時 |
| capacity 上限超過 (= frontmatter 自己宣言) | docs-check step 2 | 同上 |
| 索引整合崩壊 (= フォルダ内 .md 全列挙) | docs-check step 3 | 同上 |
| dead link (= 削除/rename 後の参照漏れ) | docs-check step 4 | 同上 |
| CLAUDE.md ↔ always 重複 | docs-check step 5 | 同上 |
| placeholder 残し (= 雛形 cp 後の埋め忘れ) | docs-check step 6 | 同上 |
| 動的検索パターン残骸 | docs-check step 7 | 同上 |
| プロジェクト folder 整合 | docs-check step 8 | 同上 |
| synced-paths (= base ↔ 派生 整合) | docs-check step 9 | 同上 |
| section 単位重複 (= LCS 比較) | detect-duplicates.py | 同上 |
| 7 日無更新 = 形骸化候補 | detect-stale-rules.sh | 同上 |

### 反応規律

- 起動時 `startup-status.sh` 出力に反応 (= 上記表のいずれかが hit したら処置)
- **FAIL ≥ 1 → 同 session 内 fix 必須** (= 持ち越し禁止)
- WARN 累積 5 件以上 or 同 file 3 件以上 → 自発で sweep 検討
- 終了時 Step 2 で再走、 残った FAIL は user 報告 + 翌 session 最優先

### detector 出力の判別運用

**dup_pairs 出力** (= detect-duplicates.py) は **真値分散** と **reference** をエージェント自身が判別:

- **真値分散** = 同じ説明文 / ルール本体が複数 file に書かれてる → **集約** (= 1 file を真値、 他は参照 1 行)
- **reference** = 同じ command / path / file 名が複数 file から legitimate に参照されてる → **残置 OK** (= 起動時即実行性 / 各 file の自己完結性のため意図的)

判別軸 = 「この共通部分は本体ルールか、 引用 reference か」。

**stale_rules 出力** (= detect-stale-rules.sh) は **永続原則** と **真の dead** を frontmatter `stable: true` + path pattern 除外で機械分離済 (= `_README.md` 全般 + `stable: true` 宣言 file は出力外)。 残った stale 候補は真の改訂対象として自走判断。

### 弱点パターン発見時の機構自己拡張運用

「過去 2 回同じパターンの違反を見た」「見落としやすい構造」 を見つけたら:

1. **機械検出可能性を評価**: grep / awk / python で機械化できるか
2. **可能なら `docs-check.sh` に step 追加** (= 番号拡張、 false positive 抑制パターン込みで)
3. **可能なら `detect-duplicates.py` / `detect-stale-rules.sh` の精度向上** (= 閾値調整等)
4. **機械化不能なら本 file の `## ルール改訂文化` に規律として追記**
5. **既存 step の形骸化** (= hit 常時 0 で 1 month+) なら**廃止 or 検出基準調整**

「detector 追加」 のハードルを意識的に下げる = 指摘を 2 回受けたら即 detector 化、 機械出力に反応するだけで品質維持。

## 関連 lazy 文書庫

- 自動化機構 (`.tooling/*` script / settings.json hook) の改修 → `rules/lazy/automation-machinery.md`
- 横断昇格提案 書式 → `rules/lazy/rule-promotion-format.md`
- 新 lazy file 追加時の設計原則 → `rules/lazy/automation-machinery.md` § 文書庫運用
