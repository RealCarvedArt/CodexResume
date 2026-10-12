# Phase 07: Security & Quality Gates

Project: CodexResume · Date: 2026-10-12 · Lead: main session; reviews by security-reviewer, privacy-reviewer, ux-reviewer · Status: gate passed (for v1.1.0)

## Objective
Run an independent audit of the app before release. The reported bug (status stuck at "23% left" and "OK" after the limit was hit) is a failure of the app's core promise: acting at the right time on the user's behalf.

## Key Activities
- [SEC] Ran gitleaks and PSScriptAnalyzer. Ran three rounds of independent review with exploit proofs. Fixed every High and Medium, and most Lows. Fixed the two host-permission Highs (with backups).
- [PRIV] Traced every data flow. Fixed PRIV-01 to PRIV-17, with PRIV-15 partly fixed. Rewrote the data inventory and added a data-flow document.
- [UX] Ran a WCAG 2.2 AA review over two rounds. Fixed UX-01 to UX-14 and UX-N1 to UX-N5, and checked them in real UI renders.
- Added a CI hostile-input test. It is shown to fail on v1.0.0.

## Deliverables
| Deliverable | Path / link | Priority it serves |
|---|---|---|
| Audit (all rounds, final statuses) | `docs/security/audit-2026-10-12.md` | SEC / PRIV / UX |
| Threat register | `docs/security/threat-register.md` | SEC |
| Data inventory and flow | `docs/privacy/data-inventory.md`, `docs/privacy/data-flow.md` | PRIV |
| CI hostile-input test | `tools/ci/Test-Hostile.ps1` | SEC |
| Host permission backups and rollback | Kept on the developer's PC, outside the repo | SEC |

## Tools/Best Practices
| Tool or standard | Used for | Priority |
|---|---|---|
| gitleaks 8.30.1, PSScriptAnalyzer 1.25.0 | Scanning | SEC |
| Exploit proofs on planted inputs | Confirming findings | SEC |
| OWASP ASVS 4.0 L1 (V5, V7, V12, V14) | Checklist | SEC |
| WCAG 2.2 AA, contrast computation | Accessibility | UX |

## Reasoning

### 1. Security (paramount)
- **Thresholds:** any open High fails the gate.
- **Code Highs:** the two Highs in the code (SEC-01, SEC-02) came from generating a PowerShell script out of untrusted values. They were fixed by design rather than by escaping: the runner is now fixed text and the values travel only as data.
- **Host Highs:** the two host Highs let other accounts plant the inputs those bugs needed. They were fixed with backups and a tested rollback, then confirmed by a full rescan. Every tool on PATH still runs.
- **Verification:** each fix has a test that exercises the real function, and the CI version is shown to catch the old code.
- **Suppressions:** none.

### 2. Privacy
- **Regressions caught:** reviews caught two privacy regressions introduced during the work:
  - the transcript cache (PRIV-01);
  - the upgrade carrying an old log forward (PRIV-12).
- **Both fixed and tested:** the log now never holds the prompt, the reset command or the profile path, and the prompt never sits on a helper's command line.
- **Stays with the owner:** the lawful-basis question.

### 3. UI/UX
The reported bug was a UX failure first: a confident green "OK" over 5-hour-old data. The status now:
- ranks states by urgency;
- shows how old the data is, and says "Stale" in words, not just in color;
- keeps setup warnings on screen until they are fixed;
- never hides the rate-limit countdown.

Accessibility issues block the gate; only severity-4 notes remain.

### Trade-offs
- **Privacy over speed:** reading command lines only for Codex processes made the process scan slower. The scan was moved off the UI thread instead of reading every process's command line (privacy > UX).
- **Upgrade loses the v1.0 log:** the old log is deleted rather than migrated, because it can contain tokens (privacy > keeping history).

## Summary/Conclusions
- **Passed:** all three reviewers pass the release candidate. The CI test (17 checks) passes on the final code.
- **Left open:** accepted Lows (SEC-09; the one-off scan at resume time; the parent-folder check; R7) and severity-4 UX notes.
- **Next:** phase 3's remaining items (CI on GitHub, branch protection) are handled during the release.

## Exit Gate
- [x] [SEC] Zero open critical/high findings (security-reviewer, rc2: "Nothing Medium or above is still open")
- [x] [SEC] ASVS target items verified: V5, V7, V12, V14 pass for L1. DAST is not applicable (no network service)
- [x] [PRIV] PII and inventory checks green (privacy-reviewer, rc2: PASS)
- [x] [UX] a11y gate green (ux-reviewer, rc2: PASS); visual check by real renders
- [x] Suppression log reviewed by `security-reviewer`: none

Verified by: security-reviewer 2026-10-12, privacy-reviewer 2026-10-12, ux-reviewer 2026-10-12
