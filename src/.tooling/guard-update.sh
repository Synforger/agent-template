#!/usr/bin/env bash
# =============================================================================
# guard-update.sh — 番人をこの PC で最新にする (= 冪等、 何度流しても同じ)
# =============================================================================
#   bash <エージェントの repo>/.tooling/guard-update.sh
#
# 番人 (= guard-dispatcher) を直した後、 もう 1 台の PC で追いつく時、 起動時の点検が guard_deploy STALE を
# 出した時に流す。 session の中からでも流せる。
# 1. エージェントの repo を pull する
# 2. 番人の clone を develop に揃えて導入し直す (= bootstrap。 番人は clone から直接動くので clone は develop に留める。
#    手元に origin に無い commit / commit していない変更があれば止める。 作業中の変更は worktree で持つ)
# 3. Claude Code の設定を全 config dir へ配る (= その script を持つ派生だけ。 templates/claude-settings.json が真値)
# =============================================================================
set -uo pipefail

AGENT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 番人の clone は、 導入先 (= ~/.git-hooks の中の link) が指している folder
GUARD_CLONE="${GUARD_CLONE:-$(cd -P "$HOME/.git-hooks/scripts" 2>/dev/null && cd .. && pwd)}"
[ -n "${GUARD_CLONE}" ] || { echo "番人が導入されていません (= ~/.git-hooks/scripts が無い)。 番人の README の手順で導入してください"; exit 1; }
LOG="${TMPDIR:-/tmp}/guard-update.log"
: > "${LOG}"

echo "== 1/3 エージェントの repo を pull"
git -C "${AGENT}" pull -q --rebase --autostash || { echo "   pull が止まりました。 ${AGENT} の状態を確かめてください"; exit 1; }

echo "== 2/3 番人を develop に揃えて導入し直す"
git -C "${GUARD_CLONE}" fetch -q origin develop || exit 1
if [ -n "$(git -C "${GUARD_CLONE}" log --oneline origin/develop..develop 2>/dev/null)" ]; then
    echo "   手元の develop に origin に無い commit があります (= 消さずに止めます): git -C ${GUARD_CLONE} log origin/develop..develop"
    exit 1
fi
if [ -n "$(git -C "${GUARD_CLONE}" status --porcelain)" ]; then
    echo "   clone に commit していない変更があります (= 消さずに止めます): git -C ${GUARD_CLONE} status"
    exit 1
fi
git -C "${GUARD_CLONE}" checkout -q -B develop origin/develop || exit 1
if bash "${GUARD_CLONE}/scripts/bootstrap-machine.sh" >> "${LOG}" 2>&1; then
    echo "   導入しました ($(git -C "${GUARD_CLONE}" log -1 --format='%h %s'))"
else
    echo "   bootstrap が findings を出しました (= ${LOG} の末尾を見てください)"
fi

echo "== 3/3 Claude Code の設定を配る"
if [ -f "${AGENT}/.tooling/sync-claude-settings.sh" ]; then
    bash "${AGENT}/.tooling/sync-claude-settings.sh" --apply | tail -2
else
    echo "   (skipped, この repo は設定を配る script を持たない)"
fi
echo "== 終わりました"
