# Phase 09: Staging / QA

Project: CodexResume · Date: 2026-10-12 · Lead: main session · Status: see Exit Gate

## Objective
Run the release candidate the way a user would, on real and on staged data, with the app's folders redirected so the user's own settings and log are never touched.

## Key Activities
- [SEC] Ran the hostile-input test (13 checks) on the release candidate: all pass. Run on v1.0.0, it fails 4 checks, so it can detect the bugs it targets.
- [SEC] Re-ran the attacks from the audit against the real functions: planted session id, smart-quote folder name, here-string breakout, `\\server` folder, future-dated event, 30-day reset, broken config. All blocked.
- [PRIV] Staged the v1.0 → v1.1 migration with a token in the old log. Only the settings moved; the token is gone, an unknown file in the old folder is left alone, and a locked file is retried on the next start.
- [PRIV] Typed into a real console window through the helper's stdin, with é and ✓. The exact characters arrived, and the prompt was never on a command line.
- [UX] Ran the real app on staged data and took screenshots: stale state, warning, Details collapsed and open, normal OK state. Checked that X and `WM_CLOSE` hide to the tray, and that the Target list fills from the background scan.
- Rollback rehearsal (below).

## Deliverables
| Deliverable | Path / link | Priority it serves |
|---|---|---|
| QA results | this record | SEC / PRIV / UX |
| Rollback rehearsal | this record | SEC |
| Screenshot of the release UI | `docs/screenshot.png` | UX |

## QA results by journey
| Journey | Result | Evidence |
|---|---|---|
| See usage and reset times | Pass | Real data: 99% used, reset 7:11 PM, matching Codex's own message. Staged: "as of" shown on the bars when stale |
| Limit hit → auto-continue | Pass (staged) | Arming from real data; runner end-to-end with a stand-in program (argument list exact) |
| Type into the open window | Pass | Real console target; exact Unicode delivered through stdin |
| New-window resume via npm Codex | Pass (staged) | node + codex.js chosen; prompt with `" & % ^ !` arrives as one argument |
| Use a reset credit | Pass (staged) | Exit codes 1, 7 and 0 kept; script deleted afterwards; no browser opened without the user |
| Upgrade from v1.0 | Pass (staged) | See the migration item above |
| Close / minimise / Esc / F5 | Pass (X and `WM_CLOSE` run live); Esc with a list open checked in code only | |

## Rollback rehearsal (2026-10-12)
1. Downloaded the v1.0.0 release zip; its checksum matches the published `.sha256`.
2. Started from the state after a v1.1 upgrade: settings only in `%LOCALAPPDATA%`.
3. Copied `config.json` back to `%APPDATA%\CodexResume\` and ran v1.0.0. It started, showed its window, and kept the settings.

Rollback procedure for users (also in the release notes): exit the app, extract v1.0.0, and copy `%LOCALAPPDATA%\CodexResume\config.json` to `%APPDATA%\CodexResume\`.

## Tools/Best Practices
| Tool or standard | Used for | Priority |
|---|---|---|
| `tools/ci/Test-Hostile.ps1`; scratch test scripts t2, t4, t5, t8, t9, t10 | Regression and attack tests | SEC / PRIV |
| `subst` drive and redirected `APPDATA`/`LOCALAPPDATA`/`CODEX_HOME` | Staging without touching the user's data | PRIV |

## Reasoning

### 1. Security (paramount)
Every High finding has a test that exercises the real function, and the CI version of those tests is shown to fail on the old code. The remaining Low items are listed in the audit.

### 2. Privacy
Staging ran in isolated folders. A screenshot of the real UI was taken on a neutral drive letter so that no username or session id reaches the published README.

### 3. UI/UX
The main journeys were run on the real window. Screen-reader speech and 150–200% text were not tested on a device; that is recorded as not verified.

### Trade-offs
Some journeys were staged with stand-in programs, so as not to spend the user's Codex quota while they are rate-limited.

## Summary/Conclusions
The release candidate passes QA, and the rollback works. This record does not give the go-ahead: that is the user's decision.

## Exit Gate
- [ ] [SEC] Phase 7 gate passed for this build (see STATE.md)
- [x] [PRIV] Migration, deletion and retention checked on staged data
- [x] [UX] No open severity-1/2 usability or a11y issues (ux-reviewer, rc2)
- [x] Rollback rehearsed successfully
- [x] User gives explicit go: "fix everything then release" (2026-10-12), plus the release method chosen the same day: PR, merge, tag v1.1.0
