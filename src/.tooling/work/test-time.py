#!/usr/bin/env python3
"""試験の時間が鳴っている時に、 縮める手を試したと書いて受け入れる命令 (= `accept`)。

打つのは、 hook `hooks/test_time_gate.py` が「いつもの時間を越えた」と鳴らした session の本人。 既定は縮める事で、
縮める手を試しても縮まらなかった時だけ、 試した手と、 何秒が何秒になったかを書いて受け入れる。
受け入れると、 鳴っている物のうち一番新しい 1 件の基準を最後の elapsed に上げ、 鳴りを消し、 `accepted.jsonl` に 1 行足す。
使い方: python3 .tooling/work/test-time.py accept --tried "<試した手>" --before <秒> --after <秒>
session は環境変数 `CLAUDE_CODE_SESSION_ID`。 無ければ、 鳴っている物を持つ一番新しい session に倒す。
試験 = tests/test-test-time-gate.sh
"""
import argparse
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

from test_time import baseline_key  # noqa: E402
from test_time_store import TestTimeStore, current_time  # noqa: E402


def accept(tried: str, before: float | None, after: float | None) -> int:
    """鳴っている 1 件を受け入れる。 試した手と before・after が揃わなければ断る。"""
    if not tried.strip() or before is None or after is None:
        print("断ります: --tried (試した手)・--before・--after の 3 つが要ります。 縮める手を試してから、 その手と秒数を書いてください。", file=sys.stderr)
        return 1
    store = TestTimeStore()
    session = os.environ.get("CLAUDE_CODE_SESSION_ID") or store.newest_ringing_session() or ""
    ring = store.pop_latest_ring(session) if session else None
    if ring is None:
        print("断ります: この session で鳴っている試験の時間がありません。", file=sys.stderr)
        return 1
    store.save_base(baseline_key(ring["repo"], ring["command"]), ring["elapsed"])
    written = store.append_accepted({
        "at": datetime.fromtimestamp(current_time(), timezone.utc).isoformat(), "session": session,
        "repo": ring["repo"], "command": ring["command"], "before": before, "after": after, "tried": tried.strip(),
    })
    left = len(store.ringing(session))
    print(f"受け入れました: {Path(ring['repo']).name} `{ring['command'][:80]}` 基準を {ring['elapsed']:.1f}秒 に上げました。"
          + ("" if written else " (記録の file には書けませんでした)")
          + (f" まだ鳴っている物が {left} 件あります。" if left else ""))
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    parser_accept = commands.add_parser("accept", help="鳴っている試験の時間を、 試した手を書いて受け入れる")
    parser_accept.add_argument("--tried", default="", help="縮めるために試した手")
    parser_accept.add_argument("--before", type=float, help="いつもの秒数")
    parser_accept.add_argument("--after", type=float, help="縮める手を試した後の秒数")
    args = parser.parse_args(argv)
    return accept(args.tried, args.before, args.after)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
