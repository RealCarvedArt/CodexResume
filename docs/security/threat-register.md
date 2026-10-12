# Threat Register: CodexResume

Created 2026-10-12 (retroactive, harness phase 1). Owner of every row: repo owner (RealCarvedArt) until reassigned.

## Assets
| ID | Asset | Why it matters |
|---|---|---|
| A1 | User's machine and account (runs Codex with the user's rights) | The app launches processes and types keystrokes as the user |
| A2 | Codex session transcripts (`<CODEX_HOME>\sessions\**\*.jsonl`) | Contain prompts, code, paths, possibly secrets; the app reads them |
| A3 | App config `%APPDATA%\CodexResume\config.json` | Holds command templates and `UseResetCommand`, which the app executes |
| A4 | App log `%APPDATA%\CodexResume\*.log` | Records resume commands, folders, events |
| A5 | Codex usage window / reset credits | Wasting a banked reset or resuming at the wrong time costs the user money/time |

## Actors
| ID | Actor | Capability |
|---|---|---|
| T1 | Malicious content inside a session file (e.g. text a model or repo wrote) | Controls strings the app parses (cwd, timestamps, error text) |
| T2 | Other local process running as the same user | Can edit config, plant `codex.cmd` on PATH, write session files |
| T3 | Another local user / low-privilege process | Limited to what file ACLs allow |
| T4 | Accidental: stale or malformed data, wrong window focused | Causes wrong-time resume, keystrokes to the wrong process |

## Risks
| ID | Risk | Actors | Status | Notes / mitigation |
|---|---|---|---|---|
| R1 | Command/argument injection from templates, prompt, session id, or a cwd read from a session file | T1, T2 | **mitigated v1.1** (SEC-01/02/03, NEW-04) | Fixed runner text plus a data file; UUID-only session id; node instead of cmd.exe; the .cmd fallback refuses metacharacters; bare template programs resolved from PATH |
| R2 | Keystrokes injected into the wrong console or process | T4 | mitigated v1.1; Low accepted (SEC-09) | Only your own Windows session; PID plus start time |
| R3 | PATH hijack when resolving `codex`, `node` or system programs | T2, T3 | **mitigated v1.1** (SEC-06/07, ENV-02) | Known install paths first; full paths for system programs; node from PATH refused if others can write its folder; this PC's PATH folders tightened |
| R4 | Stale data: app shows "OK" or arms at the wrong time | T4 | **mitigated v1.1** | Ranks by event time inside the files; stale state shown; future-dated events and resets past the window length ignored |
| R5 | Transcript content or secrets copied into the log, UI or command lines | T1, T4 | mitigated v1.1; Low PRIV-15 | Derived-only cache; log redaction; prompt on stdin; reset command in a short-lived script |
| R6 | DoS: huge or malformed session files freeze the UI thread | T1, T4 | **mitigated v1.1** (SEC-13, NEW-01) | Bounded reads at both ends of a file; process scan in the background with a WMI timeout |
| R7 | Launcher uses `-ExecutionPolicy Bypass` | T2 | accepted by design, **pending owner acceptance** | Standard for unsigned local scripts; does not raise privilege |
| R8 | Other local accounts write Codex data or PATH folders (the Codex home folder, several tool folders on PATH) | T3 | **mitigated 2026-10-12** (ENV-01/02) | Permissions tightened on the developer's PC, with backups; the app warns if the sessions or Codex folder can be written by others |

Same-user actors (T2) can already run code as the user, so risks that need T2 are low severity unless they bypass a boundary the user relies on.
