# Phases 04–06: Backend, Frontend, API Integration (retroactive, mapped)

Project: CodexResume · Date: 2026-10-12 · Lead: main session · Status: retroactive

## Objective
CodexResume is one PowerShell process with no server, no API, and no web frontend. This record maps each phase to the part of the app that plays that role, so its gate items are checked instead of skipped.

## Key Activities
| Phase | Equivalent in CodexResume | Where it is checked |
|---|---|---|
| 4 Backend | Reading the Codex logs (`Get-RateLimits`, `Find-LimitError`, `Get-SessionFiles`) and building commands (`Start-Resume`, `Use-ResetCommand`) | Phase 7 security audit (injection, error handling); the stale-data fix was tested on real data |
| 5 Frontend | The WinForms window and tray icon | Phase 7 UX review (UX-01 to UX-14) |
| 6 Integration | Three outside dependencies: the Codex JSONL file format, starting `codex` processes, and typing into Codex consoles | Phase 7 security audit (keystroke target, PATH resolution) |

- [SEC] No authentication or authorization endpoints exist, so the authorization and IDOR (insecure direct object reference) tests are not applicable. Input validation for strings read from files is audited in phase 7.
- [PRIV] There are no deletion or export endpoints. The user's data is their own files on their own machine. The app's own log retention is reviewed in phase 7.
- [UX] The error model is plain-language status text (verified by `ux-reviewer`).

## Deliverables
| Deliverable | Path / link | Priority it serves |
|---|---|---|
| Stale-session fix (working tree) | `CodexResume.ps1`: `Read-Tail`, `Get-SessionFiles`, `Get-RateLimits`, `Find-LimitError` | SEC / UX |
| Test against real data | below | SEC / UX |

**Test of the fix (2026-10-12, Windows PowerShell 5.1, live Codex data on the developer's PC):**

| Version | 5h used | Limit error seen | Waits until |
|---|---|---|---|
| Original | 77% | no | nothing; shows "OK" |
| Fixed | 99% | 14:37:47 | 19:11 (the same time Codex's own error gives) |

Root cause: Windows does not update the LastWriteTime of a session file while Codex keeps it open. The main thread's file showed 10/11 18:39 while it was still being written on 10/12. The app's "newest 5 files by LastWriteTime" rule skipped that file.

## Tools/Best Practices
| Tool or standard | Used for | Priority |
|---|---|---|
| Real-data A/B run (old vs. new functions) | Testing the fix | SEC / UX |

## Reasoning

### 1. Security (paramount)
Mapping these phases, rather than marking them N/A, keeps their security items (input handling, safe process launch, integration failure modes) in scope for the phase 7 audit. The integration with the Codex file format is fragile: the format is undocumented and the file timestamps are unreliable. The fix removes trust in file timestamps and uses the timestamps inside the events.

### 2. Privacy
The fix adds an in-memory cache of file tails, up to 512 KB of transcript text per recent file. It is never written to disk. Its scope is assessed in the phase 7 privacy review.

### 3. UI/UX
The fix makes the numbers correct but does not tell the user when the data is old (UX-01). That is a separate change, tracked in phase 7.

### Trade-offs
The fix reads more files: about 4.4 s on the first scan, then about 0.14 s per refresh thanks to the cache. Accuracy, which drives the security-relevant behavior of when to resume, was chosen over startup speed.

## Summary/Conclusions
These phases have no separate deliverables beyond the stale-data fix. Their gate items carry into the phase 7 audit.

## Exit Gate
- [x] Mapped; gate items carried to phase 7
