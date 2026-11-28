#!/usr/bin/env python3
"""番人の週次の監査の記録から、 このタブに届ける物を起動の検査の行 (= `weekly_audit: …`) にする。

`audit-known.sh status` が、 監査の記録の置き場を渡して呼ぶ (= 起動の検査の 6b)。

番人は既知と決めた物 (= `weekly-audit.sh --accept [--as-of <時刻>]`) を除いて FINDINGS に書くので、
FINDINGS の repo は全部が新しい漏れになる。 ただし回の後に受け入れた repo (= 受け入れの記録の `since` が、 その回の
記録より新しい) は、 次の回まで FINDINGS に残るので、 新しい漏れから外して別の行に出す。 新しい漏れは、 境界ごとに 1 つの
係のタブだけが読み上げる。

- 境界の外の repo (`area -`、個人の側) の係は normal のタブ
- 境界の中の repo の係は、階層の folder に印の file `.weekly-audit-reader` を置いた階層のタブ。印の在る階層が
  読める境界の repo は、ほかのタブには出さない。印が無い・係に訊けない境界の repo は、その境界を読めるタブ全部に出す
- 子のタブ (`AGENT_CHILD=1`) は係にならない

印を file にするのは、会社の階層の名前を git に載るこの file に書かずに係を決めるため。タブと係が読める境界は
入口の番人に訊く (`area-guard.py reach` を、係ならその階層の folder を `GUARD_WORK_FOLDER` に渡して呼ぶ)。
判定は番人が持ち、ここは訊いた名前と記録の名前を突き合わせるだけ。番人に訊けない時は全部を出す。黙って隠すより、
読めない境界の名前が出る方を選ぶ。

出す行:
  weekly_audit: NO RUN                    記録が無い / 終わった記録が無い
  weekly_audit: INCOMPLETE (…)            一番新しい記録に終わりの行が無い (= 走っている最中か、 途中で止まった)。
                                          続く行は、 終わりの行を持つ一番新しい記録で判定した物
  weekly_audit: clean / STALE             見つかった物が無い (= 7 日より古ければ STALE)
  weekly_audit: NEW in N repo(s) …        このタブの境界の新しい漏れ。 続く `new:` 行に repo と見つかった物
  weekly_audit: accepted after the run …  このタブの境界の FINDINGS が全部、 回の後に受け入れ済み (= 最初に言う物は無い)。
                                          NEW の行の後に付く時は `accepted:` 行に repo と受け入れた時刻
  weekly_audit: nothing for this tab (…)  見つかった物は、ほかのタブの境界にだけ在るか、係のタブが読み上げる
  weekly_audit: OLD LOG (…)               見出しに境界の無い記録 (= 書いた番人が古い)。 判定しない

走らせ方:
  python3 .tooling/startup/audit_findings.py <監査の記録の folder> [<受け入れの記録の folder>]

番人の在処は `AREA_GUARD_HOOK` で差し替えられる (既定は番人が導入される `~/.git-hooks/` の下)。
このタブの階層は `AGENT_TIER` (無ければ normal)、エージェントの folder は `AGENT_ROOT` (無ければこの file の 2 つ上)。
"""
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from tier_paths import tier_files  # noqa: E402

HOOK = Path(os.environ.get("AREA_GUARD_HOOK",
                           Path.home() / ".git-hooks/agent-hooks/claude-code/area-guard.py"))
TIMEOUT_SEC = 60
STALE_DAYS = 7
SECONDS_PER_DAY = 86400
LOG_GLOB = "weekly-audit-*.log"
OUTSIDE = "-"
NORMAL_TIER = "normal"
READER_MARKER = ".weekly-audit-reader"
AGENT_DIR = Path(os.environ.get("AGENT_ROOT") or Path(__file__).resolve().parents[2])

