#!/usr/bin/env python3
"""器の点検 (= manifest の `platform check`) の結果を、 起動の検査の行 (= `platform_check: …`) にする。

`startup-status.sh` が起動のたびに呼ぶ (= 起動の検査の 8g)。

器の切り替えの後に落ちた物 (= 前の path を信頼したままの Claude の設定・載っていない / 落ち続ける常駐) は、
動いている物の側に言う物が無く、 誰の画面にも出ない。 判定は `platform check` が持ち、 ここは結果を読んで
起動の画面へ運ぶだけ。 `template drift:` の行は数を読むための物で、 問題には数えない。

出す行:
  platform_check: clean                 問題が無い
  platform_check: N problem(s)          問題が在る。 続く `problem:` 行に 1 件 1 行
  platform_check: UNKNOWN (…)           点検が終わらなかった / 集計の行を出さなかった
  (何も出さない)                         器の無い機械 (= `<器の根>/manifest/bin/platform` が無い)

走らせ方:
  python3 .tooling/startup/check_platform.py

器の根は `AGENT_PLATFORM_ROOT` (= 無ければ `~/agent-platform`)。
"""
import os
import re
import subprocess
import sys
from pathlib import Path

PLATFORM_ROOT = Path(os.environ.get("AGENT_PLATFORM_ROOT") or Path.home() / "agent-platform")
COMMAND = PLATFORM_ROOT / "manifest" / "bin" / "platform"
# 実測は 0.2〜2 秒。 常駐への問い合わせが詰まった時に起動を待たせない上限
TIMEOUT_SEC = 20
SUMMARY = re.compile(r"^check: (clean|(\d+) problem\(s\))$")
COUNT_PREFIX = "template drift:"


def summarize(stdout: str, returncode: int, stderr: str) -> list[str]:
    """`platform check` の出力から、 起動の検査に出す行を返す。"""
    lines = [line for line in stdout.splitlines() if line.strip()]
    summary = SUMMARY.match(lines[-1]) if lines else None
    if summary is None:
        last_error = next((line for line in reversed(stderr.splitlines()) if line.strip()), "no message")
        return [f"platform_check: UNKNOWN (platform check exited {returncode} without its summary line: "
                f"{last_error.strip()[:120]})"]
    if summary.group(1) == "clean":
        return ["platform_check: clean"]
    problems = [line for line in lines[:-1] if not line.startswith(COUNT_PREFIX)]
    return [f"platform_check: {summary.group(2)} problem(s)"] + [f"  problem: {line}" for line in problems]


def main() -> int:
    """器が在る機械でだけ点検を走らせ、 行を出す (= 何が起きても起動の検査は止めない)。"""
    if not COMMAND.is_file():
        return 0
    try:
        done = subprocess.run([str(COMMAND), "check"], capture_output=True, text=True, timeout=TIMEOUT_SEC)
    except subprocess.TimeoutExpired:
        print(f"platform_check: UNKNOWN (platform check did not finish in {TIMEOUT_SEC}s)")
        return 0
    except OSError as error:
        print(f"platform_check: UNKNOWN (could not run {COMMAND}: {error.strerror})")
        return 0
    for line in summarize(done.stdout, done.returncode, done.stderr):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
