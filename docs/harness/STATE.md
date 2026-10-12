# Harness State: CodexResume

Current phase: 10 Deployment (v1.1.0)
Last updated: 2026-10-12

| # | Phase | Gate | Record | Open findings |
|---|---|---|---|---|
| 1 | Discovery & Planning | retroactive (2026-10-12) | `01-discovery-planning.md` | Lawful-basis assumption (personal use) for the owner to confirm |
| 2 | Architecture & Design | retroactive (2026-10-12) | `02-architecture-design.md` | none |
| 3 | Scaffold & CI Setup | see `03-scaffold-ci.md` | `03-scaffold-ci.md`, `ci-gates.md` | Completed by the v1.1.0 PR: CI run on GitHub, branch protection, SECURITY.md |
| 4 | Backend Development | retroactive, mapped (2026-10-12) | `04-06-not-applicable.md` | Carried into 7 |
| 5 | Frontend Development | retroactive, mapped (2026-10-12) | `04-06-not-applicable.md` | Carried into 7 |
| 6 | API Integration | retroactive, mapped (2026-10-12) | `04-06-not-applicable.md` | Carried into 7 |
| 7 | Security & Quality Gates | passed (2026-10-12) | `07-security-quality-gates.md`, `../security/audit-2026-10-12.md` | Accepted Lows: SEC-09, synchronous scan at resume, parent-folder check, PRIV-15 leftover; UX severity-4 notes |
| 8 | Performance & Optimization | passed (2026-10-12) | `08-performance.md` | Budgets not enforced in CI (noisy runners) |
| 9 | Staging / QA | passed (2026-10-12) | `09-staging-qa.md` | Screen reader and 150–200% text not tested on a device |
| 10 | Deployment | in progress | `10-deployment.md` | |
| 11 | Monitor & Iterate | pending | | |

Gate values: pending, passed (date), failed (date), retroactive (date).

## Accepted risks
| Finding | Accepted by | Date | Expires | Logged in threat register |
|---|---|---|---|---|
| R7 `-ExecutionPolicy Bypass` in the launcher | pending the owner's explicit acceptance | | | R7 |
| SEC-09 Codex processes matched by name (same Windows session only) | recommended Low by security-reviewer; pending the owner | 2026-10-12 | 2027-04-12 | R2 |

## Next action
Publish v1.1.0 (PR → CI green → merge → tag → release), then start phase 11.
