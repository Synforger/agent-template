#!/usr/bin/env python3
"""エージェントが流した試験が「その repo のいつもの時間」を越えた時だけ鳴り、 縮めるか受け入れるまで閉じる手を止める hook。

入口だけ。 payload を受けて `lib/test_time.py` (判定) と `lib/test_time_store.py` (状態) を呼ぶ。
settings の PreToolUse (matcher Bash)・PostToolUse (matcher Bash)・PostToolUseFailure (matcher Bash) から呼ぶ。
試験 = tests/test-test-time-gate.sh。 受け入れの命令 = `work/test-time.py`

- PreToolUse: まず終わった background の記録を終わりにする (下)。 閉じる手で鳴りが残っていれば deny。
  試験の命令で、 同じ repo の別の session の終わっていない記録 (30 分以内) が在れば deny。 それ以外の試験の命令は、 始まりを記録する。
  秒は命令の全体でしか測れないので、 試験が複数在る命令は束で 1 つの試験として数える
- PostToolUse: まず終わった background の記録を終わりにする。 始まりと比べて秒数を出し、 基準と比べる。
  線を越えたら鳴りを残して文脈に文を足す。 収まれば基準を更新し、 同じ鍵の鳴りを消す。 `run_in_background` の命令は、 ここでは終わりにしない
- PostToolUseFailure: 始まりの記録を捨てるだけ (= 失敗した試験の時間は基準にしない)
- background の終わり: 知らせは UserPromptSubmit を通らず、 会話の記録に `queue-operation` の `enqueue` の行で残る。
  Bash の hook が呼ばれるたび (どの session でも)、 終わっていない background の記録の会話の記録の末尾から同じ tool-use-id の行を探し、
  見つけたら、 その行の時刻を終わりとして判定する (status が completed の時だけ。 出力は output-file の末尾)。
  記録の持ち主の session の hook なら文を文脈に足し、 別の session の hook なら鳴りを持ち主の session に残すだけ
- 読めない・書けない・壊れた入力は、 何も出さずに通す (= fail-open)。 鳴らない時は何も出さない
"""
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

from test_time import (  # noqa: E402
    COLLISION_WINDOW_SECONDS,
    baseline_key,
    closing_deny_message,
    collision_message,
    is_closing_hand,
    next_base,
    find_task_notification,
    ring_limit,
    ring_message,
    rings,
    runs_label,
    slowest_lines,
    test_runs,
)
from test_time_store import (  # noqa: E402
    OUTPUT_TAIL_BYTES,
    TRANSCRIPT_TAIL_BYTES,
    TestTimeStore,
    current_time,
    read_tail,
    repo_root,
)


def emit(event: str, deny_reason: str | None, contexts: list[str]) -> None:
    """hook の出力を 1 つの JSON にして出す (= 止める理由か流した本人の文脈に足す文があれば。 無ければ何も出さない)。"""
    output: dict = {"hookEventName": event}
    if deny_reason:
        output.update({"permissionDecision": "deny", "permissionDecisionReason": deny_reason})
    if contexts:
        output["additionalContext"] = "\n\n".join(contexts)
    if len(output) > 1:
        print(json.dumps({"hookSpecificOutput": output}, ensure_ascii=False))


def response_text(response) -> str:
    """PostToolUse の tool_response から出力の文字列を取る (= 文字列でも、 stdout / stderr を持つ dict でも)。"""
    if isinstance(response, str):
        return response
    if isinstance(response, dict):
        return "\n".join(str(response.get(name) or "") for name in ("stdout", "stderr"))
    return ""


def call_id(payload: dict) -> str:
    """呼び出しの id (= payload の tool_use_id。 無ければ session と命令から作る。 始まりと終わりで同じ値になる)。"""
    if payload.get("tool_use_id"):
        return payload["tool_use_id"]
    command = (payload.get("tool_input") or {}).get("command") or ""
    return f"{payload.get('session_id') or ''}-{hashlib.sha1(command.encode()).hexdigest()[:12]}"


