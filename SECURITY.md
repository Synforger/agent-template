# Security Policy

## Reporting a vulnerability

Use **GitHub Security Advisories private vulnerability reporting** to
disclose security issues responsibly:

1. Open https://github.com/Synforger/agent-template/security/advisories/new
2. Fill in the affected version + reproduction + impact estimate
3. Maintainer will acknowledge within 7 days

Do not file public Issues or PRs for security-relevant findings. Public
discussion only after a fix has shipped and end users have had time to
update.

If GitHub access is unavailable, reach `@Synforger` via the
contact channel listed in the repo's README.

## Supported versions

| version | supported |
|---|---|
| main (= rolling release) | ✅ active |
| tagged releases (= v0.x) | ⚠️ best effort (= no formal LTS) |
| forks / mirrors | ❌ out of scope |

This is a personal project; there is no enterprise LTS. Security fixes
land on `main` and the next tagged release. Pin to a specific tag if
your environment requires reproducibility.

## Threat model

Template scaffold whose shell / Python scripts run locally on the
deriving operator's machine with that operator's privileges — no
network service, no secret storage. Main threats: supply-chain
tampering of the scripts between clone and first run (mitigated by
pinning a tag), and unsafe handling of operator-provided paths inside
the tooling scripts.

## In scope

- Authentication / authorization flaws (= when applicable)
- Sensitive data leakage (= secrets in logs / errors / responses)
- Path traversal / SSRF / SQLi / XSS / RCE in code paths the
  template's own scripts execute
- Personal-identifier leakage surfaced by `task audit:deep`

## Out of scope

- Issues in upstream dependencies that are already disclosed
  (= report those upstream; this repo will pick up the fix on next bump)
- Best-practice nudges with no concrete exploit path
- Vulnerabilities only reproducible with privileged local access
  (= `sudo` / root) — those imply the threat model has already failed
- Cosmetic / DoS-via-resource-exhaustion in dev-mode tools

## Audit log

The maintainer runs `task audit:deep` (= 11-source deep anonymity
audit via guard-dispatcher) at least every 6 months. Findings + resolutions are tracked here:

| date | findings | resolution |
|---|---|---|
| 2026-07-05 | (initial) | placeholders filled, no findings |

## Upstream redirect

When a vulnerability originates in a transitive dependency, the
disclosure goes to the upstream maintainer first. This repo only
contains the integration layer; the offending logic lives elsewhere
and should be patched there.
