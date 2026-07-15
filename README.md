# agent-template

> 🇯🇵 日本語版: [README.ja.md](README.ja.md)

> A **scaffold for long-lived agents** running on Claude Code / the Anthropic SDK. Machinery, structural templates, and a revision culture live in one base; each derived agent is spun up with `init-new-agent.sh` and shares improvements through two-way sync.

## Design ideas

- **An agent is persona + its own projects + machinery.** The machinery is factored into this base; persona and projects stay in the derived repo — so machinery improvements are shared by every agent.
- **A continuous self-reinforcement loop.** Machinery quality is swept mechanically (`docs-check.sh` / `detect-duplicates.py` / `detect-stale-rules.sh`); the agent only reacts to the output, spending no context on re-derivation.
- **Built to be published.** Personal and workplace identifiers are blocked mechanically at the commit / push boundary by the machine-resident guard-dispatcher (a separate repo).
- **Minimal constraints on derivations.** The base owns only the machinery, the required rule file, and the structural templates; everything else is the derivation's free territory.

## Repository layout

```
agent-template/
├── LICENSE                            # Apache 2.0
├── README.md / README.ja.md           # this file + Japanese version
├── .gitignore                         # the template repo's own gitignore
├── .githooks/pre-commit               # branch guard (anon scanning is delegated to guard-dispatcher)
├── .tooling/local-ci/                 # the template repo's own docs lint
│   ├── docs-check.sh
│   ├── docs-check-ignore.txt
│   └── setup-lib.sh
├── .tooling/                          # template operation scripts
│   ├── init-new-agent.sh              # spin up a derivation
│   ├── sync-from-base.sh              # base → derivation (pull down)
│   └── promote-to-base.sh             # derivation → base (promote up)
├── .synced-paths.txt                  # the paths shipped down to derivations
└── src/                               # ★ what a derived agent receives
    ├── CLAUDE.template.md             # becomes the derivation's CLAUDE.md (persona)
    ├── .gitignore.template            # expands to the derivation's .gitignore
    ├── .tooling/                      # machinery scripts (the truth that runs in derivations)
    │   ├── docs-check.sh              # multi-axis docs verification
    │   ├── detect-duplicates.py       # section-level duplicate detection
    │   ├── detect-stale-rules.sh      # 7-day-stale rule detection
    │   ├── extract-artifact-index.sh  # for a SessionEnd hook
    │   ├── first-prompt-pull.sh       # multi-machine sync (optional)
    │   ├── precommit-conflict-check.sh
    │   ├── setup-hooks.sh             # hook install
    │   ├── startup-status.sh          # run at session boot
    │   └── _README.md
    ├── rules/
    │   ├── always.md                  # ★ required: capacity management + revision culture + the loop
    │   └── lazy/
    │       ├── _template.md           # scaffold for new lazy rules
    │       └── automation-machinery.md
    ├── projects/_template-project/    # project scaffold (nested subprojects included)
    ├── journal/                       # session log structure
    ├── todos/                         # cross-cutting tasks
    ├── plans/                         # cross-cutting plans
    ├── research/                      # cross-cutting research
    └── profile/                       # user profile structure
        └── profile-core.template.md
```

Everything under `src/` is the derived agent's content; everything at the root operates the template itself. `init-new-agent.sh` rsyncs `src/` into the derivation root and expands every `*.template` into a real file.

## Spinning up a derivation

```bash
git clone git@github.com:synforger/agent-template.git
cd agent-template
./.tooling/init-new-agent.sh ~/path/to/<new-agent>
```

Then, inside the derivation:

1. Edit `CLAUDE.md` (persona / user relationship / agent constellation)
2. Edit `profile/profile-core.md` (your primary user's core + judgement axes)
3. Add your private vocabulary to the machine-side guard-dispatcher word list (`~/.config/anon-words/`)
4. Add derivation-specific rules to `rules/always.md` (git conventions, prohibitions, and so on)
5. `git remote add origin <your-repo>` and push

## Two-way sync

### Base → derivation (pull down)

When a derivation wants the latest base:

```bash
cd ~/path/to/<your-agent>
./.tooling/sync-from-base.sh
```

Only the paths listed in `.synced-paths.txt` are overwritten with the base version; derivation-specific files are never touched. Review with `git diff`, then commit.

### Derivation → base (promote up)

When a derivation discovers a machinery improvement worth sharing:

```bash
cd ~/path/to/<your-agent>
./.tooling/promote-to-base.sh "feat: add a new docs-check step"
```

This cuts a feature branch on the base, pushes it, and the change lands via a pull request. Files outside `.synced-paths.txt` are rejected.

### Conflict policy

- **Always run `sync-from-base.sh` before promoting** (resolve conflicts on the derivation side).
- If a derivation wants to override a base file permanently, the policy is the derivation's choice: keep a differently-named local file, propose the change upstream via PR, or edit its local `.synced-paths.txt` to exclude the path.

## Required rules (do not delete in derivations)

The template ships only these; below this floor the machinery stops working.

- `rules/always.md § meta` — capacity management, revision culture, and the self-reinforcement loop (single-file form)
- `rules/lazy/_template.md` — scaffold for new lazy rules
- `rules/lazy/automation-machinery.md` — operational truth for `.tooling/*`

Derivation-specific rules (git conventions, prohibitions, subagent discipline, anything else) go freely into the derivation's `rules/always.md` / `rules/lazy/*.md`; rule content is not synced.

## Machinery core

### `docs-check.sh`

Run at session end; any FAIL must be fixed within the same session. Verification axes (the script's own step output is the truth):

1. frontmatter
2. capacity (self-declared per file)
3. index consistency (`_README.md` ↔ sibling .md files)
4. dead links
5. leftover placeholders (unfilled scaffolds)
6. dynamic-search-pattern residue
7. project folder consistency
8. synced-paths consistency (derivations only, diffed against base)

### `detect-duplicates.py`

Compares every rule at H2/H3 section granularity via longest-common-substring and reports consolidation candidates for split truths. Pairs judged as intentional shared references go into `.tooling/duplicates-allowlist.txt` for permanent suppression — no re-judging every session.

### `detect-stale-rules.sh`

No update for 7 days = retirement candidate. Files with frontmatter `stable: true` and `_README.md` files are excluded mechanically, so only genuine dead-rule candidates are reported.

### The self-extension loop

Observe the same weakness twice, mechanise it immediately:

1. Assess whether it is machine-detectable (grep / awk / python)
2. If so, add a step to `docs-check.sh` or sharpen a `detect-*` script
3. If not, write it into `rules/always.md § meta` as discipline

The bar for "add a detector" is kept deliberately low — quality holds because the agent only has to react to machine output.

## Anonymity (for public publication)

The base ships with zero concrete agent names or operator identifiers. Scanning itself lives in the machine-resident guard-dispatcher (a separate repo) and is enforced for every repo at the commit / push boundary; the word list lives in machine config (`~/.config/anon-words/`) and is never committed.

## License

[Apache License 2.0](./LICENSE)

## Related

- [Synforger](https://github.com/synforger) — the organisation this template ships from
- Claude Code (Anthropic) — the harness this scaffold targets
