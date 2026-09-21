#!/bin/bash
set -euo pipefail

# =============================================================================
# init-new-agent.sh
# -----------------------------------------------------------------------------
# agent-template から派生エージェント repo を新規立ち上げる。
#
# Usage:
#   ./.tooling/init-new-agent.sh <agent-dir>
#
# 引数:
#   agent-dir : 派生先の absolute path (= 例 ~/path/to/your-agent)
#
# 動作:
#   1. agent-dir が既存なら error (= --force で上書き)
#   2. base の src/ 配下を agent-dir 直下に rsync (= 派生の中身が一気に展開)
#   3. base の運用 file (LICENSE / .githooks/pre-commit / .synced-paths.txt) を
#      agent-dir にも同梱
#   4. base の sync-from-base.sh / promote-to-base.sh を派生 .tooling/ に配置
#   5. *.template 拡張子を実 file に rename (= CLAUDE.template.md → CLAUDE.md 等)
#   6. agent-dir で git init -b main + initial commit
#
# 完了後:
#   派生 dir で CLAUDE.md / profile/profile.md / rules/always.md の personal section
#   を書いていく。
# =============================================================================

FORCE=0
if [ "${1:-}" = "--force" ]; then
    FORCE=1
    shift
fi

AGENT_DIR="${1:-}"
if [ -z "$AGENT_DIR" ]; then
    echo "Usage: $0 [--force] <agent-dir>" >&2
    exit 2
fi

# tilde 展開
AGENT_DIR="${AGENT_DIR/#\~/$HOME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -e "$AGENT_DIR" ] && [ "$FORCE" -eq 0 ]; then
    echo "error: $AGENT_DIR already exists (use --force to overwrite)" >&2
    exit 1
fi

mkdir -p "$AGENT_DIR"

echo "==> rsync src/ to $AGENT_DIR"
rsync -a --exclude='.gitkeep' "$BASE_DIR/src/" "$AGENT_DIR/"

# .gitkeep は dir 構造保持のため別途コピー (rsync --exclude 後)
( cd "$BASE_DIR/src" && find . -name '.gitkeep' -exec rsync -R {} "$AGENT_DIR/" \; )

echo "==> copy operational files (LICENSE / .githooks / .synced-paths.txt)"
cp "$BASE_DIR/LICENSE" "$AGENT_DIR/LICENSE"
cp "$BASE_DIR/.synced-paths.txt" "$AGENT_DIR/.synced-paths.txt"
mkdir -p "$AGENT_DIR/.githooks"
cp "$BASE_DIR/.githooks/pre-commit" "$AGENT_DIR/.githooks/pre-commit"
chmod +x "$AGENT_DIR/.githooks/pre-commit"
# 禁止語彙の scan は派生 repo に配らない (= マシン常駐の guard-dispatcher が
# 全 repo の commit / push 境界で回す、 word list はマシン config 側)

echo "==> install sync-from-base / promote-to-base scripts"
cp "$BASE_DIR/.tooling/sync-from-base.sh" "$AGENT_DIR/.tooling/sync-from-base.sh"
cp "$BASE_DIR/.tooling/promote-to-base.sh" "$AGENT_DIR/.tooling/promote-to-base.sh"
chmod +x "$AGENT_DIR/.tooling/sync-from-base.sh"
chmod +x "$AGENT_DIR/.tooling/promote-to-base.sh"

echo "==> expand *.template files"
# .gitignore.template → .gitignore
if [ -f "$AGENT_DIR/.gitignore.template" ]; then
    mv "$AGENT_DIR/.gitignore.template" "$AGENT_DIR/.gitignore"
fi
# CLAUDE.template.md → CLAUDE.md
if [ -f "$AGENT_DIR/CLAUDE.template.md" ]; then
    mv "$AGENT_DIR/CLAUDE.template.md" "$AGENT_DIR/CLAUDE.md"
fi
# vision.template.md → vision.md
if [ -f "$AGENT_DIR/vision.template.md" ]; then
    mv "$AGENT_DIR/vision.template.md" "$AGENT_DIR/vision.md"
fi
# profile/profile.template.md → profile/profile.md
if [ -f "$AGENT_DIR/profile/profile.template.md" ]; then
    mv "$AGENT_DIR/profile/profile.template.md" "$AGENT_DIR/profile/profile.md"
fi

# 展開した実 file の日付 placeholder だけ埋める (= 機械が確実に書ける 1 箇所を
# 人の宿題に回さない。 雛形 dir 配下の `{{YYYY-MM-DD}}` は雛形のまま残す)
TODAY="$(date +%F)"
for _f in CLAUDE.md vision.md profile/profile.md; do
    [ -f "$AGENT_DIR/$_f" ] && sed -i '' "s/{{YYYY-MM-DD}}/${TODAY}/g" "$AGENT_DIR/$_f"
done

# pc-labels.example.txt は派生に降ろさない (= 各派生で必要なら手動 cp)
if [ -f "$AGENT_DIR/.tooling/pc-labels.example.txt" ]; then
    : # 残置: 派生先で cp pc-labels.example.txt pc-labels.txt して書く
fi

echo "==> git init + initial commit"
cd "$AGENT_DIR"
if [ ! -d .git ]; then
    git init -b main
fi
# core.hooksPath は local に設定しない (= git は hooksPath を 1 つしか見ないので、
# local 上書きはマシン常駐の guard-dispatcher を丸ごと無効化する。 dispatcher が
# repo の .githooks/ へ委譲するため、 branch guard は設定なしでも効く)
git add -A
if git diff --cached --quiet; then
    echo "(no files to commit)"
else
    # bootstrap commit だけは hook を通さない (= pre-commit の branch guard が main を
    # 弾くので、 そのまま通すと派生は commit 0 本のまま「初期化成功」と表示される)
    git -c core.hooksPath=.git/hooks-disabled commit -m "chore: bootstrap from agent-template" -q
fi

echo ""
echo "✓ Agent initialized at: $AGENT_DIR"
echo ""
echo "Next steps in $AGENT_DIR:"
echo "  1. Edit CLAUDE.md (persona / boot protocol)"
echo "  2. Edit profile/profile.md (the profile of your primary user, one file)"
echo "  3. Add your word list to the machine config (~/.config/anon-words/, via guard-dispatcher)"
echo "  4. Add agent-specific rules to rules/always.md (single-file form)"
echo "  5. (optional) cp .tooling/pc-labels.example.txt .tooling/pc-labels.txt and edit"
echo "  6. Add remote: git remote add origin <your-repo-url>"