def before_call(payload: dict, store: TestTimeStore, now: float) -> str | None:
    """PreToolUse: 閉じる手と試験のぶつかりを止める理由を返し (= 通す時は None)、 通す試験の始まりを記録する。"""
    tool_input = payload.get("tool_input") or {}
    command = tool_input.get("command") or ""
    session = payload.get("session_id") or ""
    if is_closing_hand(command) and store.ringing(session):
        return closing_deny_message(store.ringing(session))
    runs = test_runs(command, Path(payload.get("cwd") or "."))
    root = repo_root(runs[0][0]) if runs else None
    if not root:
        return None
    elsewhere = store.running_elsewhere(root, session, now, COLLISION_WINDOW_SECONDS)
    if elsewhere:
        return collision_message(Path(root).name, now - min(record["started_at"] for record in elsewhere))
    tool_use_id = call_id(payload)
    store.start(tool_use_id, {
        "session": session, "repo": root, "command": runs_label(root, runs), "started_at": now,
        "background": bool(tool_input.get("run_in_background")), "tool_use_id": tool_use_id,
        "transcript_path": payload.get("transcript_path") or "",
    })
    return None


def judge(record: dict, output: str, now: float, store: TestTimeStore) -> str | None:
    """終わった試験を基準と比べる。 線を越えたら鳴りを残して文を返し、 収まれば基準を更新して同じ鍵の鳴りを消す。"""
    elapsed = now - record["started_at"]
    key = baseline_key(record["repo"], record["command"])
    base = store.load_base(key)
    if rings(base, elapsed):
        slowest = slowest_lines(output)
        store.add_ring(record["session"], {
            "key": key, "repo": record["repo"], "command": record["command"], "base": base, "elapsed": elapsed,
            "limit": ring_limit(base), "slowest": slowest, "at": now,
        })
        return ring_message(Path(record["repo"]).name, record["command"], base, elapsed, slowest)
    store.save_base(key, next_base(base, elapsed))
    store.clear_ring(record["session"], key)
    return None


def after_call(payload: dict, store: TestTimeStore, now: float, *, succeeded: bool) -> str | None:
    """PostToolUse / PostToolUseFailure: 始まりの記録を終わりにして判定し、 鳴る時はその文を返す。"""
    if succeeded and (payload.get("tool_input") or {}).get("run_in_background"):
        return None
    record = store.finish(call_id(payload))
    if record is None or not succeeded:
        return None
    return judge(record, response_text(payload.get("tool_response")), now, store)


def settle_background(session: str, store: TestTimeStore) -> list[str]:
    """会話の記録に終わりの知らせが残った background の記録を終わりにして判定する。 session の持ち物で鳴った文だけ返す (別の session の物は鳴りを残すだけ)。"""
    messages: list[str] = []
    transcripts: dict[str, str] = {}
    for record in store.running_background():
        path = record["transcript_path"]
        if path not in transcripts:
            transcripts[path] = read_tail(path, TRANSCRIPT_TAIL_BYTES)
        notice = find_task_notification(transcripts[path], record["tool_use_id"])
        if notice is None:
            continue
        store.finish(record["tool_use_id"])
        if notice.status != "completed":
            continue
        output = read_tail(notice.output_file, OUTPUT_TAIL_BYTES) if notice.output_file else ""
        message = judge(record, output, notice.ended_at, store)
        if message and record["session"] == session:
            messages.append(message)
    return messages


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        event = payload.get("hook_event_name")
        if payload.get("tool_name") != "Bash" or event not in ("PreToolUse", "PostToolUse", "PostToolUseFailure"):
            return 0
        store, now = TestTimeStore(), current_time()
        contexts = settle_background(payload.get("session_id") or "", store)
        deny_reason = None
        if event == "PreToolUse":
            deny_reason = before_call(payload, store, now)
        else:
            message = after_call(payload, store, now, succeeded=event == "PostToolUse")
            contexts += [message] if message else []
        emit(event, deny_reason, contexts)
    except Exception:  # noqa: BLE001  hook は何があっても作業を止めない
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
