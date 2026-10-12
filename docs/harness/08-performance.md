# Phase 08: Performance & Optimization

Project: CodexResume · Date: 2026-10-12 · Lead: main session · Status: gate passed

## Objective
Keep the window responsive and the app light, with no weakening of the v1.1 security and privacy controls.

## Key Activities
- [UX] Measured the scan, the process listing, and memory on real data (23 session files, 602 processes) under Windows PowerShell 5.1, against v1.0.0 as a baseline.
- [PRIV] Found a regression: the privacy fix PRIV-06 had made the process listing slower and blocking. Fixed it without dropping that privacy control.
- [SEC] Checked that caching cannot serve stale or planted data. The cache key is the file length plus a hash of the last 4 KB, and future-dated events are ignored.

## Deliverables
| Deliverable | Path / link | Priority it serves |
|---|---|---|
| Budgets and measurements | this record | UX |
| Background process scan | `CodexResume.ps1` (`Update-CodexScan`, `Receive-CodexScan`) | UX / PRIV |

## Budgets and measurements (median of 4 runs after one warm-up; one machine)
| What | Budget | v1.0.0 | v1.1 first build | v1.1 release |
|---|---|---|---|---|
| First scan of session files (startup) | ≤ 3 s, with the window shown during it | 0.22 s (5 files, often the wrong ones) | 1.1 s | 1.1 s; the window shows "Reading Codex logs..." |
| Regular scan, every 15 s | ≤ 100 ms on the UI thread | 26 ms | 26 ms | 25 ms |
| Process listing, every 15 s | ≤ 100 ms on the UI thread | 554–700 ms, blocking | 2,888 ms, blocking | **0 ms on the UI thread** (about 1.3 s in the background) |
| Managed memory after a scan | ≤ 50 MB | 11.3 MB | 13.0 MB | 13.0 MB |

## Tools/Best Practices
| Tool or standard | Used for | Priority |
|---|---|---|
| Stopwatch timing harness (`perf.ps1`, `perf2.ps1`, scratchpad) | Measurement | UX |
| PowerShell runspace via `BeginInvoke` | Moving the scan off the UI thread | UX |

## Reasoning

### 1. Security (paramount)
- **Cache:** faster scans come from the summary cache. A changed file always changes its key, and the cache holds no text that could be served without checking.
- **Background scan:** it runs the same code with the same filters. It finds the Codex window to target; a resume still scans directly, so it acts on current data.

### 2. Privacy
- **Why it got slower:** reading command lines only for Codex processes needs two WMI queries. That cost is fixed, about 0.5–0.7 s each, however the query is filtered.
- **What was rejected:** going back to one query that reads every process's command line. That would undo PRIV-06 just for speed.
- **Decision:** privacy ranks above UX, so the queries stay. The UX problem is solved by moving them off the UI thread.

### 3. UI/UX
- **Freeze removed:** v1.0 froze the window for about 0.6 s every 15 seconds; v1.1 no longer freezes at all.
- **Startup:** the first scan is slower because it reads 23 files instead of 5, which is the stale-data fix. It now runs after the window appears, with a visible loading state.

### Trade-offs
Privacy (fewer command lines read) cost CPU time in the background, but no visible responsiveness.

## Summary/Conclusions
Every budget is met. The PRIV-06 regression was found by measuring, and fixed without undoing the privacy control.

## Exit Gate
- [x] [SEC] Caching cannot serve stale or planted data (tested: same-length rewrite, future-dated event)
- [x] [PRIV] No new data retained by caches (derived values only)
- [x] [UX] Budgets met on the target machine
- [ ] Budgets enforced in CI: not done; timing on shared CI runners is too noisy to gate on. Recorded here instead
