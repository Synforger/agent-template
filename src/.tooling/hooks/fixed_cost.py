"""起動と締めの固定費を、全部のタブで毎回 1 行ずつ記録する hook (Stop と UserPromptSubmit)。

- 起動 (phase=startup): session の最初の Stop で、会話の頭からそこまでの量を書く。2 回目からは印の file を見て抜ける
- 締め (phase=close): 入れ替えの締めの封筒 (`phase="close"`) が UserPromptSubmit に来た時に、会話の記録の今の長さを印に残す。
  その後の Stop で、印から後の量を書いて印を消す。印が無い Stop は file を 1 つ見て抜ける (= 毎回の応答で重い読みをしない)
書くのは、終わった時の context の大きさ (= 最後の応答が読んだ token)・使った量 (応答ごとの token の和と、API の単価の比で
重みづけた値)・どの封筒で始まったか・階層。記録の先は `$AGENT_PLATFORM_ROOT/state/token-usage/fixed.jsonl` (git に載せない)。
読むのは `startup/fixed_cost_summary.py`。失敗は全部黙って通す (= 応答を止めない)。
"""

import json
import os
import sys
import time

WEIGHTS = {"input_tokens": 1.0, "cache_creation_input_tokens": 1.25, "cache_read_input_tokens": 0.1, "output_tokens": 5.0}
CONTEXT_KEYS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
KINDS = (("session rollover", "rollover"), ("Tab opened by the client", "tab-open"), ("<child-start>", "child"))
CLOSE_MARK = 'session-rollover phase="close"'


def state_dir() -> str:
    root = os.environ.get("AGENT_PLATFORM_ROOT", os.path.expanduser("~/agent-platform"))
    return os.path.join(root, "state", "token-usage")


def human_text(row: dict) -> str:
    content = row.get("message", {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list) and not any(b.get("type") == "tool_result" for b in content):
        return " ".join(b.get("text", "") for b in content if b.get("type") == "text")
    return ""


def measure(transcript: str, offset: int) -> dict:
    """会話の記録の offset バイト目から今までの量を数える。"""
    seen, weighted, raw, context, opening = set(), 0.0, 0, 0, None
    with open(transcript, "rb") as fh:
        fh.seek(offset)
        for line in fh:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if opening is None and row.get("type") == "user" and not row.get("isMeta"):
                opening = human_text(row) or None
            message = row.get("message") or {}
            if row.get("type") != "assistant" or message.get("id") in seen:
                continue
            seen.add(message.get("id"))
            usage = message.get("usage") or {}
            weighted += sum((usage.get(k) or 0) * w for k, w in WEIGHTS.items())
            raw += sum(usage.get(k) or 0 for k in WEIGHTS)
            context = sum(usage.get(k) or 0 for k in CONTEXT_KEYS)
    head = (opening or "")[:300]
    kind = next((name for mark, name in KINDS if mark in head), "other")
    return {"kind": kind, "answers": len(seen), "context_tokens": context, "used_tokens": raw, "used_weighted": round(weighted)}


def write_row(phase: str, payload: dict, numbers: dict) -> None:
    row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "phase": phase, "session": payload.get("session_id"),
           "agent_dir": os.path.basename(payload.get("cwd") or ""), "tier": os.environ.get("AGENT_TIER", ""),
           "tab": os.environ.get("PWA_SID", ""), "child": os.environ.get("AGENT_CHILD") == "1", **numbers}
    with open(os.path.join(state_dir(), "fixed.jsonl"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def on_prompt(payload: dict, transcript: str, marks: str) -> None:
    if CLOSE_MARK in (payload.get("prompt") or ""):
        with open(os.path.join(marks, payload["session_id"] + ".close"), "w") as fh:
            fh.write(str(os.path.getsize(transcript)))


def on_stop(payload: dict, transcript: str, marks: str) -> None:
    session = payload["session_id"]
    close_mark = os.path.join(marks, session + ".close")
    if os.path.exists(close_mark):
        with open(close_mark) as fh:
            offset = int(fh.read().strip() or 0)
        os.remove(close_mark)
        write_row("close", payload, measure(transcript, offset))
    start_mark = os.path.join(marks, session)
    if not os.path.exists(start_mark):
        open(start_mark, "w").close()
        write_row("startup", payload, measure(transcript, 0))


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    transcript = payload.get("transcript_path") or ""
    if not payload.get("session_id") or not os.path.isfile(transcript):
        return 0
    marks = os.path.join(state_dir(), "seen")
    try:
        os.makedirs(marks, exist_ok=True)
        if payload.get("hook_event_name") == "UserPromptSubmit":
            on_prompt(payload, transcript, marks)
        else:
            on_stop(payload, transcript, marks)
    except (OSError, ValueError):
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
