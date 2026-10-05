#!/usr/bin/env python3
"""Check journal filename / frontmatter / tier consistency in one pass.

Emits one violation per line on stdout; the caller turns each into a `fail`.
Written as a single pass because the shell version spawned half a dozen
processes per journal file, which dominated the whole docs-check runtime once
the journal count grew into the hundreds.

Rules (unchanged from the shell original):
  - filename `session-NN.md` must match frontmatter `session:`
  - the date folder must match frontmatter `date:`
  - a project/subproject-tier journal must not carry `mode: normal`
  - a normal-tier journal must not carry any other `mode:`
"""

from __future__ import annotations

import pathlib
import re
import sys

FNAME_RE = re.compile(r"^session-0*(\d+)\.md$")
SESSION_RE = re.compile(r'^session: *"?0*(\d+)"?', re.MULTILINE)
DATE_RE = re.compile(r'^date: *"?(\d{4}-\d{2}-\d{2})"?', re.MULTILINE)
MODE_RE = re.compile(r'^mode: *"?([^"\n]*)"?$', re.MULTILINE)


def frontmatter(text: str) -> str:
    if not text.startswith("---"):
        return ""
    end = text.find("\n---", 3)
    return text[:end] if end != -1 else ""


def main() -> int:
    root = pathlib.Path(".")
    violations = 0
    for path in sorted(root.glob("**/journal/**/session-*.md")):
        if ".git" in path.parts:
            continue
        m = FNAME_RE.match(path.name)
        if not m:
            continue
        nn = m.group(1)
        rel = f"./{path.as_posix()}"
        try:
            fm = frontmatter(path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue

        m_session = SESSION_RE.search(fm)
        if m_session and m_session.group(1) != nn:
            print(f"{rel}: filename NN ({nn}) does not match "
                  f"frontmatter session ({m_session.group(1)})")
            violations += 1

        m_date = DATE_RE.search(fm)
        dir_date = path.parent.name
        if m_date and m_date.group(1) != dir_date:
            print(f"{rel}: date folder ({dir_date}) does not match "
                  f"frontmatter date ({m_date.group(1)})")
            violations += 1

        m_mode = MODE_RE.search(fm)
        mode = m_mode.group(1) if m_mode else ""
        in_project = path.parts and path.parts[0] == "projects"
        if in_project and mode == "normal":
            print(f"{rel}: project-tier journal carries mode: normal (tier mix-up)")
            violations += 1
        elif not in_project and mode and mode != "normal":
            print(f"{rel}: normal-tier journal carries mode: {mode} "
                  "(tier self-containment violation)")
            violations += 1

    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
