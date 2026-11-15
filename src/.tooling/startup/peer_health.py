#!/usr/bin/env python3
"""別の機械に繋がっているかを、 client の見張りの記録から起動の検査の行にする。

`startup-status.sh` が起動のたびに呼ぶ (= 起動の検査の `step_peer_health`)。 行の持ち主は機械を持つ normal で、
`owner_routing.py` がほかの階層のタブには `others:` の 1 行にまとめる。

client は設定の `agent_message_peers` の機械を 5 分ごとに見張り、 機械ごとの記録を data の `peer_health.json` に書く。
記録は `{ok, since, checked_at, last_error, tailnet: {online, last_seen}}` で、 `since` は今の状態 (= 答える / 答えない)
になった時刻。 届けられなかった連絡は data の `peer_outbox/<id>.json` に `{peer, kept_at, …}` で置かれ、 相手が戻ると
送り直される。 在処と形の真値は client の `backend/_common/paths.py` と `backend/peers/`。 この段は読むだけで、 叩かない。

出す行 (機械ごと。 見張りの記録が無い機械では何も出さない):
  peer(<名前>): ok
  peer(<名前>): DOWN <N>h <M>m (since <時刻>; <理由>; <K> message(s) waiting)   30 分以上答えていない
  peer(<名前>): WAITING <K> message(s) (not answering for <M>m; <理由>)            30 分より短いが、 置かれた連絡が在る
  peer(<名前>): UNKNOWN (last checked <M>m ago; the client's patrol may be stopped)  見張りの記録が古い

走らせ方:
  python3 .tooling/startup/peer_health.py
  (`PEER_HEALTH_FILE` と `PEER_OUTBOX_DIR` で記録の在処を、 `PEER_HEALTH_NOW` (ISO 8601) で今の時刻を差し替えられる)
"""
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

PLATFORM_ROOT = Path(os.environ.get("AGENT_PLATFORM_ROOT") or Path.home() / "agent-platform")
DATA_DIR = PLATFORM_ROOT / "state/claude-pwa-client/data"
HEALTH_FILE = Path(os.environ.get("PEER_HEALTH_FILE") or DATA_DIR / "peer_health.json")
OUTBOX_DIR = Path(os.environ.get("PEER_OUTBOX_DIR") or DATA_DIR / "peer_outbox")

# client の見張りの間隔 (= backend/peers/peer_patrol.py の CHECK_INTERVAL_SEC)
PATROL_INTERVAL_SEC = 300
# 眠り・持ち運びの短い切断で鳴らさないため、 見張り 6 回分続けて答えない時に DOWN とする
DOWN_AFTER_SEC = PATROL_INTERVAL_SEC * 6
# 見張り 3 回分記録が更新されていなければ、 見張りそのものが止まっていると見る
STALE_AFTER_SEC = PATROL_INTERVAL_SEC * 3
MINUTE_SEC = 60
HOUR_SEC = 3600


def parse_time(text: object) -> datetime | None:
    """ISO 8601 の時刻 (= 時差つき)。 読めない時は None。"""
    if not isinstance(text, str):
        return None
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        return None
    return moment if moment.tzinfo else None


def span(seconds: float) -> str:
    """経過の長さを `<N>h <M>m` か `<M>m` で。"""
    whole = max(0, int(seconds))
    hours, minutes = whole // HOUR_SEC, (whole % HOUR_SEC) // MINUTE_SEC
    return f"{hours}h {minutes}m" if hours else f"{minutes}m"


def reason(record: dict) -> str:
    """答えない理由の見え方 (= tailnet から消えたか、 居るのに答えないか)。"""
    online = (record.get("tailnet") or {}).get("online")
    if online is False:
        return "off the tailnet (asleep or no power)"
    if online is True:
        return "on the tailnet but not answering"
    return "tailnet state unknown"


def peer_line(name: str, record: dict, waiting_count: int, now: datetime) -> str:
    """機械 1 台の行。"""
    checked = parse_time(record.get("checked_at"))
    if checked is None or (now - checked).total_seconds() >= STALE_AFTER_SEC:
        ago = f"{span((now - checked).total_seconds())} ago" if checked else "at an unknown time"
        return f"peer({name}): UNKNOWN (last checked {ago}; the client's patrol may be stopped)"
    if record.get("ok") is True:
        return f"peer({name}): ok" if not waiting_count else f"peer({name}): WAITING {waiting_count} message(s) (answering now; the client sends them)"
    since = parse_time(record.get("since"))
    down_for = (now - since).total_seconds() if since else 0.0
    if since and down_for >= DOWN_AFTER_SEC:
        local = since.astimezone().strftime("%Y-%m-%d %H:%M")
        return (f"peer({name}): DOWN {span(down_for)} (since {local}; {reason(record)}; "
                f"{waiting_count} message(s) waiting)")
    if waiting_count:
        return f"peer({name}): WAITING {waiting_count} message(s) (not answering for {span(down_for)}; {reason(record)})"
    return f"peer({name}): ok"


def load_records() -> dict[str, dict]:
    """機械の名前 → 見張りの記録。 file が無い・読めない時は空。"""
    try:
        records = json.loads(HEALTH_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(records, dict):
        return {}
    return {name: record for name, record in records.items() if isinstance(record, dict)}


def waiting_counts() -> dict[str, int]:
    """機械の名前 → 届けられずに置かれている連絡の数。"""
    counts: dict[str, int] = {}
    for path in sorted(OUTBOX_DIR.glob("*.json")) if OUTBOX_DIR.is_dir() else []:
        try:
            peer = json.loads(path.read_text(encoding="utf-8")).get("peer")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(peer, str):
            counts[peer] = counts.get(peer, 0) + 1
    return counts


def now_time() -> datetime:
    """今の時刻 (= 試験は `PEER_HEALTH_NOW` で差し替える)。"""
    return parse_time(os.environ.get("PEER_HEALTH_NOW")) or datetime.now(timezone.utc)


def main() -> int:
    records = load_records()
    counts = waiting_counts()
    now = now_time()
    for name in sorted(set(records) | set(counts)):
        print(peer_line(name, records.get(name, {}), counts.get(name, 0), now))
    return 0


if __name__ == "__main__":
    sys.exit(main())
