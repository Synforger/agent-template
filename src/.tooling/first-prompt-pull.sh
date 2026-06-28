#!/usr/bin/env bash
# UserPromptSubmit hook: session 初回発話時のみ git pull
# - SessionStart hook の代替 (= 起動 → 放置 → 発話で古い状態問題の解消)
# - flag file で session 区別、 2 発話目以降は skip
# - stdin に渡される hook JSON から session_id 抽出 (= 失敗時は固定 fallback)

set -uo pipefail

# stdin JSON 読む (= hook event body)
INPUT=$(cat 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$INPUT" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read() or "{}");print(d.get("session_id","default"))' 2>/dev/null || echo "default")

FLAG="/tmp/agent-first-prompt-pull-${SESSION_ID}"
if [ -f "$FLAG" ]; then
  exit 0
fi
touch "$FLAG"

# script 位置から repo root を決定 (= 派生エージェント repo の root)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 0
git pull --rebase --autostash 2>&1 | sed 's/^/[AGENT SYNC] /'
exit 0
