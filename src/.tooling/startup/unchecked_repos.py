#!/usr/bin/env python3
"""番人の照合の外にある repo の一覧を、 このタブが読める境界の分だけ起動の検査の行にする。

`startup-status.sh` が起動のたびに呼ぶ (= 起動の検査の `step_unchecked_repos`)。 一覧は番人の doctor が書き
(週次の監査の回と `doctor.sh --machine --save` の時)、 置き場は番人の監査の記録の folder (`guard_places.py audit-logs`)
の `unchecked-repos.txt`。 形は 1 行目が `# written <UTC の時刻> by doctor.sh --machine`、 続いて 1 本 1 行の
`outside<TAB><境界の名前><TAB><repo><TAB><理由>`。 境界の名前は、 境界の外なら `-`、 除外の folder なら `_exempt`。

repo の path は境界の folder の名前を含むので、 path を出すのはこのタブが読める境界の行と `-`・`_exempt` の行だけで、
ほかは数だけにする (= 番人の doctor が画面に出す時と同じ割り方)。 読める境界は入口の番人に訊く (`audit_findings.load_reach`)。
訊けない時は、 境界の行は全部数だけにする。 行の持ち主は振り分けない (= どのタブも、 自分の読める分を見る)。

出す行 (一覧が無い機械では何も出さない):
  unchecked_repos: none (written <時刻>)
  unchecked_repos: <N> repo(s) outside the guard's matching (written <時刻>)
    repo: <path> (area <名前>; <理由>)      読める行ごと
    <K> more in areas this tab does not read

走らせ方:
  python3 .tooling/startup/unchecked_repos.py
  (`UNCHECKED_REPOS_FILE` で一覧の在処を、 `AREA_GUARD_HOOK` で番人の在処を差し替えられる)
"""
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_findings import load_reach  # noqa: E402

GUARD_PLACES = Path.home() / ".git-hooks/scanners/guard_places.py"
LIST_NAME = "unchecked-repos.txt"
# どのタブにも path を出してよい境界の名前 (= 境界の外と、 除外の folder)
OPEN_AREAS = frozenset({"-", "_exempt"})
ASK_TIMEOUT_SEC = 10


def list_file() -> Path | None:
    """一覧の在処。 番人に訊けない時は None。"""
    named = os.environ.get("UNCHECKED_REPOS_FILE")
    if named:
        return Path(named)
    try:
        done = subprocess.run([sys.executable, str(GUARD_PLACES), "audit-logs"], capture_output=True, text=True,
                              timeout=ASK_TIMEOUT_SEC, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    folder = done.stdout.strip() if done.returncode == 0 else ""
    return Path(folder) / LIST_NAME if folder else None


def parse(text: str) -> tuple[str, list[tuple[str, str, str]]]:
    """一覧の本文 → (書いた時刻, [(境界, repo, 理由)])。 読めない行は捨てる。"""
    written = "?"
    rows: list[tuple[str, str, str]] = []
    for line in text.splitlines():
        if line.startswith("# written "):
            written = line.split()[2]
            continue
        fields = line.split("\t")
        if len(fields) >= 4 and fields[0] == "outside":
            rows.append((fields[1], fields[2], fields[3]))
    return written, rows


def status_lines(written: str, rows: list[tuple[str, str, str]], reach: set[str] | None) -> list[str]:
    """一覧から、 このタブに出す行。 `reach` は読める境界 (= 訊けなければ None)。"""
    if not rows:
        return [f"unchecked_repos: none (written {written})"]
    readable = OPEN_AREAS | (reach or set())
    shown = [row for row in rows if row[0] in readable]
    lines = [f"unchecked_repos: {len(rows)} repo(s) outside the guard's matching (written {written})"]
    lines += [f"  repo: {repo} (area {area}; {reason})" for area, repo, reason in shown]
    hidden = len(rows) - len(shown)
    if hidden:
        lines.append(f"  {hidden} more in areas this tab does not read")
    return lines


def main() -> int:
    path = list_file()
    if path is None or not path.is_file():
        return 0
    written, rows = parse(path.read_text(encoding="utf-8", errors="replace"))
    print("\n".join(status_lines(written, rows, load_reach())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
