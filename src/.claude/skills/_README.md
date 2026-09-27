---
title: .claude/skills/ の運用 (= 全階層共通の真値)
description: 特定の作業中にだけ効く手順の置き場。 何を入れるか / 置き場と命名 / frontmatter / 足し方 / _archive の基準
updated: 2026-09-26
capacity: 3KB
---

# .claude/skills/ の運用

> **全階層共通の真値**。 `projects/<P>/.claude/skills/` も `subprojects/<S>/.claude/skills/` も同じ運用で、 **下の階層に本 file と雛形の写しは置かない**。 毎 session 効くルールは `rules/always.md` が持つ (= skill と混ぜない)。

## 何を入れる

- **特定の作業中にだけ効く手順** (= 置く層の判定 = `.claude/skills/rule-registry/SKILL.md § ルールを足す時の判定`)
- 1 skill = 1 場面。 本文は呼んだ時にだけ読まれる

## 置き場と載り方

- `<階層>/.claude/skills/<name>/SKILL.md`。 その階層でだけ効くものはその階層に置く
- 一覧 (= `description` + `when_to_use`) はハーネスが出す。 親は起動時から、 下の階層は**その階層の file を初めて読んだ時**から載り、 session の終わりまで残る (= サブプロを読むと親プロも載る)
- 起動手順の `_README.md` の Read で採用階層の分が載るので、 索引は持たない
- **gitignored な階層の skill はハーネスが探さない** (= `respectGitignore: false` + 再起動でも同じ、 2026-09-26 実測)。 その階層の `_README.md § 起動時の追加読み` に `python3 .tooling/lib/skill-listing.py --list <階層>` を置き、 出力を一覧の代わりに読む (= 欠けると docs-check step 10 が FAIL)

## 命名

- folder 名 = skill 名 (= kebab-case、 読者の語で)
- **`_` で始まる folder は作らない** (= `_template/SKILL.md` も skill として拾われる。 skills 直下の file と `_archive/` の中は拾われない、 2026-09-26 実測)

## frontmatter

- `title` / `description` (= 何の手順か 1 行) / `when_to_use` / `updated` / `capacity`
- **`when_to_use` は作業の場面で書く** (= 「〜する直前」「〜を始める時」。 特定の発話に依存させない)
- 一覧は毎 session 文脈に入る。 階層ごとの合計は `.tooling/check-static-capacity.sh` が別枠で数える

## 足す時

`.claude/skills/_template.md` を `<name>/SKILL.md` へコピーして埋める。 常時 load 側から場面の名前で触れておく (= 読まれない手順を作らない)。

## _archive

退役した skill は `.claude/skills/_archive/<name>.md` へ file として移す (= `git mv` + 理由 1 行。 一覧から外れ、 中身は残る)。 台帳の行は `retired: true` で残す。
