---
title: <project> プロジェクト
description: <project> プロジェクトが何を射程に持つか + この階層でだけ要る追加の読み物
updated: "{{YYYY-MM-DD}}"
capacity: 5KB
---

# <project> プロジェクト

> 新規プロジェクトはこの `_template-project/` を `cp -R` して `projects/<新名>/` を立て、 下記 5 section を埋める。 **folder 名がそのまま判定キーワード**なので、 置くだけで起動判定に編入される (= 親 `CLAUDE.md` は触らない)。

## このプロジェクトは何か

<射程を 1-3 文で書く>。

### 含む / 含まない
- 含む: <活動・対象>
- 含まない: <別プロジェクト送り>

## repo

<この階層に紐づく repo の path。 無ければ「無し」 と書く>

## 起動時の追加読み

起動時に踏む共通 6 点は親 `CLAUDE.md § Phase B-階層固有` が真値 (= ここには書かない)。 **この階層でだけ追加で要る読み物**があれば列挙する、 無ければ「無し」。

## エージェントの役割 / 挙動ルール (= 本プロジェクト時)

- <このプロジェクトでのポジション = 共同開発者 / 水先案内 / 代理実行 等>
- <このプロジェクトでだけ効く行動制約があれば書く。 全プロジェクト共通のものは親 `rules/always.md` が持つ>

## 関連 link

- 外部リポ / 参照先: <該当時>

---

## 新規立ち上げ checklist

`cp -R projects/_template-project/ projects/<新名>/` した後に埋める場所。 `bash .tooling/docs-check.sh` の **step 7 (= placeholder 残し)** が雛形由来の `{{...}}` / `<日本語含む 文>` を全部拾うので、 埋め忘れは FAIL で出る。

- [ ] **`_README.md`** の 5 section を埋める (= 射程 / 含む含まない / repo / 起動時の追加読み / 役割)
- [ ] **`vision.md`** の 2 節を埋める (= 今どこ / 到達点。 状態だけを書く)
- [ ] **`rules/always.md`** の `<プロジェクト名>` を実名に置換 (= 固有 rule が無い間も file は置いたまま)
- [ ] **`rules/lazy/_README.md`** の `<プロジェクト名>` を実名に置換 (= lazy 0 件でも索引は置く)
- [ ] **`subprojects/_README.md`** の `<project>` を実名に置換 + 「現在のサブプロジェクト」 を埋める (= 無ければ「なし」)
- [ ] **各 `*/_template.md`** (= 雛形そのもの) は**触らない** (= cp 元として残す、 placeholder 残しは想定内)
- [ ] `_README.md` が容量上限 (= 5KB、 大規模プロジェクトは 20KB まで) に収まるか確認
- [ ] サブプロジェクトを持つなら `subprojects/_template-subproject/` を `cp -R` して同じ手順を踏む
- [ ] `bash .tooling/docs-check.sh` で FAIL 0 を確認
