# agent-template

> Claude Code / Anthropic SDK で動かす**長期エージェントの雛形**。 機構 + 構造テンプレ + 改訂文化を 1 つの base に集約し、 各派生エージェントは base から `init-new-agent.sh` で派生 → 双方向 sync で進化を共有する。

## 設計思想

- **エージェントは「人格 + 固有プロジェクト + 機構」 で出来てる**。 機構部分を base に切り出し、 人格 + プロジェクトは派生に残す = 機構改善を全エージェントで共有
- **継続的自己強化ループ**: 機構の品質は機械検出 (`docs-check.sh` / `detect-duplicates.py` / `detect-stale-rules.sh`) で自動 sweep、 エージェントは出力に反応するだけ = context 浪費しない
- **OSS 公開前提**: 個人情報・社内情報の混入はマシン常駐の guard-dispatcher (= git hooks dispatcher) が commit / push 境界で機械防止
- **派生に縛りを最小化**: base が真値を持つのは「機構 + 必須 4 rule file + 構造テンプレ」 のみ、 残りは派生の自由領域

## リポジトリ構成

```
agent-template/
├── LICENSE                            # Apache 2.0
├── README.md                     # 本 file
├── .gitignore                         # template リポ自体の gitignore
├── .githooks/pre-commit               # branch guard (= anon scan は guard-dispatcher 委譲)
├── .tooling/local-ci/                 # template リポ自体の OSS 運用 lint
│   ├── docs-lint.sh
│   ├── docs-lint-ignore.txt
│   └── setup-lib.sh
├── .tooling/                          # template 運用 script
│   ├── init-new-agent.sh              # 派生立ち上げ
│   ├── sync-from-base.sh              # base → 派生 取り込み
│   └── promote-to-base.sh             # 派生 → base 昇格
├── .synced-paths.txt                  # 派生に降ろす path 列挙
└── src/                               # ★ 派生に降りる中身
    ├── CLAUDE.template.md             # 派生で CLAUDE.md として人格を書く
    ├── .gitignore.template            # 派生で .gitignore に展開
    ├── .tooling/                      # 機構 script (= 派生で動く真値)
    │   ├── docs-check.sh              # 多軸 docs 検査
    │   ├── detect-duplicates.py       # section 単位重複検出
    │   ├── detect-stale-rules.sh      # 7 日無更新検出
    │   ├── extract-artifact-index.sh  # SessionEnd hook 用
    │   ├── first-prompt-pull.sh       # 複数 PC 同期用 (任意)
    │   ├── precommit-conflict-check.sh
    │   ├── setup-hooks.sh             # hook install
    │   ├── startup-status.sh          # Phase B-共通 で実行
    │   └── _README.md
    ├── rules/
    │   ├── always/meta.md             # ★ 必須: 容量管理 + 改訂文化 + 自己強化ループ
    │   └── lazy/
    │       ├── _template.md           # 新 lazy 雛形
    │       ├── automation-machinery.md
    │       └── rule-promotion-format.md
    ├── projects/_template-project/    # プロジェクト雛形 (= 入れ子 subprojects 込み)
    ├── journal/                       # session log 構造
    ├── todos/                         # 横断タスク
    ├── plans/                         # 横断計画
    ├── research/                      # 横断調査
    └── profile/                       # ユーザプロファイル構造
        └── profile-core.template.md
```

`src/` 配下が「派生 agent の中身」、 root 配下は「template 自体の運用」。 `init-new-agent.sh` は `src/` を派生 root に rsync + `*.template` を実 file に展開する。

## 派生の立ち上げ

```bash
git clone git@github.com:synforger/agent-template.git
cd agent-template
./.tooling/init-new-agent.sh ~/path/to/<new-agent>
```

派生 dir で:

1. `CLAUDE.md` を編集 (= 人格 / ユーザ関係 / エージェント構成)
2. `profile/profile-core.md` を編集 (= ユーザの核 + 判断軸)
3. マシン側の guard-dispatcher word list (= `~/.config/anon-words/`) に固有語彙を追記
4. 派生固有の `rules/always/*-local.md` を追加 (= git 運用ルール / 禁止事項 等)
5. `git remote add origin <your-repo>` + initial push

## 双方向 sync 運用

### base → 派生 (= 下り)

派生で base 最新を取り込みたい時:

```bash
cd ~/path/to/<your-agent>
./.tooling/sync-from-base.sh
```

`.synced-paths.txt` に列挙された path のみ base 最新で上書き。 派生固有 file (= synced-paths 外) は触らない。 `git diff` で確認後 commit。

### 派生 → base (= 上り)

派生で発見した機構改善を base に昇格:

```bash
cd ~/path/to/<your-agent>
./.tooling/promote-to-base.sh "feat: 新 docs-check step 追加"
```

base 側に feature branch を切って push、 PR 経由で merge。 synced-paths 外の派生固有 file は弾かれる。

### 競合解決

- promote する前に**必ず先に sync-from-base.sh を実行** (= 競合を派生側で解決)
- 派生で base file を独自 override したい時の方針は派生側で決める (= 例: `<file>.local.md` で別名運用 / base への PR で改善提案 / `.synced-paths.txt` をローカル編集して除外)

## 必須 rule (= 派生で消さない)

agent-template が出荷する rule は以下のみ。 これ未満では機構が動かない。

- `rules/always.md § meta` — 容量管理 + 改訂文化 + 継続的自己強化ループ (= 形態 D、 1 file 統合)
- `rules/lazy/_template.md` — 新 lazy 作成雛形
- `rules/lazy/automation-machinery.md` — `.tooling/*` 運用真値

派生固有の rule (= git 運用 / 禁止事項 / sub-agent 起動規律 / その他) は派生で `rules/always/*-local.md` `rules/lazy/*-local.md` 等として自由に追加。 sync 対象外。

## 機構の中核

### `docs-check.sh`

セッション終了時に走らせ、 FAIL は同 session 内 fix 必須。 検査軸 (= 真値は script 自身の step 表示):

1. frontmatter
2. capacity (= file 自己宣言)
3. 索引整合 (= `_README.md` ↔ 同フォルダ .md)
4. dead link
5. placeholder 残し (= 雛形 cp 後の埋め忘れ)
6. 動的検索パターン残骸
7. プロジェクト folder 整合
8. synced-paths 整合 (= 派生のみ、 base と diff 検出)

### `detect-duplicates.py`

H2/H3 section 単位で全 rule の LCS 比較、 真値分散の集約候補を出力。 reference 判定済 (= 意図的な共通参照) のペアは `.tooling/duplicates-allowlist.txt` に登録して恒久 suppress (= 毎 session の再判定を消す)。

### `detect-stale-rules.sh`

7 日無更新 = 形骸化候補。 frontmatter `stable: true` + `_README.md` は機械除外、 真の dead 候補のみ報告。

### 自己拡張ループ

弱点パターンを 2 回観測したら即 detector 化:

1. 機械検出可能性を評価 (grep / awk / python)
2. 可能なら `docs-check.sh` に step 追加 / `detect-*` の精度向上
3. 機械化不能なら `rules/always/meta.md § ルール改訂文化` に規律として追記

「detector 追加」 のハードルを意識的に下げる = 機械出力に反応するだけで品質維持。

## 匿名性 (= OSS 公開向け)

base 側は具体的なエージェント名・運用者個人情報ゼロで出荷。 スキャンの実体はマシン常駐の guard-dispatcher (= 別リポ) が持ち、 commit / push 境界で全リポ強制される (= word list はマシン config `~/.config/anon-words/` に置き、 リポには commit しない)。

## ライセンス

[Apache License 2.0](./LICENSE)

## 関連

- [Synforger](https://github.com/synforger) — 本 template の出元 organization
- Claude Code (Anthropic) — このエージェント雛形が想定する harness
