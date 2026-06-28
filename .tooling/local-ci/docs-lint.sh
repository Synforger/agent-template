#!/bin/bash
set -euo pipefail

# =============================================================================
# Local Dev Platform - Docs Freshness Checker (local)
# =============================================================================
# Scans all tracked Markdown files for machine-verifiable claims that go
# stale when code moves, and fails when a claim no longer matches reality.
#
# What it checks (the machine-verifiable staleness classes):
#   A. inline-code path references (`src/foo/bar.py`)  -> path must exist
#   B. `task <name>` references                        -> task must be listed
#   C. ASCII tree diagrams inside fenced code blocks   -> entries must exist
#      (a tree block is only verified when its root line resolves to an
#       existing directory; trees describing planned/future layouts are
#       skipped automatically because their root does not exist yet)
#
# What it cannot check: prose claims about behaviour. Those are covered by
# the review pass before integration, not by this script.
#
# False-positive escape hatch: add one substring or glob per line to
# `docs-check-ignore.txt` (next to this script). Any flagged reference whose
# path matches an ignore line is suppressed. Comments (#) and blanks allowed.
#
# Called from:
#   - `task docs:check`  (= the pre-integration docs sweep entry point)
# Deliberately NOT part of `task lint`: docs are reconciled once before
# integration, not on every dev-loop lint run.
#
# Exit code:
#   0 = clean
#   1 = stale reference found
#   2 = environment error (python3 missing)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 not found; docs-check requires it" >&2
    exit 2
fi

# Task names are resolved against `task --list-all` when the task binary is
# available; otherwise check B is skipped with a warning.
TASK_NAMES=""
if command -v task >/dev/null 2>&1; then
    TASK_NAMES="$(task --list-all --silent 2>/dev/null || true)"
else
    echo "warning: task binary not found; task-name check skipped" >&2
fi
export TASK_NAMES

python3 - "$@" <<'PYEOF'
import os, re, sys, fnmatch

ROOT = os.getcwd()
EXCLUDE_DIRS = {".git", "node_modules", "dist", "build", ".venv", "venv",
                "__pycache__", ".next", ".tooling"}
IGNORE_FILE = os.path.join(ROOT, ".tooling", "local-ci", "docs-check-ignore.txt")

ignores = []
if os.path.isfile(IGNORE_FILE):
    with open(IGNORE_FILE, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                ignores.append(line)

def is_ignored(path):
    return any(fnmatch.fnmatch(path, pat) or pat in path for pat in ignores)

def md_files():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIRS]
        for fn in filenames:
            if fn.endswith(".md"):
                yield os.path.join(dirpath, fn)

# A reference "looks like a repo path" when it has at least one slash and no
# placeholder / URL / variable syntax. Absolute and home paths are external
# by definition and skipped. Git branch names share the slash syntax but are
# not paths, so the common branch prefixes are skipped.
PATHISH = re.compile(r"^[A-Za-z0-9_.@-]+(/[A-Za-z0-9_.@-]+)+/?$")
# Tree roots may be a single segment ("docs/"), unlike inline references.
ROOTISH = re.compile(r"^[A-Za-z0-9_.@-]+(/[A-Za-z0-9_.@-]+)*/$")
BRANCH_PREFIX = re.compile(r"^(feature|fix|hotfix|release|chore|origin)/")

def path_exists(cand, md_dir):
    cand = cand.rstrip("/")
    return (os.path.exists(os.path.join(ROOT, cand))
            or os.path.exists(os.path.join(md_dir, cand)))

TREE_CHARS = ("├", "└", "│")
PLACEHOLDER = re.compile(r"[<>{}*$]|\.\.\.|…")

task_names = set(filter(None, os.environ.get("TASK_NAMES", "").splitlines()))
findings = []

for md in md_files():
    rel_md = os.path.relpath(md, ROOT)
    md_dir = os.path.dirname(md)
    with open(md, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()

    in_fence = False
    fence_block = []          # (lineno, text) of current fenced block
    for lineno, line in enumerate(lines, 1):
        if line.lstrip().startswith("```"):
            if in_fence:
                # ---- check C: tree diagrams in the closed block ----
                block = fence_block
                tree_idx = [i for i, (_, t) in enumerate(block)
                            if any(c in t for c in TREE_CHARS)]
                if tree_idx:
                    # root = nearest line above the first tree line that is
                    # a bare "dir/" path resolving to a real directory
                    root_dir = None
                    for i in range(tree_idx[0] - 1, -1, -1):
                        cand = block[i][1].strip()
                        if ROOTISH.match(cand):
                            if os.path.isdir(os.path.join(ROOT, cand)):
                                root_dir = cand
                            break
                    if root_dir:
                        stack = []  # (depth, name)
                        for i in tree_idx:
                            ln, text = block[i]
                            m = re.search(r"[├└]─* ?(\S+)", text)
                            if not m:
                                continue
                            depth = m.start()  # column of the branch char
                            name = m.group(1)
                            if PLACEHOLDER.search(name):
                                continue
                            stack = [(d, n) for d, n in stack if d < depth]
                            stack.append((depth, name.rstrip("/")))
                            full = os.path.join(root_dir,
                                                *[n for _, n in stack])
                            if not os.path.exists(os.path.join(ROOT, full)):
                                if not is_ignored(full):
                                    findings.append(
                                        f"{rel_md}:{ln}: tree entry not found:"
                                        f" {full}")
                fence_block = []
                in_fence = False
            else:
                in_fence = True
            continue
        if in_fence:
            fence_block.append((lineno, line))
            continue

        # ---- check A: inline-code path references ----
        for span in re.findall(r"`([^`\n]+)`", line):
            span = span.strip()
            if span.startswith(("http", "~", "/", "$")):
                continue
            if PLACEHOLDER.search(span):
                continue
            # B: `task xxx` reference
            m = re.match(r"^task\s+([A-Za-z0-9][A-Za-z0-9:_-]*)$", span)
            if m:
                if task_names and m.group(1) not in task_names:
                    if not is_ignored(span):
                        findings.append(
                            f"{rel_md}:{lineno}: unknown task: {span}")
                continue
            if not PATHISH.match(span) or BRANCH_PREFIX.match(span):
                continue
            if not path_exists(span, md_dir) and not is_ignored(span):
                findings.append(
                    f"{rel_md}:{lineno}: path not found: {span}")

if findings:
    print("\n".join(findings))
    print(f"\ndocs-check: {len(findings)} stale reference(s)."
          " Fix the doc or add an exception to"
          " .tooling/local-ci/docs-check-ignore.txt")
    sys.exit(1)
print("docs-check: clean")
PYEOF
