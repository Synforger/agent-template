"""Run test scripts one at a time, stop one that runs past the time limit, and name the slowest.

Called by the Taskfile's `test` and `ci` tasks with the test scripts as arguments. Stops at the
first script that fails or runs out of time. The slowest are printed in pytest's `--durations` form, so the closing hooks that read pytest output read
these too.
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

# The slowest script takes about 15 seconds on a developer's Mac (7 on the CI runner); three times that.
TIME_LIMIT_SECONDS = 45
SLOWEST_COUNT = 10
# A stopped script gets this long to clean up after SIGTERM before it is killed.
STOP_GRACE_SECONDS = 5


def stop_group(process: subprocess.Popen[bytes]) -> None:
    """Stop the script and everything it started: SIGTERM first, SIGKILL when it does not end."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=STOP_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    except ProcessLookupError:
        process.wait()


def run_script(script: Path, limit_seconds: float) -> tuple[int | None, float]:
    """Run one script under bash; return its exit code (None when stopped at the limit) and its seconds."""
    started = time.monotonic()
    # A session of its own lets the limit stop the script's children too.
    process = subprocess.Popen(["bash", str(script)], start_new_session=True)
    try:
        exit_code: int | None = process.wait(timeout=limit_seconds)
    except subprocess.TimeoutExpired:
        stop_group(process)
        exit_code = None
    except KeyboardInterrupt:
        stop_group(process)
        raise
    return exit_code, time.monotonic() - started


def print_slowest(durations: list[tuple[float, Path]]) -> None:
    """Print the slowest scripts, slowest first."""
    slowest = sorted(durations, reverse=True)[:SLOWEST_COUNT]
    print(f"===== slowest {SLOWEST_COUNT} durations =====")
    for seconds, script in slowest:
        print(f"{seconds:.2f}s call {script}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("scripts", nargs="+", type=Path, help="test scripts to run, in order")
    arguments = parser.parse_args()

    durations: list[tuple[float, Path]] = []
    failed = False
    for script in arguments.scripts:
        exit_code, seconds = run_script(script, TIME_LIMIT_SECONDS)
        durations.append((seconds, script))
        if exit_code is None:
            print(f"TIMEOUT {script}: stopped after {TIME_LIMIT_SECONDS}s (the limit per script)")
            failed = True
            break
        if exit_code != 0:
            print(f"FAIL {script}: exit {exit_code}")
            failed = True
            break
    print_slowest(durations)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
