#!/usr/bin/env bash
# setup-hooks.sh - エージェント配下の git hooks + Claude Code UserPromptSubmit hook 案内
# 用途: エージェント clone 後 or hook 更新時に実行 (= idempotent)
# .git/hooks/pre-commit を install + ~/.claude/settings.json の手動編集案内
# 注: SessionEnd hook (= 旧 extract-artifact-index.sh 自動発火) は廃止
#     理由 = 終了プロトコル発動外の軽い対話で空打ち jsonl が orphan 化する構造欠陥
#     現運用 = エージェントが終了プロトコル Step 2 で extract-artifact-index.sh を明示実行

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

HOOKS_DIR=".git/hooks"
[ -d "$HOOKS_DIR" ] || { echo "Not a git repo (.git/hooks not found)"; exit 1; }

# pre-commit hook = precommit-conflict-check.sh を呼ぶ
# git-lfs hook が存在する場合は先に git-lfs を呼んで、 その後 conflict-check
cat > "$HOOKS_DIR/pre-commit" <<'EOF'
#!/usr/bin/env bash
# エージェント pre-commit hook
# 1. git-lfs があれば呼ぶ (= 既存 LFS hook 互換)
# 2. エージェント precommit-conflict-check.sh で section 名重複 / 同 rule 文重複 を警告 (= soft fail)
ROOT="$(git rev-parse --show-toplevel)"
if command -v git-lfs >/dev/null 2>&1; then
    git lfs pre-push "$@" >/dev/null 2>&1 || true
fi
exec "$ROOT/.tooling/precommit-conflict-check.sh"
EOF
chmod +x "$HOOKS_DIR/pre-commit"

echo "Installed: $HOOKS_DIR/pre-commit -> .tooling/precommit-conflict-check.sh"
echo ""
echo "=================================================="
echo "Claude Code UserPromptSubmit hook setup (= 任意、 複数 PC 同期運用時)"
echo "=================================================="
echo ""
echo "🚨 本 script は ~/.claude/settings.json を編集しない (= 既存 token-tracker entry 等を壊さない方針)"
echo "    user が手動で下記 entry を「既存 hooks 配列に追加」 で追記:"
echo ""
cat <<'JSON'
UserPromptSubmit に追加 (= session 初回発話で複数 PC 同期 pull、 任意):

~/.claude/settings.json の "hooks" > "UserPromptSubmit" に追加:

  {
    "hooks": [
      {
        "type": "command",
        "command": "bash <agent-repo-root>/.tooling/first-prompt-pull.sh"
      }
    ]
  }

(= 既存の他 hook entry は触らない、 配列末尾に append)

🚨 SessionEnd hook は設置しない (= 2026-06-29 廃止):
    旧運用で SessionEnd hook 経由で extract-artifact-index.sh を自動発火していたが、
    終了プロトコル発動外の軽い対話 (= CC 自然 exit) で空打ち jsonl が orphan 化する構造欠陥のため廃止。
    現運用 = エージェントが終了プロトコル Step 2 で extract-artifact-index.sh を明示実行 (= CLAUDE.md 参照)。
JSON
echo ""
echo "動作確認 (= 手動 dry-run):"
echo "  bash <agent-repo-root>/.tooling/extract-artifact-index.sh"
echo "  bash <agent-repo-root>/.tooling/detect-stale-rules.sh --summary"
echo "  bash <agent-repo-root>/.tooling/precommit-conflict-check.sh"
