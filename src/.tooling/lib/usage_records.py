"""使用量の元になる記録を読む: 7 日枠の行、会話の記録の応答ごとの量、会話がどのタブの物か。

読むだけで何も書かない。呼ぶのは work/plan_run.py。中身の文は読まず、usage の数と時刻とタブの題だけを取る。
重みは hooks/fixed_cost.py と同じ API の単価の比で、7 日枠の本当の重みではない。
"""

import glob
import json
import os
from dataclasses import dataclass
from datetime import datetime

WEIGHTS = {"input_tokens": 1.0, "cache_creation_input_tokens": 1.25, "cache_read_input_tokens": 0.1, "output_tokens": 5.0}
AGENT_MARK = "-agents-"


@dataclass(frozen=True)
class SessionUse:
    """会話 1 本の、ある時刻から後の量。"""

    session: str
    account: str
    agent: str
    tab: str
    title: str
    tier: str
    is_child: bool
    answers: int
    weighted: float


def platform_root() -> str:
    return os.environ.get("AGENT_PLATFORM_ROOT", os.path.expanduser("~/agent-platform"))


def load_limit_rows() -> list[dict]:
    """statusline が書いた 7 日枠の行を全部返す。file が無ければ空。"""
    path = os.path.join(platform_root(), "state", "statusline", "rate-limits.jsonl")
    rows: list[dict] = []
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        pass
    return rows


def _tab_table() -> dict[str, dict]:
    """会話の id → タブの id・題・階層・子か。client の一覧と結び付きの記録、固定費の記録から作る。"""
    table: dict[str, dict] = {}
    data = os.path.join(platform_root(), "state", "claude-pwa-client", "data")
    try:
        with open(os.path.join(data, "session_meta.json"), encoding="utf-8") as handle:
            tabs = {tab["id"]: tab for tab in json.load(handle)}
        with open(os.path.join(data, "jsonl_bindings.json"), encoding="utf-8") as handle:
            bindings = json.load(handle)
    except (OSError, ValueError, KeyError, TypeError):
        tabs, bindings = {}, {}
    try:
        with open(os.path.join(platform_root(), "state", "token-usage", "fixed.jsonl"), encoding="utf-8") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if row.get("session") and row.get("tab"):
                    table[row["session"]] = {"tab": row["tab"], "tier": row.get("tier") or "", "child": bool(row.get("child"))}
    except OSError:
        pass
    for tab_id, bind in bindings.items():
        path = bind.get("jsonl_path") if isinstance(bind, dict) else None
        if path:
            table.setdefault(os.path.basename(path)[: -len(".jsonl")], {})["tab"] = tab_id
    for entry in table.values():
        tab = tabs.get(entry.get("tab", ""), {})
        entry.setdefault("tier", tab.get("tier") or "")
        entry["title"] = tab.get("title") or ""
        entry["child"] = bool(entry.get("child") or tab.get("child"))
    return table


def _agent_of(project_folder: str) -> str:
    """口座の記録の folder の名前 (`-Users-…-agents-<agent>…`) から agent の名前を取る。当たらなければ other。"""
    if AGENT_MARK not in project_folder:
        return "other"
    return project_folder.split(AGENT_MARK, 1)[1].split("-", 1)[0] or "other"


def _account_of(path: str, account_roots: dict[str, str]) -> str:
    """会話の記録の path が、どの口座の記録の根の下に在るかを返す。どの根にも入らなければ空。"""
    for account, root in account_roots.items():
        if path.startswith(os.path.join(os.path.expanduser(root), "")):
            return account
    return ""


def load_session_uses(since: float, until: float | None = None, account_roots: dict[str, str] | None = None) -> list[SessionUse]:
    """全部の口座の会話の記録から、`since` から `until` (epoch 秒。無ければ今) までの応答の量を会話ごとに返す。

    口座は記録の根で決まる (`account_roots` は 口座 → 根の folder。folder の名前では分けられない)。
    口座の記録の folder が link で同じ実体を指す時は 1 本に数える。
    """
    table = _tab_table()
    roots = account_roots or {}
    uses: list[SessionUse] = []
    seen_files: set[str] = set()
    for path in sorted(glob.glob(os.path.expanduser("~/.claude*/projects/*/*.jsonl"))):
        real = os.path.realpath(path)
        if real in seen_files or os.path.getmtime(path) < since:
            continue
        seen_files.add(real)
        answers, weighted = _measure(path, since, until)
        if not answers:
            continue
        session = os.path.basename(path)[: -len(".jsonl")]
        entry = table.get(session, {})
        uses.append(
            SessionUse(
                session=session,
                account=_account_of(path, roots),
                agent=_agent_of(os.path.basename(os.path.dirname(path))),
                tab=entry.get("tab", ""),
                title=entry.get("title", ""),
                tier=entry.get("tier", ""),
                is_child=bool(entry.get("child")),
                answers=answers,
                weighted=weighted,
            )
        )
    return uses


def _measure(path: str, since: float, until: float | None) -> tuple[int, float]:
    seen: set[str] = set()
    weighted = 0.0
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                message = row.get("message") or {}
                if row.get("type") != "assistant" or message.get("id") in seen:
                    continue
                stamp = _epoch(row.get("timestamp"))
                if stamp < since or (until is not None and stamp >= until):
                    continue
                seen.add(message.get("id"))
                usage = message.get("usage") or {}
                weighted += sum((usage.get(key) or 0) * weight for key, weight in WEIGHTS.items())
    except OSError:
        return 0, 0.0
    return len(seen), weighted


def _epoch(stamp: str | None) -> float:
    if not stamp:
        return 0.0
    try:
        return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0
