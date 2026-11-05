---
title: pages/ の運用 (= 全階層共通の真値)
description: 操作者に見せる説明のページとタブのメモの置き場。 何を入れるか / 構造 / 新しいタブの足し方 / git から外す物
updated: "2026-11-05"
capacity: 3KB
---

# pages/ の運用

> **全階層共通の真値**。 `projects/<P>/pages/` も `subprojects/<S>/pages/` も同じ運用で、 **下の階層に本 file の写しは置かない**。 説明のページの作り方 = `.claude/skills/explainer-pages/SKILL.md`。

## 何を入れる / 入れない

- **入れる**: 操作者が理解するための説明のページ (= HTML) と、 タブのメモ。 タブごとの folder に並べる
- **入れない**: 計画 / 調査そのもの (= それぞれ `plans/` `research/`)。 ページは調べた結果を見せる出力で、 真値は元の側に置く

## 構造

```
<階層>/pages/
├── index.html        階層のトップ (= タブの一覧。 読める名前はここに出す)
├── _template-tab/    タブのトップページの雛形 (= 本 file の隣。 下の階層には置かない)
└── <タブの id>/      タブごと (= id は入れ替えでも変わらない)
    ├── index.html    そのタブのトップページ (= 今の全体像と全部への入口)
    ├── memo.md       タブのメモ (= git から外す)
    ├── <枝>/         枝ごとの説明のページ (= skill の「中身の木」)
    └── data/ src/    図の元
```

- 階層はタブを起動した階層。 階層が無いタブは `normal` (= 親の階層)
- `memo.md` は client の 📋 が開く普通のメモ。 `.gitignore` が `pages/*/memo.md` を外す
- **説明のページと説明の資料はタブの folder にだけ置く**。 道具がほかの場所に書き出す物は、 タブの `index.html` に 1 行足して配線する (= タブのトップページが説明の全部への唯一の入口)

## 新しいタブ

1. タブの folder と `index.html` は client が作る (= タブの階層を記録した時に、 無ければ `_template-tab/index.html` を写し、 `{{title}}` をタブの題、 `{{tier}}` を階層で埋める。 在るページには触らない)。 `memo.md` は起動の script が置く
2. 説明のページを置いたら、 タブの `index.html` にそのページへの 1 行を足し、 `python3 -I .claude/skills/explainer-pages/scripts/install_toc.py <タブの folder>` で横の目次を入れ、 同じ folder の `check-tab-links.py` で抜けを 0 にする
3. タブが最初の説明のページを置いた時に、 階層のトップ `index.html` にそのタブへの 1 行を足す

## 残す

説明のページは全部残す (= 資料の元になる)。 古くなったページは、 タブの folder の `_archive/` に置いて今の物と分ける。 階層の `pages/` の下に置くのは生きているタブの folder だけで、 閉じたタブの片付け方は skill の「続けて保つ」にある。
