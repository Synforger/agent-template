#!/usr/bin/env python3
"""試験の時間の状態の読み書き (= この機械だけの物。 git には載せない)。

呼ぶのは `hooks/test_time_gate.py`・`work/test-time.py`・`session-end/session-end-precheck.py`。
置き場は `$AGENT_PLATFORM_ROOT/state/test-times/` (無ければ `~/.local/state/agent-test-times/`)。
中身は 基準 (`baselines.json`)・流している最中の記録 (`running/<tool-use-id>.json`)・鳴っている物 (`ringing/<session>.json`)・
受け入れの記録 (`accepted.jsonl`)。 読めない・書けない時は、 何も無かった事にして通す (= fail-open)。
判定は `test_time.py`。 試験 = tests/test-test-time-gate.sh
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

GIT_TIMEOUT_SECONDS = 5
OUTPUT_TAIL_BYTES = 4 * 1024 * 1024
TRANSCRIPT_TAIL_BYTES = 8 * 1024 * 1024
UNSAFE_NAME = re.compile(r"[^A-Za-z0-9_.-]")


def default_directory() -> Path:
    """状態の置き場。 `AGENT_PLATFORM_ROOT` が在ればその下の `state/test-times/`、 無ければ `~/.local/state/agent-test-times/`。"""
    root = os.environ.get("AGENT_PLATFORM_ROOT")
    if root:
        return Path(root) / "state" / "test-times"
    return Path.home() / ".local" / "state" / "agent-test-times"


def current_time() -> float:
    """今の時刻 (秒)。 試験は `TEST_TIME_NOW` で差し替える。"""
    override = os.environ.get("TEST_TIME_NOW")
    try:
        return float(override) if override else time.time()
    except ValueError:
        return time.time()


def repo_root(folder: Path) -> str | None:
    """folder を含む git の repo の根 (= git の外なら None)。"""
    try:
        done = subprocess.run(
            ["git", "-C", str(folder), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=GIT_TIMEOUT_SECONDS, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout.strip() if done.returncode == 0 and done.stdout.strip() else None


def read_tail(path: str, limit_bytes: int) -> str:
    """file の末尾 limit_bytes (= 読めなければ空)。 途中から読んだ時の最初の行は切れているので落とす。"""
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            start = max(0, handle.tell() - limit_bytes)
            handle.seek(start)
            text = handle.read().decode("utf-8", errors="replace")
            return text.split("\n", 1)[1] if start and "\n" in text else text
    except OSError:
        return ""


def _safe_name(name: str) -> str:
    return UNSAFE_NAME.sub("_", name)[:120] or "_"


class TestTimeStore:
    """試験の時間の状態の置き場 1 つ。 `directory` を渡さなければ既定の置き場。"""

    __test__ = False

    def __init__(self, directory: Path | None = None) -> None:
        self.directory = directory if directory is not None else default_directory()

    # ---- 基準 -------------------------------------------------------------------------------

    def load_base(self, key: str) -> float | None:
        """鍵の基準の秒数 (= 無い・読めない時は None)。"""
        value = self._bases().get(key)
        return float(value) if isinstance(value, (int, float)) else None

    def save_base(self, key: str, seconds: float) -> None:
        """鍵の基準を書く (= 書けなければ黙って捨てる)。"""
        with self._locked():
            bases = self._bases()
            bases[key] = seconds
            self._write_json(self.directory / "baselines.json", bases)

    # ---- 流している最中の記録 -----------------------------------------------------------------

    def start(self, tool_use_id: str, record: dict) -> None:
        """試験の始まりを記録する。"""
        self._write_json(self._running_path(tool_use_id), record)

    def finish(self, tool_use_id: str) -> dict | None:
        """同じ id の記録を取り出して消す (= 無ければ None)。"""
        path = self._running_path(tool_use_id)
        with self._locked():
            record = self._read_json(path, None)
            try:
                path.unlink()
            except OSError:
                return None
        return record if isinstance(record, dict) else None

    def running_background(self) -> list[dict]:
        """終わっていない background の記録 (= 全 session の分。 会話の記録の在処を持つ物だけ)。"""
        records = [self._read_json(path, None) for path in sorted((self.directory / "running").glob("*.json"))]
        return [record for record in records if isinstance(record, dict) and record.get("background") and record.get("transcript_path")]

    def running_elsewhere(self, repo: str, session: str, now: float, window_seconds: float) -> list[dict]:
        """repo で、 session 以外の、 始まりから window_seconds 以内の終わっていない記録。 窓を越えた記録は捨てる。"""
        found: list[dict] = []
        for path in sorted((self.directory / "running").glob("*.json")):
            record = self._read_json(path, None)
            if not isinstance(record, dict) or not isinstance(record.get("started_at"), (int, float)):
                continue
            if now - record["started_at"] > window_seconds:
                try:
                    path.unlink()
                except OSError:
                    pass
                continue
            if record.get("repo") == repo and record.get("session") != session:
                found.append(record)
        return found

    # ---- 鳴っている物 -----------------------------------------------------------------------

    def ringing(self, session: str) -> list[dict]:
        """session で鳴っている物 (= 鳴った順。 無ければ空)。"""
        rings = self._read_json(self._ringing_path(session), [])
        return [ring for ring in rings if isinstance(ring, dict)] if isinstance(rings, list) else []

    def add_ring(self, session: str, ring: dict) -> None:
        """鳴りを足す。 同じ鍵の鳴りは置き換える。"""
        with self._locked():
            rings = [other for other in self.ringing(session) if other.get("key") != ring.get("key")]
            self._write_json(self._ringing_path(session), [*rings, ring])

    def clear_ring(self, session: str, key: str) -> bool:
        """同じ鍵の鳴りを消す。 消えたら真。"""
        with self._locked():
            rings = self.ringing(session)
            left = [ring for ring in rings if ring.get("key") != key]
            if len(left) == len(rings):
                return False
            self._save_rings(session, left)
            return True

    def pop_latest_ring(self, session: str) -> dict | None:
        """session で一番新しく鳴った 1 件を消して返す (= 無ければ None)。"""
        with self._locked():
            rings = self.ringing(session)
            if not rings:
                return None
            self._save_rings(session, rings[:-1])
            return rings[-1]

    def newest_ringing_session(self) -> str | None:
        """鳴っている物を持つ session のうち、 一番新しく書かれた物 (= session を知らない受け入れの時だけ使う)。"""
        paths = [path for path in (self.directory / "ringing").glob("*.json") if self._read_json(path, [])]
        if not paths:
            return None
        return max(paths, key=lambda path: path.stat().st_mtime).stem

    # ---- 受け入れの記録 -----------------------------------------------------------------------

    def append_accepted(self, row: dict) -> bool:
        """`accepted.jsonl` に 1 行足す。 書けたら真。"""
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
            with open(self.directory / "accepted.jsonl", "a", encoding="utf-8") as handle:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
            return True
        except OSError:
            return False

    def accepted_since(self, since: datetime) -> list[dict]:
        """since 以後の受け入れの行 (= 古い順。 読めなければ空)。"""
        rows: list[dict] = []
        try:
            lines = (self.directory / "accepted.jsonl").read_text(encoding="utf-8").splitlines()
        except OSError:
            return rows
        for line in lines:
            try:
                row = json.loads(line)
                at = datetime.fromisoformat(row["at"])
            except (ValueError, KeyError, TypeError):
                continue
            if at.tzinfo is None:
                at = at.replace(tzinfo=timezone.utc)
            if at >= since:
                rows.append(row)
        return rows

    # ---- 中の物 -----------------------------------------------------------------------------

    @contextmanager
    def _locked(self) -> Iterator[None]:
        """機械の中の全 session の hook が、 読む → 足す → 書くを 1 本ずつ通す (= 後に書いた方が先の行を消さない)。
        lock の file を開けない時は lock なしで通す (= fail-open)。"""
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
            handle = open(self.directory / ".lock", "a")
        except OSError:
            yield
            return
        with handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            yield

    def _bases(self) -> dict:
        bases = self._read_json(self.directory / "baselines.json", {})
        return bases if isinstance(bases, dict) else {}

    def _running_path(self, tool_use_id: str) -> Path:
        return self.directory / "running" / f"{_safe_name(tool_use_id)}.json"

    def _ringing_path(self, session: str) -> Path:
        return self.directory / "ringing" / f"{_safe_name(session)}.json"

    def _save_rings(self, session: str, rings: list[dict]) -> None:
        path = self._ringing_path(session)
        if rings:
            self._write_json(path, rings)
            return
        try:
            path.unlink()
        except OSError:
            pass

    @staticmethod
    def _read_json(path: Path, default: Any) -> Any:
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return default

    @staticmethod
    def _write_json(path: Path, value: Any) -> None:
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_suffix(path.suffix + ".tmp")
            temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
            temporary.replace(path)
        except OSError:
            pass
