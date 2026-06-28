#!/usr/bin/env bash
# extract-artifact-index.sh - SessionEnd hook、 当 session で触った file/commit/PR を自動抽出 (= LLM 不使用)
# 用途: SessionEnd hook 経由で発火、 journal/<date>/session-NN-auto-index.jsonl に append
# 走らせ方: bash <agent-repo-root>/.tooling/extract-artifact-index.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 0

# session 開始時刻 = 当 transcript 1 行目以降の最初の timestamp、 fallback = 24h
# Claude Code の transcript dir 命名規約: $HOME/.claude/projects/-<root-path-with-slashes-as-dashes>
ROOT_SLUG=$(printf '%s' "$ROOT" | sed 's|/|-|g')
TRANSCRIPT_DIR="$HOME/.claude/projects/$ROOT_SLUG"
LATEST_TRANSCRIPT=$(ls -t "$TRANSCRIPT_DIR"/*.jsonl 2>/dev/null | head -1)
SINCE_ISO=""
session_uuid=""
if [ -n "$LATEST_TRANSCRIPT" ]; then
    session_uuid=$(basename "$LATEST_TRANSCRIPT" .jsonl)
    SINCE_ISO=$(python3 -c "
import json,sys
try:
    with open('$LATEST_TRANSCRIPT') as f:
        for line in f:
            d=json.loads(line)
            ts=d.get('timestamp')
            if ts:
                print(ts); break
except Exception: pass
" 2>/dev/null)
fi
SINCE_ARG="${SINCE_ISO:-24 hours ago}"

today=$(date '+%Y-%m-%d')
DATE_DIR="$ROOT/journal/$today"
mkdir -p "$DATE_DIR"
# 採番真値は .md のみ (= エージェント が書いた journal)。 jsonl は副産物 = 採番に使わない
# session_nn = .md の最大 NN + 1 (= 当日 エージェント が締めた session 数 + 1 = 今 session)
# 同 session 内で hook が複数回発火しても同 NN を上書きするので NN インフレしない
# file 名に uuid8 を入れない = NN だけで一意、 transcript 切替 (= compact/resume) に強い
max_nn=0
for f in "$DATE_DIR"/session-*.md; do
    [ -f "$f" ] || continue
    n=$(basename "$f" | sed -E 's/session-0*([0-9]+).*/\1/')
    [ "$n" -gt "$max_nn" ] && max_nn=$n
done
session_nn=$(printf "%02d" $((max_nn + 1)))
OUT_FILE="$DATE_DIR/session-${session_nn}-auto-index.jsonl"

# エージェント配下で触った file (= session 開始 ts 以降の commit のみ)
ark_files=$(git -C "$ROOT" log --since="$SINCE_ARG" --name-only --pretty=format: 2>/dev/null | sort -u | grep -v '^$' || true)

# 当 session の commit (= エージェント配下)
ark_commits=$(git -C "$ROOT" log --since="$SINCE_ARG" --format='%H %s' 2>/dev/null || true)

# 当日 関連 PR (= gh があれば)
gh_prs=""
if command -v gh >/dev/null 2>&1; then
    gh_prs=$(gh search prs --author=@me --created=">=$today" --limit 20 --json number,title,repository 2>/dev/null | python3 -c "
import json,sys
try:
    data=json.load(sys.stdin)
    for pr in data:
        repo=pr.get('repository',{}).get('nameWithOwner','?')
        print(f\"{repo}#{pr['number']} {pr['title']}\")
except Exception:
    pass
" 2>/dev/null || true)
fi

# JSONL 1 record、 上書き mode (= 同 session 再発火で重複根絶)
python3 - "$ark_files" "$ark_commits" "$gh_prs" "$today" "$session_nn" "$OUT_FILE" "$session_uuid" "$SINCE_ISO" <<'PYEOF'
import sys, json
from datetime import datetime
ark_files = [l for l in sys.argv[1].split("\n") if l.strip()]
ark_commits = [l for l in sys.argv[2].split("\n") if l.strip()]
gh_prs = [l for l in sys.argv[3].split("\n") if l.strip()]
date_str = sys.argv[4]
session_nn = sys.argv[5]
out_file = sys.argv[6]
session_uuid = sys.argv[7]
since_iso = sys.argv[8]

record = {
    "session": f"{date_str}-{session_nn}",
    "session_uuid": session_uuid,
    "session_start": since_iso or "(fallback: 24h)",
    "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
    "touched_files_ark": ark_files,
    "commits_ark": ark_commits,
    "prs_today": gh_prs,
}
with open(out_file, "w", encoding="utf-8") as f:
    f.write(json.dumps(record, ensure_ascii=False) + "\n")
print(f"wrote: {out_file}")
PYEOF
