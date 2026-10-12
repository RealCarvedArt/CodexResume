# Data Inventory: CodexResume v1.1

Updated 2026-10-12 to match v1.1 (traced from the code by `privacy-reviewer`, then re-reviewed). Personal-use software: the user processes their own data on their own machine, and nothing is sent to the author.

Lawful basis is marked "not applicable" on the assumption of personal or household use. **That is a legal judgement the owner must confirm**, especially if the app is given to employees or other organisations. "User" below also means any process running as that user.

| # | Data | Source | Purpose | Stored / shown | Retention | Readable by |
|---|---|---|---|---|---|---|
| D1 | Transcript tails: last 512 KB of each session file touched in the last 8 days (at least 5 files), plus at most 1 MB from the start of a file | `<CODEX_HOME>\sessions\**\*.jsonl` | Extract usage numbers, timestamps, limit errors, cwd, session id | Process memory, only while one file is being parsed | Freed after each parse | User |
| D2 | Last 256 KB of `codex-tui.log` | `<CODEX_HOME>\log` | Timestamps of limit errors | Memory, briefly | Freed after each parse | User |
| D3 | Derived per-file summary: size + hash key, usage %, reset times, plan, credits, limit-error times, cwd | D1 | Status, arming the resume | `SessionCache` in memory | Dropped when the file leaves the scan set; gone when the app exits | User |
| D4 | Session cwd (may name the user and project) | D3 | Folder to resume in | Window (Folder box, Details); runner data file. The log and balloons get the folder name only | Data file: deleted on read, or after 2 min | User |
| D5 | Session id (UUID only, otherwise `--last`) | File name or `session_meta` | `codex resume <id>` | Window (Details); runner data file; Codex's command line | Transient | User; process auditing |
| D6 | Process list: name, PID, parent PID, start time, Windows session. Command line for `codex*` processes only | WMI `Win32_Process`, every 15 s, on a background thread | Find open Codex windows | Memory; the chosen PID and start time go to the config | Until the next scan; config until changed | User |
| D7 | Prompt text (default "continue") | Config | Text typed or sent to Codex | Config; typing helper's stdin; runner data file; Codex's command line in the new-window modes. The log gets its length only; balloons never show it | Config until changed; the rest are transient | User; process auditing (new-window modes only) |
| D8 | `UseResetCommand` (may contain a token) | Config | Redeem a reset credit | Config; `reset-command.ps1` while it runs. Never logged and never on a command line; PowerShell script-block logging, if enabled by the organisation, records it | Script deleted when it finishes, or at the next start | User |
| D9 | Paths and settings | User | Settings | `%LOCALAPPDATA%\CodexResume\config.json` | Until deleted | User |
| D10 | Broken-config copy | D9 | Keep a config that could not be read | `config.json.bad-<date>` | Newest one only | User |
| D11 | App log `resume.log` (+ `.1`) | App | Diagnostics, time of last resume | `%LOCALAPPDATA%\CodexResume\` | 1 MB rotation, one old file; `%USERPROFILE%` masked | User |
| D12 | Helpers: `run-resume.ps1` (fixed text), `TypeIntoCodex-v3.exe` + `.cs` | App | Resume and keystroke helpers | `%LOCALAPPDATA%\CodexResume\` | Until the folder is deleted; older helper versions are removed | User |
| D13 | Balloon notifications | App | Status alerts. They never contain the prompt or a path | Windows notification center | Set by the OS | User |
| D14 | v1.0 data in `%APPDATA%\CodexResume\` | Earlier version | n/a | Removed at the first v1.1 start: config copied, log and helpers deleted | Retried on every start until done | User; roaming profile until removed |

## Third parties
| Party | When | Data sent |
|---|---|---|
| OpenAI, through the Codex CLI the app starts | On resume | The session, sent by Codex itself; this is the app's purpose |
| chatgpt.com Usage page, in the user's browser | Only when the user presses **Use reset** with no command set | A browser request with the user's cookies (an https address is required) |

The app makes no network calls of its own: searching the code for network APIs finds none. A folder taken from a session file is accepted only if it is on a local drive, so a `\\server` path cannot trigger a network login.

## Deleting your data
Delete `%LOCALAPPDATA%\CodexResume\`, and `%APPDATA%\CodexResume\` if a pre-1.1 version left it behind. The app does not copy Codex transcripts anywhere. See the README section "Uninstall / delete your data".