HEADER = re.compile(r"^--- (?P<repo>.*) \((?P<notes>.*)\) ---$")
AREA_NOTE = re.compile(r"(?:^|, )area (?P<area>[^,]+)$")
END = re.compile(r"^--- (?P<repo>.*): (?P<result>clean|FINDINGS) ---$")
HITS = re.compile(r"^(?P<count>[0-9]+) hit\(s\) = (?P<words>.*)$")
DONE = re.compile(r"^=== done: (?P<count>[0-9]+) repo", re.MULTILINE)
KNOWN_GLOB = "*.known"
#: 受け入れの記録の頭の行 (`# findings accepted as known by <道具> (<repo>)`) と、 受け入れた時刻の行
KNOWN_REPO = re.compile(r"^#.*\((?P<repo>/[^()]*)\)\s*$")
KNOWN_SINCE = re.compile(r"^since (?P<stamp>\S+)\s*$")


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


@dataclass
class Audience:
    """このタブが誰か。読める境界、係か、normal か、係のタブが読み上げる境界 (訊けなければ空)。"""

    reach: set[str]
    is_reader: bool
    is_normal: bool
    covered: set[str]


def split_by_reach(findings: list[Finding], reach: set[str]) -> tuple[list[Finding], list[Finding]]:
    """→ (このタブが読める物, 他の境界のタブの物)。 境界を読まないタブは境界の外の repo を受け持つ。"""
    if reach:
        mine = [f for f in findings if f.area in reach]
    else:
        mine = [f for f in findings if f.area == OUTSIDE]
    return mine, [f for f in findings if f not in mine]


def split_for(findings: list[Finding], audience: Audience) -> tuple[list[Finding], list[Finding]]:
    """→ (このタブが読み上げる物, ほかのタブが読み上げる物)。係でないタブは、係の境界と境界の外を normal に譲る。"""
    readable, _ = split_by_reach(findings, audience.reach)
    if audience.is_reader:
        mine = readable
    else:
        mine = [f for f in readable
                if (f.area == OUTSIDE and audience.is_normal) or (f.area != OUTSIDE and f.area not in audience.covered)]
    return mine, [f for f in findings if f not in mine]


def finding_lines(log: AuditLog, name: str, age_days: int, audience: Audience | None,
                  accepted: dict[str, str] | None = None) -> list[str]:
    """終わった記録 1 本の判定の行 (= 1 行目が要約、 続く行が repo ごとの見つかった物)。

    accepted は、 この回の後に受け入れた repo → 受け入れた時刻の字 (= 新しい漏れから外す物)。
    """
    accepted = accepted or {}
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
    if audience is None:
        mine, others, note = log.findings, [], "; this tab's areas unknown, every repo shown"
    else:
        mine, others = split_for(log.findings, audience)
        note = f"; {len(others)} other repo(s) with findings that other tabs read out, not shown"
    if not mine:
        return [f"weekly_audit: nothing for this tab ({len(others)} repo(s) with findings that other tabs"
                f" read out; {name})"]
    fresh = [finding for finding in mine if finding.repo not in accepted]
    taken = [finding for finding in mine if finding.repo in accepted]
    taken_lines = [f"  accepted: {finding.repo} (since {accepted[finding.repo]})" for finding in taken]
    if not fresh:
        return [f"weekly_audit: accepted after the run in {len(taken)} repo(s) ({name}, {age_days}d ago{note};"
                " nothing to say first)"] + taken_lines
    lines = [f"weekly_audit: NEW in {len(fresh)} repo(s) ({name}, {age_days}d ago{note}) -> say it first in the briefing"]
    for finding in fresh:
        found = "; ".join(f"{place}: {words}" for place, words in finding.places)
        lines.append(f"  new: {finding.repo} -> {found}")
    return lines + taken_lines


def status_lines(logs: list[tuple[str, int, str, float]], audience: Audience | None, folder: str,
                 known: dict[str, tuple[float, str]] | None = None) -> list[str]:
    """記録を新しい順に並べた (名前, 古さの日数, 本文, 書いた時刻) と受け入れの記録から、 起動の検査に出す行。"""
    if not logs:
        return [f"weekly_audit: NO RUN (no log in {folder})"]
    lines = []
    finished = [entry for entry in logs if DONE.search(entry[2])]
    newest_name, newest_age, _, _ = logs[0]
    # 終わりの行の無い記録を 0 件と読むと、 一つ前の本物の結果が「clean」 に隠れる
    if not finished or finished[0][0] != newest_name:
        lines.append(f"weekly_audit: INCOMPLETE ({newest_name} has no end line, {newest_age}d old: running, or stopped"
                     " half way) -> the lines below are from the last finished run")
    if not finished:
        return lines + [f"weekly_audit: NO RUN (no finished log in {folder})"]
    name, age_days, text, written_at = finished[0]
    accepted = {repo: stamp for repo, (since, stamp) in (known or {}).items() if since > written_at}
    return lines + finding_lines(parse(text), name, age_days, audience, accepted)


