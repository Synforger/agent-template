#!/usr/bin/env python3
"""週次の監査の log から、 このタブが読める境界の repo の新しい漏れを起動の検査の行にする。

`audit-known.sh status` が、 log の repo の見出しに境界 (= `, area <名前>`) が書かれた回に呼ぶ。

番人は既知と決めた物 (= `weekly-audit.sh --accept`) を除いて FINDINGS に書くので、 FINDINGS の repo は
全部が新しい漏れになる。 新しい漏れは、 その repo の境界を読めるタブにだけ出す。 境界の外の repo
(= 見出しが `area -`) は、 境界を 1 つも読まないタブに出す。 このタブが読める境界は入口の番人に訊く
(= `area-guard.py reach`。 判定は番人が持ち、 ここは訊いた名前と log の名前を突き合わせるだけ)。
番人に訊けない時は全部を出す (= 黙って隠すより、 読めない境界の名前が出る方を選ぶ)。

走らせ方:
  python3 .tooling/startup/audit_findings.py <log> <log の古さの日数>

番人の在処は `AREA_GUARD_HOOK` で差し替えられる (= 既定は番人が導入される `~/.git-hooks/` の下)。
"""
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HOOK = Path(os.environ.get("AREA_GUARD_HOOK",
                           Path.home() / ".git-hooks/agent-hooks/claude-code/area-guard.py"))
TIMEOUT_SEC = 60
OUTSIDE = "-"

HEADER = re.compile(r"^--- (?P<repo>.*) \((?P<notes>.*)\) ---$")
AREA_NOTE = re.compile(r"(?:^|, )area (?P<area>[^,]+)$")
END = re.compile(r"^--- (?P<repo>.*): (?P<result>clean|FINDINGS) ---$")
HITS = re.compile(r"^(?P<count>[0-9]+) hit\(s\) = (?P<words>.*)$")
DONE = re.compile(r"done: (?P<count>[0-9]+) repo")


@dataclass
class Finding:
    """FINDINGS で終わった repo 1 本と、 その中で見つかった物 (= 調べた場所と語)。"""

    repo: str
    area: str
    places: list[tuple[str, str]] = field(default_factory=list)


@dataclass
class AuditLog:
    """log を読んだ結果 (= FINDINGS の repo と、 log の末尾が言う FINDINGS の数)。"""

    findings: list[Finding]
    declared_count: int | None


def has_areas(text: str) -> bool:
    """log の repo の見出しに境界が書かれているか (= 番人がこの形の log を書く版か)。"""
    return any((m := HEADER.match(line)) and AREA_NOTE.search(m["notes"]) for line in text.splitlines())


def parse(text: str) -> AuditLog:
    """log の本文から FINDINGS の repo を読む。 見つかった物の行が読めない repo も、 場所 `?` で残す。"""
    findings: list[Finding] = []
    current: Finding | None = None
    for line in text.splitlines():
        if (header := HEADER.match(line)) and not END.match(line):
            note = AREA_NOTE.search(header["notes"])
            current = Finding(header["repo"], note["area"].strip() if note else OUTSIDE)
        elif end := END.match(line):
            if current is not None and end["result"] == "FINDINGS":
                if not current.places:
                    current.places.append(("?", "*"))
                findings.append(current)
            current = None
        elif current is not None and line.startswith("fail: "):
            body = line.removeprefix("fail: ")
            if body.startswith("deep audit: ") or ": " not in body:
                continue
            place, rest = body.split(": ", 1)
            hits = HITS.match(rest)
            current.places.append((place, hits["words"] if hits else "*"))
    counts = DONE.findall(text)
    return AuditLog(findings, int(counts[-1]) if counts else None)


def split_by_reach(findings: list[Finding], reach: set[str]) -> tuple[list[Finding], list[Finding]]:
    """→ (このタブに出す物, 他の境界のタブに出す物)。 境界を読まないタブは境界の外の repo を受け持つ。"""
    if reach:
        mine = [f for f in findings if f.area in reach]
    else:
        mine = [f for f in findings if f.area == OUTSIDE]
    return mine, [f for f in findings if f not in mine]


def status_lines(log: AuditLog, name: str, age_days: int, reach: set[str] | None) -> list[str]:
    """起動の検査に出す行 (= 1 行目が要約、 続く行が repo ごとの見つかった物)。 出す物が無ければ空。"""
    if not log.findings:
        return []
    if log.declared_count != len(log.findings):
        return [f"weekly_audit: NEW in {log.declared_count} repo(s) ({name}, {age_days}d ago, log not parsed)"
                " -> read the FINDINGS blocks of that log"]
    if reach is None:
        mine, others, note = log.findings, [], "; this tab's areas unknown, every repo shown"
    else:
        mine, others = split_by_reach(log.findings, reach)
        note = f"; {len(others)} other repo(s) with findings in areas this tab does not read, not shown"
    if not mine:
        return [f"weekly_audit: nothing for this tab ({len(others)} repo(s) with findings in areas this tab"
                f" does not read; {name})"]
    lines = [f"weekly_audit: NEW in {len(mine)} repo(s) ({name}, {age_days}d ago{note}) -> say it first in the briefing"]
    for finding in mine:
        found = "; ".join(f"{place}: {words}" for place, words in finding.places)
        lines.append(f"  new: {finding.repo} -> {found}")
    return lines


def load_reach() -> set[str] | None:
    """このタブが読める境界の名前 (= 入口の番人の答え)。 番人が無い・訊く口の無い古い番人なら None。"""
    if not HOOK.is_file():
        return None
    try:
        done = subprocess.run([sys.executable, str(HOOK), "reach"], capture_output=True, text=True,
                              timeout=TIMEOUT_SEC, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return None
    return {line.strip() for line in done.stdout.splitlines() if line.strip()}


def main(argv: list[str]) -> int:
    if len(argv) != 2 or not argv[1].isdigit():
        print("usage: audit_findings.py <log> <age in days>", file=sys.stderr)
        return 2
    path = Path(argv[0])
    log = parse(path.read_text(encoding="utf-8", errors="replace"))
    for line in status_lines(log, path.name, int(argv[1]), load_reach()):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
