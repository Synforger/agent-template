#!/usr/bin/env python3
"""番人の週次の監査の記録から、 このタブに届ける物を起動の検査の行 (= `weekly_audit: …`) にする。

`audit-known.sh status` が、 監査の記録の置き場を渡して呼ぶ (= 起動の検査の 6b)。

番人は既知と決めた物 (= `weekly-audit.sh --accept [--as-of <時刻>]`) を除いて FINDINGS に書くので、
FINDINGS の repo は全部が新しい漏れになる。 新しい漏れは、 その repo の境界 (= 見出しの `, area <名前>`) を
読めるタブにだけ出す。 境界の外の repo (= `area -`) は、 境界を 1 つも読まないタブに出す。 このタブが
読める境界は入口の番人に訊く (= `area-guard.py reach`。 判定は番人が持ち、 ここは訊いた名前と記録の名前を
突き合わせるだけ)。 番人に訊けない時は全部を出す (= 黙って隠すより、 読めない境界の名前が出る方を選ぶ)。

出す行:
  weekly_audit: NO RUN                    記録が無い / 終わった記録が無い
  weekly_audit: INCOMPLETE (…)            一番新しい記録に終わりの行が無い (= 走っている最中か、 途中で止まった)。
                                          続く行は、 終わりの行を持つ一番新しい記録で判定した物
  weekly_audit: clean / STALE             見つかった物が無い (= 7 日より古ければ STALE)
  weekly_audit: NEW in N repo(s) …        このタブの境界の新しい漏れ。 続く `new:` 行に repo と見つかった物
  weekly_audit: nothing for this tab (…)  見つかった物は他のタブの境界にだけ在る
  weekly_audit: OLD LOG (…)               見出しに境界の無い記録 (= 書いた番人が古い)。 判定しない

走らせ方:
  python3 .tooling/startup/audit_findings.py <監査の記録の folder>

番人の在処は `AREA_GUARD_HOOK` で差し替えられる (= 既定は番人が導入される `~/.git-hooks/` の下)。
"""
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

HOOK = Path(os.environ.get("AREA_GUARD_HOOK",
                           Path.home() / ".git-hooks/agent-hooks/claude-code/area-guard.py"))
TIMEOUT_SEC = 60
STALE_DAYS = 7
SECONDS_PER_DAY = 86400
LOG_GLOB = "weekly-audit-*.log"
OUTSIDE = "-"

HEADER = re.compile(r"^--- (?P<repo>.*) \((?P<notes>.*)\) ---$")
AREA_NOTE = re.compile(r"(?:^|, )area (?P<area>[^,]+)$")
END = re.compile(r"^--- (?P<repo>.*): (?P<result>clean|FINDINGS) ---$")
HITS = re.compile(r"^(?P<count>[0-9]+) hit\(s\) = (?P<words>.*)$")
DONE = re.compile(r"^=== done: (?P<count>[0-9]+) repo", re.MULTILINE)


@dataclass
class Finding:
    """FINDINGS で終わった repo 1 本と、 その中で見つかった物 (= 調べた場所と語)。"""

    repo: str
    area: str
    places: list[tuple[str, str]] = field(default_factory=list)


@dataclass
class AuditLog:
    """記録を読んだ結果 (= FINDINGS の repo、 見出しに境界が在るか、 終わりの行が言う FINDINGS の数)。"""

    findings: list[Finding]
    has_areas: bool
    declared_count: int | None


def parse(text: str) -> AuditLog:
    """記録の本文を読む。 見つかった物の行が読めない repo も、 場所 `?` で残す。"""
    findings: list[Finding] = []
    current: Finding | None = None
    has_areas = False
    for line in text.splitlines():
        if (header := HEADER.match(line)) and not END.match(line):
            note = AREA_NOTE.search(header["notes"])
            has_areas = has_areas or note is not None
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
    return AuditLog(findings, has_areas, int(counts[-1]) if counts else None)


def split_by_reach(findings: list[Finding], reach: set[str]) -> tuple[list[Finding], list[Finding]]:
    """→ (このタブに出す物, 他の境界のタブに出す物)。 境界を読まないタブは境界の外の repo を受け持つ。"""
    if reach:
        mine = [f for f in findings if f.area in reach]
    else:
        mine = [f for f in findings if f.area == OUTSIDE]
    return mine, [f for f in findings if f not in mine]


def finding_lines(log: AuditLog, name: str, age_days: int, reach: set[str] | None) -> list[str]:
    """終わった記録 1 本の判定の行 (= 1 行目が要約、 続く行が repo ごとの見つかった物)。"""
    if not log.findings and not log.declared_count:
        if age_days > STALE_DAYS:
            return [f"weekly_audit: STALE (last run {age_days}d ago: {name})"]
        return [f"weekly_audit: clean ({name}, {age_days}d ago)"]
    if not log.has_areas:
        return [f"weekly_audit: OLD LOG ({name}, {age_days}d ago: the guard that wrote it names no repo's area, so"
                " its findings are not judged) -> deploy the guard with .tooling/distribute/guard-update.sh"]
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


def status_lines(logs: list[tuple[str, int, str]], reach: set[str] | None, folder: str) -> list[str]:
    """記録を新しい順に並べた (名前, 古さの日数, 本文) から、 起動の検査に出す行。"""
    if not logs:
        return [f"weekly_audit: NO RUN (no log in {folder})"]
    lines = []
    finished = [entry for entry in logs if DONE.search(entry[2])]
    newest_name, newest_age, _ = logs[0]
    # 終わりの行の無い記録を 0 件と読むと、 一つ前の本物の結果が「clean」 に隠れる
    if not finished or finished[0][0] != newest_name:
        lines.append(f"weekly_audit: INCOMPLETE ({newest_name} has no end line, {newest_age}d old: running, or stopped"
                     " half way) -> the lines below are from the last finished run")
    if not finished:
        return lines + [f"weekly_audit: NO RUN (no finished log in {folder})"]
    name, age_days, text = finished[0]
    return lines + finding_lines(parse(text), name, age_days, reach)


def load_logs(folder: Path) -> list[tuple[str, int, str]]:
    """監査の記録を新しい順に (名前, 古さの日数, 本文)。 folder が無ければ空。"""
    now = time.time()
    paths = sorted(folder.glob(LOG_GLOB), key=lambda p: p.stat().st_mtime, reverse=True)
    return [(p.name, int((now - p.stat().st_mtime) // SECONDS_PER_DAY), p.read_text(encoding="utf-8", errors="replace"))
            for p in paths]


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
    if len(argv) != 1:
        print("usage: audit_findings.py <folder of the audit logs>", file=sys.stderr)
        return 2
    logs = load_logs(Path(argv[0]))
    reach = load_reach() if logs else None
    for line in status_lines(logs, reach, argv[0]):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