def load_logs(folder: Path) -> list[tuple[str, int, str, float]]:
    """監査の記録を新しい順に (名前, 古さの日数, 本文, 書いた時刻)。 folder が無ければ空。"""
    now = time.time()
    paths = sorted(folder.glob(LOG_GLOB), key=lambda p: p.stat().st_mtime, reverse=True)
    return [(p.name, int((now - p.stat().st_mtime) // SECONDS_PER_DAY), p.read_text(encoding="utf-8", errors="replace"),
             p.stat().st_mtime) for p in paths]


def parse_known(text: str) -> tuple[str, float, str] | None:
    """受け入れの記録 1 本から (repo, 受け入れた時刻, その字)。 repo か時刻が読めなければ None。"""
    repo = since = None
    for line in text.splitlines():
        if repo is None and (head := KNOWN_REPO.match(line)):
            repo = head["repo"]
        elif since is None and (mark := KNOWN_SINCE.match(line)):
            since = mark["stamp"]
    if repo is None or since is None:
        return None
    try:
        return repo, datetime.fromisoformat(since.replace("Z", "+00:00")).timestamp(), since
    except ValueError:
        return None


def load_known(folder: Path | None) -> dict[str, tuple[float, str]]:
    """受け入れの記録の folder から repo → (受け入れた時刻, その字)。 folder が無い・読めない file は数えない。"""
    known: dict[str, tuple[float, str]] = {}
    if folder is None:
        return known
    for path in sorted(folder.glob(KNOWN_GLOB)):
        try:
            entry = parse_known(path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
        if entry is not None:
            known[entry[0]] = (entry[1], entry[2])
    return known


def load_reach(work_folder: Path | None = None) -> set[str] | None:
    """タブが読める境界の名前 (入口の番人の答え)。folder を渡すとその階層のタブとして訊く。訊けなければ None。"""
    if not HOOK.is_file():
        return None
    env = dict(os.environ)
    if work_folder is not None:
        env["GUARD_WORK_FOLDER"] = str(work_folder)
    try:
        done = subprocess.run([sys.executable, str(HOOK), "reach"], capture_output=True, text=True,
                              timeout=TIMEOUT_SEC, check=False, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return None
    return {line.strip() for line in done.stdout.splitlines() if line.strip()}


def load_audience() -> Audience | None:
    """環境と印の file と番人から、このタブが誰かを組む。このタブの境界を番人に訊けなければ None。"""
    reach = load_reach()
    if reach is None:
        return None
    tier = os.environ.get("AGENT_TIER") or NORMAL_TIER
    is_child = os.environ.get("AGENT_CHILD") == "1"
    tier_folder = AGENT_DIR if tier == NORMAL_TIER else AGENT_DIR / tier
    covered: set[str] = set()
    for marker in sorted(tier_files(AGENT_DIR, READER_MARKER)):
        reader_reach = load_reach(marker.parent)
        if reader_reach is None:
            # 係が読む境界を訊けない時は、境界のタブ全部に出す側へ倒す
            covered = set()
            break
        covered |= reader_reach
    return Audience(reach=reach, is_reader=not is_child and (tier_folder / READER_MARKER).is_file(),
                    is_normal=not is_child and tier == NORMAL_TIER, covered=covered)


def main(argv: list[str]) -> int:
    if len(argv) not in (1, 2):
        print("usage: audit_findings.py <folder of the audit logs> [<folder of the accepted findings>]", file=sys.stderr)
        return 2
    logs = load_logs(Path(argv[0]))
    audience = load_audience() if logs else None
    known = load_known(Path(argv[1]) if len(argv) == 2 else None)
    for line in status_lines(logs, audience, argv[0], known):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
