---
title: メタ運用 統合 rule (= 容量 / 改訂文化 / 検出機構、 形態 D 基底)
description: agent-template 出荷時の常時 load 単一 file (= 形態 D)。 派生は本 file に「§ git / § quality / § style / § forbidden 等」 の personal section を追記して統一運用
updated: 2026-07-03
capacity: 13KB
---

# メタ運用 統合 rule

形態 D: 全階層で `rules/always.md` 1 file 統合。 詳細は本 file の section、 シチュエーション別詳細は `rules/lazy/*.md` 参照。

出荷時は本 file = メタ section のみ。 派生は同 file に personal section (= git flow / style / sub-agent / forbidden 等) を追記して 1 file 統合運用、 各階層 (= project / subproject) も同構造。

---

## § meta

### 静的容量上限 (= 階層別合計)

派生で階層別合計上限を frontmatter `capacity:` の合計で管理する。 例:

| 階層 | 上限例 | 内訳例 |
|---|---|---|
| 派生親 | 40 KB | `CLAUDE.md` + `profile/<core>.md` + `rules/always.md` |
| プロジェクト固有 | 20 KB | `projects/<P>/_README.md` + `projects/<P>/rules/always.md` |
| サブプロ固有 | 10 KB | `projects/<P>/subprojects/<S>/_README.md` + 同 `rules/always.md` |

Why: 際限ない rule 増殖を物量で止める、 常時 load で全体把握できる量に固定。

### 動的読込 = 上限外

`ls` / journal / todos / messages / startup-status / lazy file の Read 等は上限に含めない。 監視 script (= `.tooling/startup-status.sh`) は frontmatter `capacity:` 宣言 file の静的合計のみ計算。

### 形態 D

```
<階層>/rules/always.md       ← 1 file 統合 (= 全 always section)
<階層>/rules/lazy/*.md       ← 個別維持 (= シチュエーション別 trigger)
```

Why: always = 1 file で構造美 + 容量管理が `wc -c` 1 発、 lazy = 個別 trigger 機能維持。

### 表現形式

- 基本ペア = 短文 1 行 + `Why: ...` 1 行、 必要時 `How: ...` 1 行
- 表は同種要素並列のみ、 3 列以内
- 散文は file 冒頭 1-2 行のみ

Why: rule のみ書くとエッジで誤判断、 Why 付くと判断軸取れる。

### 禁止表現

rule 本体に書かない:

- 過去失敗のラベル化 (= 「反復違反」「サボり」「いつもの」 等の自己卑下や反復事象への命名)
- 経緯付記 (= `(= 2026-06-30 確定)` / `(= PR #123 で...)`)
- 強調 3 連語 (= 「必須・例外なし・スキップ禁止」 → 「必須」)
- 弱表現 (= 「念のため」「一応」「場合があります」「かも」)
- `(= ...)` 補足の乱用 (= 名詞 1 単語の言い換え廃止)

Why: rule = 法律、 履歴は git log / journal が真値、 弱表現は判断ぶれる。

### 違反時動作

- 起動時 `.tooling/startup-status.sh` が階層別静的合計を計算 (= 派生で階層別上限を script 内 or 別 config で調整)
- 上限超過 = WARN 出力、 同 session 内で圧縮 (= 凝縮 / 統合 / 削除、 緩和は最終手段)
- 緩和 commit = `.tooling/precommit-conflict-check.sh § 容量緩和 reflex 警告` で soft fail

### ルール改訂文化

派生配下の rules / profile / CLAUDE.md は気軽に見直す。 完成形と扱わず、 session 中の違和感 / 効率悪さは即打診 → 即合意 → 即 commit のループで育てる。 「あとでまとめて」 持ち越し禁止。

- 違反 2 回観測 → 3 回目防ぐ仕組みを即書く
- 冗長 / 古い / 重複 rule → 削る (= 「念のため残す」 禁止)
- 真値が 2 箇所以上 → 1 箇所に集約、 残りは「参照」 1 行に圧縮
- ユーザの反応 / 表情で察した違和感 → エージェントから打診

