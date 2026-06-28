---
title: <project> プロジェクト
description: 起動キーワード「<キーワード>」 で入る <project> プロジェクトの構造 + 起動時読込手順
updated: "{{YYYY-MM-DD}}"
capacity: 5KB
---

# <project> プロジェクト

> 新規プロジェクト追加時はこの `_template-project/` を `cp -R` して `projects/<新名>/` を立て、 下記 7 section を埋める。 CLAUDE.md は触らない (= プロジェクト判定は動的検索方式、 本フォルダを置くだけで編入)。

## 判定キーワード (= プロジェクト判定用、 最初の user 発話に部分一致でマッチ)

- `<キーワード1>`
- `<キーワード2>`

## このプロジェクトは何か

<射程を 1-3 文で書く>。

### 含む / 含まない
- 含む: <活動・対象>
- 含まない: <別プロジェクト送り>

## 起動時に読むもの (= 必須・Phase B-プロジェクト固有)

並列で一括実行 (= 共通規約は親 `<agent-repo-root>/CLAUDE.md` 参照、 ここは本プロジェクト固有のみ):

1. `rules/always/*.md` 全部 (= プロジェクト起動時必読 rule)
2. `journal/` の最新セッション (= 前回の続き把握)
3. <その他、 本プロジェクト固有に毎回必要な md / リポ ls / git status 等>

## 必要時に引いてくる (= 任意)

- `plans/` `research/` `todos/` 過去分 (= 該当作業時)
- `rules/lazy/` = PreToolUse hook が機械 inject (= 手動 lookup 不要)
- 外部参照: `REDACTED_PATH / `REDACTED_PATH 配下の関連リポ

## エージェント の役割 / 挙動ルール (= 本プロジェクト時)

- <そのプロジェクトでの エージェント のポジション = 共同開発者 / 水先案内 / 代理実行 等>
- <本プロジェクト固有の絶対ルール・行動制約があれば明記、 一般ルールは親 CLAUDE.md / always 参照>

## ライフサイクル

- 本プロジェクト固有の設計判断・調査・タスク・歴史は全部このフォルダ内に閉じる
- 完了は各 file の `status` で管理、 フォルダ自体はプロジェクトの「玄関」 として常設
- サブプロジェクトを持つ場合は `subprojects/` 配下、 journal は本プロジェクトの `journal/` に集約
- 不要になったプロジェクトの扱いは user と相談 (= 基本は履歴として残す)

## 関連 link

- 親プロジェクト: <subproject の場合のみ、 親 path>
- 外部リポ: <該当時>

---

## 新規立ち上げ checklist

`cp -R projects/_template-project/ projects/<新名>/` した後の埋めるべき場所と注意点。 `bash .tooling/docs-check.sh` の **step 7 (= placeholder 残し)** が雛形由来の `{{...}}` / `<日本語含む 文>` を全部検知するので、 埋め忘れあれば即 FAIL で気づける。

- [ ] **`_README.md`** の 7 section を埋める (= 判定キーワード / 射程 / 含む含まない / Phase B-プロジェクト固有 / エージェント の役割 / ライフサイクル / 関連 link)
- [ ] **`rules/_README.md`** の `<project>` プレースホルダを実プロジェクト名に置換 + 「現在の配置」 表を埋める (= 初期は空でも明示)
- [ ] **`subprojects/_README.md`** の `<project>` プレースホルダを実プロジェクト名に置換 + 「現在のサブプロジェクト」 を埋める (= 無ければ「なし」)
- [ ] 各 `<sub>/_README.md` (= `plans` / `research` / `todos`) の `{{プロジェクト名}}` `{{プロジェクト固有の射程説明}}` `{{YYYY-MM-DD}}` を埋める
- [ ] **`rules/lazy/_template.md`** と各 `*/_template.md` (= 雛形そのもの) は**触らない** (= cp 元として残す、 placeholder 残しは想定内)
- [ ] `_README.md` 容量上限 (= 5KB、 大規模プロジェクトは 20KB まで緩和可) を超えないか確認
- [ ] サブプロジェクトを持つ場合は `subprojects/_template-subproject/` から cp -R で配置 → 同様の placeholder 埋め (= `journal/_README.md` の `{{YYYY-MM-DD}}` 含む)
- [ ] `bash <agent-repo-root>/.tooling/docs-check.sh` で FAIL 0 確認
- [ ] CLAUDE.md は触らない (= プロジェクト判定は `_README.md` 冒頭の判定キーワード走査で動的編入される)
- [ ] **`rules/always/meta.md` 容量表に新 project 専用 file (= 18KB 超の大型 rule 等) があれば追記** (= 一般的な _README は既存表項目でカバー済)
