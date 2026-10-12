# Phase 03: Scaffold & CI Setup (retroactive)

Project: CodexResume · Date: 2026-10-12 · Lead: main session · Status: gate failed (items need GitHub-side action)

## Objective
Put blocking security checks on every change. The repo had no CI, no `SECURITY.md`, and no branch protection. This phase adds the parts that can live in the repo, and lists the parts that need the repo owner to act on GitHub.

## Key Activities
- [SEC] Added `.github/workflows/ci.yml`. It has two jobs: a parse check plus PSScriptAnalyzer with a security rule set, and a gitleaks scan of the full history. Token permissions are `contents: read`, `persist-credentials: false`, and actions are pinned by SHA.
- [SEC] Ran a full-history secret scan: clean (2 commits, gitleaks 8.30.1).
- [SEC] Tested both gates against planted violations (`docs/harness/ci-gates.md`).
- [PRIV] There is no seed data or fixture data in the repo. The data-flow tests used the developer's own local Codex files, which never left the machine and were not committed.
- [UX] An automated a11y gate is not available for WinForms; accessibility is checked manually in phase 7.

## Deliverables
| Deliverable | Path / link | Priority it serves |
|---|---|---|
| CI workflow | `.github/workflows/ci.yml` | SEC |
| Lint gate script | `tools/ci/Invoke-Lint.ps1` | SEC |
| Gate list and seeded tests | `docs/harness/ci-gates.md` | SEC |

## Tools/Best Practices
| Tool or standard | Used for | Priority |
|---|---|---|
| GitHub Actions, SHA-pinned, least-privilege token | CI | SEC |
| PSScriptAnalyzer 1.25.0 | SAST for PowerShell | SEC |
| gitleaks 8.30.1 (checksum-verified binary, no third-party action) | Secret scanning | SEC |

## Reasoning

### 1. Security (paramount)
- **Lint gate:** the security rules block the build, while style rules only warn. The 14 empty `catch` blocks and naming warnings are real but not exploitable, so making them block would just teach people to ignore red builds.
- **gitleaks:** the binary is downloaded and its SHA-256 checked, instead of using `gitleaks-action`. That avoids a third-party action running with repo access.
- **Dependency scanning and SBOM:** not applicable, because the script has no dependencies beyond Windows and .NET.
- **Still missing:**
  - Branch protection and a `SECURITY.md` (disclosure contact) need the owner's decision on GitHub.
  - The workflow has not yet run on GitHub's runners.

### 2. Privacy
Mostly indirect. The scaffold has no fixtures. The secret scan also protects personal data: a pasted transcript or log containing a token would be caught before it is published.

### 3. UI/UX
There is no automated accessibility checker for WinForms, so accessibility relies on a manual reviewer for every audit. That is weaker than an automated gate, and is recorded as such.

### Trade-offs
Style warnings are advisory rather than blocking. This trades some code quality for a CI signal people trust. Security rules stay blocking.

## Summary/Conclusions
The CI gates exist and were tested locally against planted violations, and the history is clean. The gate fails until three things happen: the workflow runs on GitHub, branch protection is enabled, and `SECURITY.md` is added. All three need the repo owner.

## Exit Gate
- [~] [SEC] All security CI jobs run and fail the build on a seeded violation: tested locally only; not yet run on GitHub
- [x] [SEC] No secrets in history (full-history scan clean)
- [x] [PRIV] Seed data is synthetic (none exists); PII logging check: manual (phase 7 privacy review)
- [ ] [UX] a11y lint and axe step run in CI: not applicable to WinForms; manual gate instead
- [ ] Branch protection active: owner action on GitHub