- エージェント自発打診 (= ユーザ指摘待ちでなく、 気付いた瞬間に提案)
- session 内完結 (= 「終了時にまとめて」 禁止、 改訂は当該 session で即 commit)
- 頻繁な改訂を恐れない (= rules file が週単位で改訂される状態が健全、 1 週間触らない rule 群は形骸化サイン)

### 機械検出機構 (= LLM 不使用、 token ゼロ)

| 検出対象 | 機構 | 発火 |
|---|---|---|
| frontmatter 欠落 / capacity / 索引 / dead link / placeholder / 動的検索 / プロジェクト整合 / synced-paths | docs-check.sh (= 8 step) | 起動 + 終了 |
| section 単位重複 (= LCS) | detect-duplicates.py | 同上 |
| 7 日無更新 (= 形骸化) | detect-stale-rules.sh | 同上 |
| 静的容量階層別 | startup-status.sh | 起動 |
| 容量緩和 commit | precommit-conflict-check.sh | git pre-commit |

エージェント反応:
- 起動時 `startup-status.sh` 出力に反応 (= FAIL ≥ 1 → 同 session 内 fix 必須)
- WARN 累積 5 件以上 or 同 file 3 件以上 → 自発 sweep 検討
- 終了時 Step 2 で再走、 残 FAIL = ユーザ報告 + 翌 session 最優先

### 弱点パターン発見時の機構自己拡張

エージェント or ユーザが「過去 2 回同じパターン違反 / エージェント見落とし構造」 発見:

1. 機械検出可能性評価 (= grep / awk / python で機械化できるか)
2. 可能なら `docs-check.sh` step 追加 (= false positive 抑制パターン込)
3. 可能なら `detect-duplicates.py` / `detect-stale-rules.sh` 精度向上
4. 機械化不能なら本 file § meta § ルール改訂文化 に規律として追記
5. 既存 step の形骸化 (= hit 常時 0 で 1 month+) なら廃止 or 検出基準調整

「detector 追加」 ハードルを意識的に下げる = ユーザ指摘 2 回受けたら即 detector 化、 エージェントは機械出力に反応するだけで品質維持。

### detector 出力判別

**dup_pairs** = 真値分散 vs reference:
- 真値分散 = 同じ説明文 / ルール本体が複数 file → 集約 (= 1 file 真値、 他は参照 1 行)
- reference = 同じ command / path / file 名が複数 file から legitimate 参照 → 残置 OK (= 起動時即実行性 / 各 file 自己完結性のため意図的)

判別軸 = 「この共通部分は本体ルールか、 引用 reference か」。

**stale_rules** = 永続原則 vs 真の dead:
- frontmatter `stable: true` + path pattern (= `_README.md` 全般) 除外で機械分離済
- 残った stale 候補は真の改訂対象として自走判断

### 関連 lazy 文書庫

- 自動化機構 (= `.tooling/*` script / settings.json hook) 改修 → `rules/lazy/automation-machinery.md`
- 新 lazy file 追加時の設計原則 → 同上 § 文書庫運用

---

## 派生で追加する section (= 例、 personal rule)

派生エージェントは以下のような section を本 file 直下に追記して 1 file 運用:

- `## § git` = commit 規約 / branch flow / 匿名性 / merge 判断軸
- `## § quality` = build エラー扱い / test 網羅 / debug log 集約 / context rot 対策
- `## § style` = path 表記 / 出力簡潔 / 表現 / ツール呼び出し / ユーザ指示解釈
- `## § sub-agent` = Agent tool 起動方針 / prompt 構造 / エージェント責務
- `## § forbidden` = 第三者操作 / 破壊操作 / session 進行中断 / 規模理由の妥協

Why: personal rule を 1 file にまとめると `wc -c` で容量管理が単純、 § 見出しで section 検索性維持。 personal section が多すぎる場合のみ、 `rules/always-<section>.md` の形で分割可 (= その時は本 file からも参照 1 行を残す)。
