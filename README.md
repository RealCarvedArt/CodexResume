# Codex Resume

Tiny Windows tray app that watches your Codex CLI usage windows and resumes your last Codex session once the 5-hour (or weekly) limit resets.

![Codex Resume window](docs/screenshot.png)

- Reads the `rate_limits` events Codex CLI writes to `%USERPROFILE%\.codex\sessions\**\*.jsonl` (or `$env:CODEX_HOME\sessions`).
- Settings and log live in `%LOCALAPPDATA%\CodexResume\`. Versions before 1.1 used `%APPDATA%\CodexResume\`. The first start of 1.1 copies your settings over and deletes the old log, because the old log could contain your prompt, full paths and the reset command. It also deletes the other files the app made there, and the old folder itself if nothing else is in it.

## Run

Double-click `Start-CodexResume.cmd` (launches `CodexResume.ps1` hidden via Windows PowerShell 5.1+).

- Closing or minimising the window hides it to the tray, and the app keeps watching. To quit, right-click the tray icon and choose **Exit**.
- **Esc** hides the window and **F5** re-reads the logs.
- **Show details** shows where the data comes from, the paths, and any warnings.

## Reading the status

- **OK**: the latest usage numbers are recent, and no window is at the limit.
- **Stale data**: Codex has not logged usage for a while (30 minutes by default; `StaleMinutes` in `config.json`), or a Codex window is open but has logged nothing for 10 minutes. The numbers may be behind. Each bar then shows `[as of …]`.
- **Rate limited**: a window reached the limit. The app continues your session after it resets.
- **Warning**: a setup problem that stays on screen until it is fixed. Examples are a `config.json` that could not be read, or a Codex folder that other accounts on the PC can write to.

## Safety

- Values taken from Codex's session files (the folder, the session id) are only used as data, never run as code. The session id must be a plain UUID, and the folder must be on a local drive.
- When Codex is installed through npm, the app starts it with `node` directly, so your prompt is not reinterpreted by `cmd.exe`.
- System programs (PowerShell, Explorer, Notepad) are started by their full paths.
- Automatic continues stop after 10 per run by default (`MaxContinues`; 0 means no limit). Settings saved by versions before 1.1 always held 0, the old default, so upgrading changes that 0 to 10 once. If you want no limit, set 0 again after upgrading.
- If `config.json` cannot be read, the app keeps a copy (`config.json.bad-<date>`) and starts with auto-continue turned off.

## Privacy

The app makes no network requests of its own. It opens the Codex Usage page in your browser only when you press **Use reset**. When it resumes a session, Codex itself sends that session to OpenAI, as it does whenever you use Codex.

| What | Why | Where | How long |
|---|---|---|---|
| The last 512 KB of recent Codex session files (the last 8 days) | To read usage numbers, reset times, the session id and folder | Memory only. Only those derived values are kept, never the text | Until the app exits, or the file is older than 8 days |
| Running programs: name, process id, start time, Windows session. Command lines are read only for Codex processes | To find your open Codex window | Memory only | Until the next check (every 15 seconds) |
| Settings (`config.json`) | Your choices, including your prompt and any reset command | `%LOCALAPPDATA%\CodexResume\` | Until you delete it |
| A broken `config.json` (`config.json.bad-<date>`) | So a settings file that could not be read is not lost | `%LOCALAPPDATA%\CodexResume\` | Only the newest copy is kept |
| Log (`resume.log`) | Times the app armed, resumed, or hit an error. It records the project folder's name and the prompt's length, never the prompt, the reset command, or session content. Your profile folder is written as `%USERPROFILE%` | `%LOCALAPPDATA%\CodexResume\` | Up to about 2 MB (the current file plus one older file) |
| Resume data file (`run-resume.json`) | Passes the folder, program and arguments to a new window | `%LOCALAPPDATA%\CodexResume\` | Deleted as soon as it is read, or after 2 minutes |
| Reset script (`reset-command.ps1`) | Runs your `UseResetCommand` without putting it on a command line | `%LOCALAPPDATA%\CodexResume\` | Deleted when the command finishes, or at the next start if the app was closed first |
| Typing helper (`TypeIntoCodex-v3.exe`) | Types your prompt into the Codex window. It receives the prompt on its input, not its command line | `%LOCALAPPDATA%\CodexResume\` | Until you delete the folder |

Command lines can be recorded by Windows auditing or security software. If your organisation turns on PowerShell script-block logging, the contents of the reset script are recorded too. That applies to any PowerShell that runs on the PC. The prompt is never on the typing helper's command line. When the app opens Codex in a **new window**, however, the prompt is an argument to Codex (`codex resume <session> <prompt>`), which is how Codex takes it. If your prompt is sensitive, use the default **Type into the open Codex window** mode.

## Uninstall / delete your data

1. Right-click the tray icon and choose **Exit**.
2. Delete the folder you extracted the app into.
3. Delete `%LOCALAPPDATA%\CodexResume\`. Also delete `%APPDATA%\CodexResume\` if a version before 1.1 left it behind.

The app never changes Codex's own files.

## Security issues

See [SECURITY.md](SECURITY.md).
