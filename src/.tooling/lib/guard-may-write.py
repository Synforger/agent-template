#!/usr/bin/env python3
"""書く前に、 この session がその path へ書けるかを入口の番人に訊く (= LLM 不使用)。

なぜ要るか:
  入口の番人 (= guard-dispatcher の area-guard) が読むのは、 エージェントが打ったコマンドだけ。
  コマンドが起動した script の中は読まず、 script に渡した相対 path は script が動く場所で解決される
  (= session の作業場所ではない)。 だから「引数で渡された階層へ書く script」 は、 session 自身が
  Edit で書こうとすれば止まる階層へ書けてしまう。 書く側の script が、 書く前にここで訊いて止まる。

走らせ方:
  python3 .tooling/lib/guard-may-write.py <path>...

  exit 0 = 書いてよい。 訊く相手が居ない時もここ (= 番人が入っていない機械 / エージェントの session の
           外で人が流した時 / 訊く口を持たない古い番人。 最後の 1 つは stderr に 1 行出す)
  exit 1 = 番人が拒んだ。 拒まれた path ごとに番人の 1 行を stderr に出す
  exit 2 = path が 1 つも渡されていない

判定そのものは番人が持つ (= ここは訊いて結果を返すだけ。 印も領域の定義も読まない)。 番人の在処は
`AREA_GUARD_HOOK` で差し替えられる (= 既定は番人が導入される `~/.git-hooks/` の下)。
"""
import os
import subprocess
import sys
from pathlib import Path

HOOK = Path(os.environ.get("AREA_GUARD_HOOK",
                           Path.home() / ".git-hooks/agent-hooks/claude-code/area-guard.py"))
# 番人が拒む時の行の頭 (= 番人自身の失敗や古い番人の例外と見分ける)
REFUSAL = "area-guard:"
TIMEOUT_SEC = 60


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: guard-may-write.py <path>...", file=sys.stderr)
        return 2
    session = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not session or not HOOK.is_file():
        return 0
    try:
        done = subprocess.run([sys.executable, str(HOOK), "may-write", session, *argv],
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=TIMEOUT_SEC)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"guard-may-write: the guard did not answer ({error.__class__.__name__}); writing as before",
              file=sys.stderr)
        return 0
    if done.returncode == 0:
        return 0
    refused = [line for line in done.stderr.splitlines() if line.startswith(REFUSAL)]
    if done.returncode == 1 and refused:
        print("\n".join(refused), file=sys.stderr)
        return 1
    print("guard-may-write: the guard could not answer (a guard older than `may-write`?); writing as before",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
