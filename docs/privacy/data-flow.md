# Data Flow: CodexResume v1.1

Item numbers (D1 to D14) refer to `data-inventory.md`.

```mermaid
flowchart LR
  subgraph Codex[Written by Codex]
    S[(sessions/**/*.jsonl)]
    T[(log/codex-tui.log)]
  end
  subgraph App[CodexResume process]
    P[Parse tails<br/>D1, D2: transient]
    C[SessionCache<br/>D3: derived values only]
    W[Window and tray<br/>full paths in window only]
    Q[Process scan, background thread<br/>D6]
  end
  subgraph Local[%LOCALAPPDATA%\CodexResume: you, SYSTEM, Administrators]
    CFG[(config.json D9<br/>+ newest .bad copy D10)]
    LOG[(resume.log D11<br/>names, lengths; no prompt/command)]
    RJ[(run-resume.json<br/>deleted on read or after 2 min)]
    RS[(reset-command.ps1<br/>deleted when done)]
  end
  S --> P --> C --> W
  T --> P
  Q --> W
  CFG <--> App
  App --> LOG
  App -->|folder, program, args| RJ --> R[Runner window] --> X[Codex] -->|session| O[(OpenAI)]
  App -->|prompt on stdin| H[Typing helper] --> X
  App --> RS --> PS[PowerShell] 
  App -->|only on Use reset| B[Browser: Usage page]
```

- **Stays in memory only:** transcript text (D1, D2) and the process list (D6).
- **Written to disk:** the config, the log, and two short-lived files (the runner data and the reset script). All of them are in `%LOCALAPPDATA%`, which only your account, SYSTEM and Administrators can open.
- **Leaves the machine:** only what Codex sends to OpenAI on resume, and the browser request when the user presses **Use reset**.
- **Deletion:** remove the folder. Codex's own files are never changed.
