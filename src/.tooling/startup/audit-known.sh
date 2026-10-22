#!/usr/bin/env bash
# audit-known.sh - 番人の週次の監査の結果を起動の検査の行にする入口 (= startup-status.sh が `status` で呼ぶ)。
# 監査の記録の置き場を番人に訊き、 判定と出し方は audit_findings.py に渡す (= 中身はその file の頭書き)。
#
# 使い方:
#   audit-known.sh status    起動の検査の行 (= 置き場は ${AUDIT_LOG_DIR:-<guard_place audit-logs>})

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/guard-place.sh"

case "${1:-}" in
    status) exec python3 "$(dirname "${BASH_SOURCE[0]}")/audit_findings.py" "${AUDIT_LOG_DIR:-$(guard_place audit-logs)}" ;;
    *) echo "usage: audit-known.sh status" >&2; exit 2 ;;
esac
