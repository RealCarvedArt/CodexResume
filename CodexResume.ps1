<#
  Codex Resume
  Tiny tray app that watches your Codex usage windows and resumes your last
  Codex session once the 5-hour (or weekly) limit resets.

  Data source: the rate_limits events Codex CLI writes into
  %USERPROFILE%\.codex\sessions\**\*.jsonl (or $env:CODEX_HOME\sessions).
  Settings and log: %LOCALAPPDATA%\CodexResume\
#>
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
# Started from PowerShell 7, Windows PowerShell inherits PS7's module folders and
# then cannot load its own built-in modules (CIM, security). Drop those folders.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    $env:PSModulePath = (($env:PSModulePath -split ';') | Where-Object { $_ -and $_ -notmatch '\\PowerShell\\7|\\powershell\\Modules$' }) -join ';'
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

Add-Type -Namespace CodexResume -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
'@
Add-Type -Namespace CodexResume -Name Native -MemberDefinition @'
[DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hWnd, string app, string idList);
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
'@
# Windows PowerShell by full path (not PATH, and not $PSHOME, which is PowerShell 7's folder under pwsh).
$WinPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ES_CONTINUOUS      = [uint32]2147483648
$ES_KEEP_AWAKE      = [uint32]2147483649   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED

# ---------------------------------------------------------------- paths -----
# Local, not Roaming: the log names project folders, and roaming profiles
# would copy it to a file server.
$ConfigDir    = Join-Path $env:LOCALAPPDATA 'CodexResume'
$ConfigPath   = Join-Path $ConfigDir 'config.json'
$LogPath      = Join-Path $ConfigDir 'resume.log'
$CodexHome    = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$SessionsPath = Join-Path $CodexHome 'sessions'
$OldConfigDir = Join-Path $env:APPDATA 'CodexResume'
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
# Move from the Roaming folder used before v1.1. Only settings are kept: the
# old log could hold prompts, full paths and the reset command, so it is
# deleted, as are the old helpers. Retried on every start until it succeeds.
# Only files this app made are removed; the folder goes only if nothing else is left.
if (Test-Path -LiteralPath $OldConfigDir) {
    try {
        $oldCfg = Join-Path $OldConfigDir 'config.json'
        if ((Test-Path -LiteralPath $oldCfg) -and -not (Test-Path -LiteralPath (Join-Path $ConfigDir 'config.json'))) {
            Copy-Item -LiteralPath $oldCfg -Destination (Join-Path $ConfigDir 'config.json')
        }
        $known = '^(config\.json(\.bad-.*|\.tmp)?|resume\.log(\.1)?|run-resume\.(ps1|json)|reset-command\.ps1|TypeIntoCodex(-v\d+)?\.(cs|exe)|type-into-codex\.ps1)$'
        Get-ChildItem -LiteralPath $OldConfigDir -File -Force | Where-Object { $_.Name -match $known } | Remove-Item -Force
        if (-not (Get-ChildItem -LiteralPath $OldConfigDir -Force)) { Remove-Item -LiteralPath $OldConfigDir -Force }
    } catch { }
}
# Files left behind by a runner or reset command that never finished (they
# hold the folder and prompt, or the reset command).
foreach ($f in 'run-resume.json', 'reset-command.ps1') { Remove-Item -LiteralPath (Join-Path $ConfigDir $f) -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- config ----
function Load-Config {
    $j = $null
    $cfg = @{
        ProjectPath     = $env:USERPROFILE
        FollowSession   = $true       # resume in the folder the last Codex session used
        CodexPath       = ''          # full path to codex.cmd / codex.exe; blank = find it automatically
        Prompt          = 'continue'
        AutoResume      = $true
        BufferSeconds   = 60          # wait this long after the reset before resuming
        RefreshSeconds  = 15          # how often to re-read Codex session files
        KeepAwake       = $true       # stop Windows sleeping while a resume is pending
        AlwaysOnTop     = $true
        Theme           = 'System'   # System, Light or Dark
        TextScale       = 100        # 100 to 200 percent, on top of the Windows text size
        DisplayUpdate   = 'Every second'   # Every second, Every 30 seconds, Paused
        # {prompt} is replaced with your prompt text. Add flags such as
        # --full-auto here if you want the resumed run to edit files freely.
        # How to continue. Interactive gives you the normal Codex screen back in a
        # new window; Background runs it without the interactive screen.
        # {session} becomes the session id (or --last if unknown), {prompt} your prompt.
        # Type        = type the prompt + Enter into the open Codex window (default)
        # Interactive = resume the session in a new window
        # Background  = resume with codex exec in a new window
        ContinueMode        = 'Type'
        TypeCharDelayMs     = 35      # gap between typed letters
        TypeEnterDelayMs    = 600     # pause before Enter, so Codex does not treat it as a paste
        MaxContinues        = 10      # stop after this many automatic continues per run; 0 = no limit
        TargetPid           = 0       # which Codex window to type into when several are open
        TargetStarted       = ''      # start time of that window, so a reused process id is not mistaken for it
        DetailsOpen         = $false  # show the Details panel
        ConfigVersion       = 3
        InteractiveTemplate = 'codex resume {session} {prompt}'
        BackgroundTemplate  = 'codex exec --skip-git-repo-check resume {session} {prompt}'
        CloseOpenCodex      = $true   # close a still-open Codex first (it locks the session)
        # Codex usually logs 99% (not 100%) before refusing, so arm at this level.
        # A "You've hit your usage limit" error in the logs also arms it.
        LimitThreshold  = 99
        # Codex only logs usage while it is working. Past this age the status
        # says the numbers may be out of date instead of "OK".
        StaleMinutes    = 30
        # Banked reset credits. OpenAI only documents redeeming these in
        # Settings > Usage (Codex app or web). If you have a script that redeems
        # one, put it in UseResetCommand; it must exit 0 on success. Leave it
        # empty to open UsagePageUrl and redeem by hand.
        UseReset            = $false
        ResetMinWaitMinutes = 60      # only spend a reset if the wait is longer than this
        UseResetCommand     = ''
        UsagePageUrl        = 'https://chatgpt.com/codex/settings/usage'
        # Codex logs do not report banked resets, so you enter how many you have.
        # -1 means unknown. The app lowers this by one each time it uses a reset.
        ResetsOnHand        = -1
        ResetExpires        = ''      # date your next reset expires, e.g. 2026-11-06
    }
    $defaults = $cfg.Clone()
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $j = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        } catch {
            # Keep the broken file for the user, and start safely: no automatic actions.
            # Only the newest broken copy is kept; it may hold your prompt and reset command.
            $bad = '{0}.bad-{1:yyyyMMdd-HHmmss}' -f $ConfigPath, (Get-Date)
            $cfg.AutoResume = $false
            try {
                Copy-Item -LiteralPath $ConfigPath -Destination $bad
                Get-ChildItem -LiteralPath $ConfigDir -Filter 'config.json.bad-*' | Where-Object { $_.FullName -ne $bad } | Remove-Item -ErrorAction SilentlyContinue
                $script:ConfigError = "config.json could not be read, so auto-continue is off. Your old file was saved as $(Split-Path $bad -Leaf)."
            } catch {
                # No copy, so never overwrite the original: settings are not saved this run.
                $script:ConfigReadOnly = $true
                $script:ConfigError = 'config.json could not be read or backed up, so auto-continue is off and settings will not be saved. Fix or delete config.json.'
            }
        }
    }
    # A value of the wrong type falls back to its default instead of crashing later.
    foreach ($k in @($defaults.Keys)) {
        $d = $defaults[$k]; $v = $cfg[$k]
        if ($d -is [bool]) {
            if ($v -isnot [bool]) { $cfg[$k] = $d }
        } elseif ($d -is [int]) {
            $n = 0.0
            if ([double]::TryParse([string]$v, [ref]$n) -and [Math]::Abs($n) -lt 1e9) { $cfg[$k] = [int]$n } else { $cfg[$k] = $d }
        } elseif ($null -eq $v -or $v -isnot [string]) { $cfg[$k] = $d }
    }
    # Configs saved before typing mode existed: switch them to it.
    $ver = 1; try { if ($j -and $j.ConfigVersion) { $ver = [int]$j.ConfigVersion } } catch { }
    if ($ver -lt 2) { $cfg.ContinueMode = 'Type'; $cfg.ConfigVersion = 2 }
    # Before v1.1 every config was saved with MaxContinues 0 (no limit), the old
    # default; give those the new limit of 10 once. 0 set from now on is kept.
    if ($ver -lt 3) {
        if ([int]$cfg.MaxContinues -eq 0) { $cfg.MaxContinues = 10 }
        $cfg.ConfigVersion = 3
    }
    # Re-reading every session file more often than every 5 seconds only costs CPU.
    if ([int]$cfg.RefreshSeconds -lt 5) { $cfg.RefreshSeconds = 5 }
    # Older versions used a single CommandTemplate; replaced by the modes.
    if ($cfg.ContainsKey('CommandTemplate')) { $cfg.Remove('CommandTemplate') }
    $cfg
}
# Write to a temporary file and swap it in, so a crash never leaves a half-written config.
function Save-Config {
    if ($script:ConfigReadOnly) { return }
    $tmp = "$ConfigPath.tmp"
    $script:Config | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
    if (Test-Path -LiteralPath $ConfigPath) { [IO.File]::Replace($tmp, $ConfigPath, [NullString]::Value) }
    else { [IO.File]::Move($tmp, $ConfigPath) }
}
# The log keeps one previous file at 1 MB, and repeats of the same message
# within 10 minutes are dropped. Line breaks are removed so a value cannot
# forge extra log lines.
$script:LastLog = @{ Msg = $null; At = [datetime]::MinValue }
function Write-Log([string]$msg) {
    # Error texts can contain full paths; hide the profile folder (it names the user).
    $msg = $msg -replace '[\r\n]+', ' '
    if ($env:USERPROFILE) { $msg = $msg -ireplace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%' }
    $now = Get-Date
    if ($msg -eq $script:LastLog.Msg -and ($now - $script:LastLog.At).TotalMinutes -lt 10) { return }
    $script:LastLog = @{ Msg = $msg; At = $now }
    if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) {
        Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
    }
    Add-Content -LiteralPath $LogPath -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f $now, $msg)
}
# Last part of a path, for the log and notifications (the full path stays in the window).
function Get-Leaf([string]$path) { if ($path) { Split-Path $path -Leaf } else { '' } }

# ------------------------------------------------------- reading Codex data --
function Read-Tail([string]$path, [int]$bytes = 524288) {
    $share = [IO.FileShare]'ReadWrite, Delete'
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $start = [Math]::Max([long]0, $fs.Length - $bytes)
        [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd()
    } finally { $fs.Dispose() }
    $lines = $text -split "`r?`n"
    if ($start -gt 0 -and $lines.Count -gt 1) { $lines = $lines[1..($lines.Count - 1)] }
    $lines
}

# Windows does not update a file's LastWriteTime while Codex keeps it open, so
# a long-running session can look a day old while it is still being written.
# Take every session touched (or created) in the last 8 days, which covers the
# weekly window; callers rank by the event timestamps inside the files.
function Get-SessionFiles {
    $all = @(Get-ChildItem -LiteralPath $SessionsPath -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending)
    $cut = (Get-Date).AddDays(-8)
    $recent = @($all | Where-Object { $_.LastWriteTime -gt $cut })
    if ($recent.Count -lt 5) { $recent = @($all | Select-Object -First 5) }
    $recent
}

function Get-EventTime($o, [datetime]$fallback) {
    $ts = $o.timestamp
    if ($ts -is [datetime]) { return $ts.ToLocalTime() }
    if ($ts) { try { return ([DateTimeOffset]::Parse([string]$ts)).LocalDateTime } catch { } }
    $fallback
}

function Convert-Window($w, [datetime]$eventTime) {
    if ($null -eq $w -or $null -eq $w.used_percent) { return $null }
    $reset = $null
    if ($w.resets_at) {
        $reset = [DateTimeOffset]::FromUnixTimeSeconds([int64]$w.resets_at).LocalDateTime
    } elseif ($null -ne $w.resets_in_seconds) {
        $reset = $eventTime.AddSeconds([double]$w.resets_in_seconds)
    }
    # A window cannot reset later than its own length after the event; a later
    # time is bad or planted data, so it is not used to arm a resume.
    # Without a window length, the longest Codex window (one week) is the limit.
    $mins = 0.0
    if (-not ([double]::TryParse([string]$w.window_minutes, [ref]$mins) -and $mins -gt 0)) { $mins = 10080 }
    if ($reset -and $reset -gt $eventTime.AddMinutes($mins + 10)) { $reset = $null }
    [pscustomobject]@{ Used = [double]$w.used_percent; Minutes = $w.window_minutes; ResetAt = $reset }
}

function Format-Credits($c) {
    if ($null -eq $c) { return 'not reported by Codex logs' }
    $bal = 0.0; [void][double]::TryParse([string]$c.balance, [ref]$bal)
    if ($c.unlimited -ne $true -and $null -ne $c.has_credits -and -not $c.has_credits -and $bal -eq 0) { return 'none (paid credit balance, not resets)' }
    if ($c -is [string] -or $c -is [ValueType]) { return [string]$c }
    if ($c.unlimited) { return 'unlimited' }
    $parts = foreach ($p in $c.PSObject.Properties) {
        if ($null -ne $p.Value -and $p.Value -isnot [psobject[]]) { '{0}: {1}' -f ($p.Name -replace '_', ' '), $p.Value }
    }
    if ($parts) { $parts -join ', ' } else { 'none' }
}

# Reset-credit count: from the Codex logs if they ever report one, otherwise
# the number you entered. Returns a number, or $null when unknown.
function Get-ResetExpiry {
    $e = [string]$script:Config.ResetExpires
    if (-not $e.Trim()) { return $null }
    try { [datetime]::Parse($e) } catch { $null }
}
function Get-ResetsFromLogs($l) {
    if (-not $l -or $null -eq $l.Credits -or $l.Credits -is [ValueType] -or $l.Credits -is [string]) { return $null }
    foreach ($p in $l.Credits.PSObject.Properties) {
        if ($p.Name -match 'reset' -and $null -ne $p.Value) {
            $n = 0.0
            if ([double]::TryParse([string]$p.Value, [ref]$n)) { return [int]$n }
            if ($p.Value -is [bool]) { return [int]$p.Value }
        }
    }
    $null
}
function Get-ResetsAvailable($l) {
    $fromLogs = Get-ResetsFromLogs $l
    if ($null -ne $fromLogs) { return $fromLogs }
    $n = [int]$script:Config.ResetsOnHand
    if ($n -lt 0) { return $null }
    $exp = Get-ResetExpiry
    if ($exp -and $exp.Date.AddDays(1) -le (Get-Date)) { return 0 }
    $n
}
function Consume-Reset {
    $n = [int]$script:Config.ResetsOnHand
    if ($n -gt 0) {
        $script:Config.ResetsOnHand = $n - 1
        Save-Config
        Write-Log "Reset count lowered to $($n - 1)"
    }
}

# The refusal Codex shows when you are out of usage. Matches the message and
# the underlying error code.
$LimitPattern = "hit your usage limit|usage_limit_reached|usage limit reached"

# Newest time a usage-limit error was logged after $since, or $null.
# Looks in recent session logs and in Codex's own log file.
function Find-LimitError($files, [datetime]$since) {
    $found = $null
    # No LastWriteTime shortcut here: it is stale for files Codex has open.
    foreach ($f in $files) {
        $sum = $script:SessionCache[$f.FullName]
        if (-not $sum) { continue }
        foreach ($t in $sum.LimitTimes) {
            if ($t -gt $since -and (-not $found -or $t -gt $found)) { $found = $t }
        }
    }
    $tui = Join-Path $CodexHome 'log\codex-tui.log'
    if (Test-Path -LiteralPath $tui) {
        $fi = Get-Item -LiteralPath $tui
        if ($fi.LastWriteTime -gt $since) {
            foreach ($line in (Read-Tail $tui 262144)) {
                if ($line -notmatch $LimitPattern) { continue }
                # Only trust lines that start with a timestamp, so old errors never count.
                if ($line -match '^\s*(\d{4}-\d{2}-\d{2}[T ][\d:.]+(Z|[+-]\d{2}:?\d{2})?)') {
                    try {
                        $t = ([DateTimeOffset]::Parse($Matches[1])).LocalDateTime
                        if ($t -gt $since -and (-not $found -or $t -gt $found)) { $found = $t }
                    } catch { }
                }
            }
        }
    }
    $found
}

# Folder the session ran in: from the newest turn_context in the tail, or the
# session_meta line at the top of the file.
function Get-SessionCwd([string]$path, $tailLines) {
    for ($i = $tailLines.Count - 1; $i -ge 0; $i--) {
        if ($tailLines[$i] -notmatch '"cwd"') { continue }
        try { $o = $tailLines[$i] | ConvertFrom-Json } catch { continue }
        foreach ($c in @($o.payload.cwd, $o.cwd)) { if ($c) { return [string]$c } }
    }
    foreach ($line in (Read-Head $path 50)) {
        if ($line -notmatch '"cwd"') { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        foreach ($c in @($o.payload.cwd, $o.cwd)) { if ($c) { return [string]$c } }
    }
    $null
}

# First $maxLines lines, reading at most 1 MB, so one huge line cannot exhaust memory.
function Read-Head([string]$path, [int]$maxLines) {
    try {
        $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            $buf = New-Object byte[] ([int][Math]::Min([long]1MB, $fs.Length))
            $got = 0
            while ($got -lt $buf.Length) { $r = $fs.Read($buf, $got, $buf.Length - $got); if ($r -le 0) { break }; $got += $r }
        } finally { $fs.Dispose() }
        @([Text.Encoding]::UTF8.GetString($buf, 0, $got) -split "`r?`n" | Select-Object -First $maxLines)
    } catch { @() }
}

# Session id: the UUID at the end of the rollout file name, or session_meta id.
function Get-SessionId([string]$path) {
    $name = [IO.Path]::GetFileNameWithoutExtension($path)
    if ($name -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$') { return $Matches[1] }
    foreach ($line in (Read-Head $path 20)) {
        if ($line -notmatch 'session_meta') { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.payload.id) { return [string]$o.payload.id }
    }
    $null
}

# Codex subcommands that are not an interactive terminal session (IDE
# extension / desktop app servers, background runs, tools).
$NonTuiCommands = @('app-server', 'mcp', 'mcp-server', 'exec', 'e', 'login', 'logout', 'proto', 'p',
    'completion', 'sandbox', 'debug', 'apply', 'a', 'cloud', 'cloud-tasks', 'responses-api-proxy',
    'stdio-to-uds', 'generate-ts', 'features', 'help')

function Get-CodexSubcommand([string]$cmdLine) {
    if (-not $cmdLine) { return '' }
    # Drop the executable (quoted or not), then find the first word that is not a flag.
    $rest = $cmdLine -replace '^\s*("[^"]*"|\S+)\s*', ''
    foreach ($tok in ($rest -split '\s+')) {
        if (-not $tok) { continue }
        if ($tok.StartsWith('-')) { continue }
        return $tok.Trim('"').ToLowerInvariant()
    }
    ''
}

# Interactive Codex terminal sessions. Each result has ProcessId, Started and
# Host (the terminal it runs in). Skips background servers and anything that
# runs under another Codex process.
# Only processes in this Windows session count, so another signed-in user's
# Codex is never typed into. Command lines are read only for Codex processes.
function Get-OpenCodex {
    try {
        # A timeout, so a stuck WMI service cannot hold the scan forever.
        $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate, SessionId -OperationTimeoutSec 10 -ErrorAction Stop)
        # One query, filtered by WMI itself, for the command lines of Codex processes only.
        $cmdLines = @{}
        foreach ($c in @(Get-CimInstance Win32_Process -Filter "Name LIKE 'codex%'" -Property ProcessId, CommandLine -OperationTimeoutSec 10 -ErrorAction Stop)) {
            $cmdLines[[int]$c.ProcessId] = [string]$c.CommandLine
        }
    } catch { return @() }
    $mySession = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $byId = @{}; foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
    $isCodex = { param($p) $p -and $p.Name -like 'codex*.exe' }
    $out = foreach ($p in $all) {
        if (-not (& $isCodex $p)) { continue }
        if ([int]$p.SessionId -ne $mySession) { continue }
        # Started between the two queries: skip it until the next scan sees it fully.
        if (-not $cmdLines.ContainsKey([int]$p.ProcessId)) { continue }
        if ($NonTuiCommands -contains (Get-CodexSubcommand $cmdLines[[int]$p.ProcessId])) { continue }
        # Walk up the parent chain: skip helpers, and note the terminal.
        $under = $false; $hostApp = $null; $shell = $null
        $cur = $byId[[int]$p.ParentProcessId]; $hops = 0
        while ($cur -and $hops -lt 12) {
            if (& $isCodex $cur) { $under = $true; break }
            $n = ([string]$cur.Name).ToLowerInvariant()
            # Keep the outermost shell: npm's cmd wrapper sits below the one you opened.
            if ($n -in @('powershell.exe', 'pwsh.exe', 'cmd.exe', 'bash.exe', 'wsl.exe', 'nu.exe')) { $shell = $cur.Name -replace '\.exe$', '' }
            if (-not $hostApp) {
                switch ($n) {
                    'windowsterminal.exe' { $hostApp = 'Windows Terminal' }
                    'code.exe'            { $hostApp = 'VS Code' }
                    'cursor.exe'          { $hostApp = 'Cursor' }
                    'wezterm-gui.exe'     { $hostApp = 'WezTerm' }
                    'alacritty.exe'       { $hostApp = 'Alacritty' }
                    'conemu64.exe'        { $hostApp = 'ConEmu' }
                }
            }
            $cur = $byId[[int]$cur.ParentProcessId]; $hops++
        }
        if ($under) { continue }
        $where = if ($hostApp -and $shell) { "$shell in $hostApp" } elseif ($hostApp) { $hostApp } elseif ($shell) { "$shell window" } else { 'console window' }
        $started = $null; try { $started = [datetime]$p.CreationDate } catch { }
        [pscustomobject]@{ ProcessId = [int]$p.ProcessId; Started = $started; Host = $where }
    }
    @($out)
}
function Format-StartKey($started) { if ($started) { $started.ToString('o') } else { '' } }

function Format-CodexChoice($c) {
    $t = if ($c.Started) { '{0:ddd h:mm tt}' -f $c.Started } else { 'unknown time' }
    'PID {0}, started {1}, {2}' -f $c.ProcessId, $t, $c.Host
}

# The Codex window to type into: your pick if it is still running, or the only
# one open. Returns @{ Target; Open } where Target may be $null.
function Get-TargetCodex {
    $open = @(Get-OpenCodex)
    $pick = [int]$script:Config.TargetPid
    # Same id and same start time: a new process that reused the id is not your pick.
    $t = $open | Where-Object { $_.ProcessId -eq $pick -and (Format-StartKey $_.Started) -eq [string]$script:Config.TargetStarted } |
         Select-Object -First 1
    if (-not $t -and $open.Count -eq 1) { $t = $open[0] }
    [pscustomobject]@{ Target = $t; Open = $open }
}

# Keystroke helper: a tiny Windows program (no console of its own) that
# attaches to the Codex console and writes key presses into its input, exactly
# as if typed on the keyboard. No window focus needed, and it cannot type into
# any other window. Compiled once with the C# compiler built into Windows.
$TypeHelperVersion = 3
$TypeHelperSource = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

static class TypeIntoCodex {
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public int bKeyDown;
        [FieldOffset(8)] public ushort wRepeatCount;
        [FieldOffset(10)] public ushort wVirtualKeyCode;
        [FieldOffset(12)] public ushort wVirtualScanCode;
        [FieldOffset(14)] public char UnicodeChar;
        [FieldOffset(16)] public uint dwControlKeyState;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] buf, uint len, out uint written);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern short VkKeyScanW(char ch);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyW(uint code, uint mapType);

    static INPUT_RECORD Key(char c, ushort vk, bool down, uint state) {
        INPUT_RECORD r = new INPUT_RECORD();
        r.EventType = 1; r.bKeyDown = down ? 1 : 0; r.wRepeatCount = 1;
        r.wVirtualKeyCode = vk; r.wVirtualScanCode = (ushort)MapVirtualKeyW(vk, 0);
        r.UnicodeChar = c; r.dwControlKeyState = state;
        return r;
    }
    static bool Send(IntPtr h, char c, bool enter) {
        ushort vk; uint state = 0;
        if (enter) { vk = 0x0D; c = (char)13; }
        else {
            short scan = VkKeyScanW(c);
            vk = (ushort)(scan == -1 ? 0 : (scan & 0xFF));
            if (scan != -1 && (scan & 0x100) != 0) state |= 0x10;  // SHIFT_PRESSED
        }
        INPUT_RECORD[] recs = new INPUT_RECORD[] { Key(c, vk, true, state), Key(c, vk, false, state) };
        uint written;
        return WriteConsoleInputW(h, recs, (uint)recs.Length, out written) && written == 2;
    }

    // Arguments: <pid> <text, or - to read it from stdin as UTF-8> [charDelayMs] [enterDelayMs]
    static int Main(string[] a) {
        if (a.Length < 2) return 10;
        uint pid; if (!uint.TryParse(a[0], out pid)) return 10;
        string text = a[1];
        if (text == "-") {
            using (var r = new System.IO.StreamReader(Console.OpenStandardInput(), new System.Text.UTF8Encoding(false))) text = r.ReadToEnd();
        }
        int charDelay = 35, enterDelay = 600;
        if (a.Length > 2) int.TryParse(a[2], out charDelay);
        if (a.Length > 3) int.TryParse(a[3], out enterDelay);
        FreeConsole();
        if (!AttachConsole(pid)) return 2;
        IntPtr h = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) { FreeConsole(); return 3; }
        try {
            foreach (char ch in text) {
                if (!Send(h, ch, false)) return 4;
                Thread.Sleep(charDelay);
            }
            Thread.Sleep(enterDelay);
            if (!Send(h, (char)13, true)) return 4;
        } finally { CloseHandle(h); FreeConsole(); }
        return 0;
    }
}
'@

$TypeHelperExe = Join-Path $ConfigDir "TypeIntoCodex-v$TypeHelperVersion.exe"

# Builds the helper if it is missing. Returns $true when it is ready.
function Ensure-TypeHelper {
    if (Test-Path -LiteralPath $TypeHelperExe) { return $true }
    $src = Join-Path $ConfigDir 'TypeIntoCodex.cs'
    Set-Content -LiteralPath $src -Value $TypeHelperSource -Encoding UTF8
    $csc = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    try {
        if ($csc) {
            $out = & $csc /nologo /target:winexe /optimize "/out:$TypeHelperExe" $src 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Log "Helper build failed: $out" }
        } else {
            Add-Type -TypeDefinition $TypeHelperSource -OutputAssembly $TypeHelperExe -OutputType WindowsApplication
        }
    } catch { Write-Log "Helper build failed: $($_.Exception.Message)" }
    $ok = Test-Path -LiteralPath $TypeHelperExe
    # Older helper versions are no longer used.
    if ($ok) {
        Get-ChildItem -LiteralPath $ConfigDir -Filter 'TypeIntoCodex-v*.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $TypeHelperExe } | Remove-Item -ErrorAction SilentlyContinue
    }
    $ok
}

# Types $text + Enter into the console of Codex process $procId. Returns $true on success.
# Exit codes: 2 = could not attach to that console, 3 = no console input,
# 4 = writing keys failed, 10 = bad arguments, 20 = helper could not be built.
function Send-ToCodex([int]$procId, [string]$text) {
    if (-not (Ensure-TypeHelper)) { $script:TypeExit = 20; return $false }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $TypeHelperExe
    # The prompt goes through stdin, so it never appears on a process command line.
    $psi.Arguments = '{0} - {1} {2}' -f $procId, [int]$script:Config.TypeCharDelayMs, [int]$script:Config.TypeEnterDelayMs
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $p = [Diagnostics.Process]::Start($psi)
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
    # If the helper already quit (e.g. bad arguments), writing fails; its exit code says why.
    try { $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.Close() } catch { }
    if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch { }; $script:TypeExit = -1; return $false }
    $script:TypeExit = $p.ExitCode
    $p.ExitCode -eq 0
}

# Reload PATH from the registry so installs made after this app started are seen.
function Update-PathFromRegistry {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
}

# Finds the Codex CLI. Returns a full path, or $null.
function Resolve-Codex {
    $cfgPath = [string]$script:Config.CodexPath
    if ($cfgPath.Trim()) {
        if (Test-Path -LiteralPath $cfgPath -PathType Leaf) { return $cfgPath }
        return $null
    }
    # Known per-user install locations first, then PATH, so a codex planted in
    # a shared PATH folder is not preferred over your own install.
    $candidates = @(
        "$env:APPDATA\npm\codex.cmd"
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\codex.exe"
        "$env:USERPROFILE\scoop\shims\codex.exe"
        "$env:LOCALAPPDATA\pnpm\codex.cmd"
        "$env:USERPROFILE\.bun\bin\codex.exe"
        "$env:USERPROFILE\.cargo\bin\codex.exe"
        "$env:USERPROFILE\.local\bin\codex.exe"
        "$env:LOCALAPPDATA\Programs\codex\codex.exe"
        "$env:ProgramFiles\nodejs\codex.cmd"
    )
    if ($env:NVM_SYMLINK) { $candidates += "$env:NVM_SYMLINK\codex.cmd" }
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c } }
    $nvm = Join-Path $env:APPDATA 'nvm'
    if (Test-Path -LiteralPath $nvm) {
        $hit = Get-ChildItem -LiteralPath $nvm -Filter 'codex.cmd' -Recurse -Depth 2 -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    Update-PathFromRegistry
    $cmd = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue |
           Where-Object { $_.Source -match '\.(cmd|exe|bat)$' } | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $null
}

# How to start Codex. npm's codex.cmd goes through cmd.exe, which reinterprets
# & | % and quotes inside the prompt, so node runs codex.js directly instead.
function Get-CodexLaunch([string]$codex) {
    if ($codex -match '\.(cmd|bat)$') {
        $dir = Split-Path $codex
        $js = Join-Path $dir 'node_modules\@openai\codex\bin\codex.js'
        if (Test-Path -LiteralPath $js) {
            $node = @((Join-Path $dir 'node.exe'), "$env:ProgramFiles\nodejs\node.exe") |
                    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if (-not $node) {
                # node from PATH only when no other account can change its folder.
                $node = (Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
                if ($node -and (Test-OthersCanWrite (Split-Path $node))) { $node = $null }
            }
            if ($node) { return [pscustomobject]@{ Program = $node; Prefix = @($js) } }
        }
    }
    [pscustomobject]@{ Program = $codex; Prefix = @() }
}

# $true when an account other than you, SYSTEM, Administrators or
# TrustedInstaller may change $path (or what is created inside it), or owns it.
# When the permissions cannot be read, it says $true: better a warning than none.
function Test-OthersCanWrite([string]$path) {
    try {
        # .NET Framework (Windows PowerShell); PowerShell 7 has only Get-Acl.
        $acl = if ([IO.Directory].GetMethod('GetAccessControl', [type[]]@([string], [Security.AccessControl.AccessControlSections]))) {
            if (Test-Path -LiteralPath $path -PathType Container) { [IO.Directory]::GetAccessControl($path, 'Access, Owner') }
            else { [IO.File]::GetAccessControl($path, 'Access, Owner') }
        } else { Get-Acl -LiteralPath $path }
    } catch { return $true }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trusted = @($me, 'S-1-5-18', 'S-1-5-32-544', 'S-1-3-0',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    try { if ($trusted -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return $true } } catch { return $true }
    # Write, append, delete child, write attributes, delete, change permissions,
    # take ownership, plus generic write/all.
    $mask = 0x2 -bor 0x4 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000
    foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ([string]$r.AccessControlType -ne 'Allow') { continue }
        if (([long]$r.FileSystemRights -band $mask) -eq 0) { continue }
        if ($trusted -notcontains $r.IdentityReference.Value) { return $true }
    }
    $false
}

# Folder Codex will be resumed in.
function Get-ResumeFolder {
    # The cwd comes from a session file, so only accept a local drive path. A
    # UNC path (\\host\share) would make Test-Path log in to that host.
    if ($script:Config.FollowSession -and $script:Limits -and $script:Limits.Cwd -and
        [string]$script:Limits.Cwd -match '^[A-Za-z]:\\' -and
        (Test-Path -LiteralPath $script:Limits.Cwd)) { return [string]$script:Limits.Cwd }
    [string]$script:Config.ProjectPath
}

# Parsed facts per session file, reused while the file's live length (read
# from an open handle; the directory entry can be stale) and a hash of its last
# 4 KB are unchanged. Only derived values are kept, never transcript text.
$script:SessionCache = @{}
function Get-SessionSummary($f) {
    $share = [IO.FileShare]'ReadWrite, Delete'
    $fs = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $len = $fs.Length
        $n = [int][Math]::Min([long]4096, $len)
        [void]$fs.Seek($len - $n, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] $n
        $got = 0
        while ($got -lt $n) { $r = $fs.Read($buf, $got, $n - $got); if ($r -le 0) { break }; $got += $r }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $key = '{0}:{1}' -f $len, [Convert]::ToBase64String($sha.ComputeHash($buf, 0, $got)) } finally { $sha.Dispose() }
    } finally { $fs.Dispose() }
    $hit = $script:SessionCache[$f.FullName]
    if ($hit -and $hit.Key -eq $key) { return $hit }

    $lines = Read-Tail $f.FullName
    $rate = $null
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -notmatch '"rate_limits"') { continue }
        try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
        $rl = $null
        foreach ($c in @($o.payload.rate_limits, $o.payload.info.rate_limits, $o.rate_limits, $o.msg.rate_limits)) {
            if ($c) { $rl = $c; break }
        }
        if (-not $rl) { continue }
        $t = Get-EventTime $o $f.LastWriteTime
        $p = Convert-Window $rl.primary $t
        $s = Convert-Window $rl.secondary $t
        if (-not $p -and -not $s) { continue }
        $rate = [pscustomobject]@{ Primary = $p; Secondary = $s; Plan = $rl.plan_type; Credits = $rl.credits; EventTime = $t }
        break
    }
    $limitTimes = @(foreach ($line in $lines) {
        if ($line -notmatch $LimitPattern) { continue }
        try { Get-EventTime ($line | ConvertFrom-Json) $f.LastWriteTime } catch { $f.LastWriteTime }
    })
    $sum = [pscustomobject]@{
        Key        = $key
        Rate       = $rate
        LimitTimes = $limitTimes
        Cwd        = $(if ($rate) { Get-SessionCwd $f.FullName $lines })
    }
    $script:SessionCache[$f.FullName] = $sum
    $sum
}

function Get-RateLimits {
    if (-not (Test-Path -LiteralPath $SessionsPath)) { return $null }
    $files = Get-SessionFiles
    $best = $null; $bestFile = $null; $seen = @{}
    # Events dated in the future are not trusted; they would outrank real data forever.
    $latest = (Get-Date).AddMinutes(5)
    foreach ($f in $files) {
        $seen[$f.FullName] = $true
        # A file can vanish or be locked between listing and reading; skip it.
        try { $sum = Get-SessionSummary $f } catch { continue }
        if (-not $sum.Rate -or $sum.Rate.EventTime -gt $latest) { continue }
        if (-not $best -or $sum.Rate.EventTime -gt $best.Rate.EventTime) { $best = $sum; $bestFile = $f }
    }
    foreach ($k in @($script:SessionCache.Keys)) { if (-not $seen[$k]) { $script:SessionCache.Remove($k) } }
    if (-not $best) { return $null }
    $r = $best.Rate
    [pscustomobject]@{
        Primary    = $r.Primary
        Secondary  = $r.Secondary
        Plan       = $r.Plan
        Credits    = $r.Credits
        EventTime  = $r.EventTime
        Source     = $bestFile.FullName
        LimitHitAt = (Find-LimitError $files $r.EventTime)
        Cwd        = $best.Cwd
        SessionId  = (Get-SessionId $bestFile.FullName)
    }
}

# A window is blocking when it reaches the threshold. If both are, wait for the
# later reset. If Codex logged a usage-limit error but no window is over the
# threshold, the fullest window is the one that ran out. A window that has
# reset since that error cleared it, so the error no longer counts.
function Get-BlockingReset($l) {
    if (-not $l) { return $null }
    $now = Get-Date
    $th = [double]$script:Config.LimitThreshold
    if ($th -le 0 -or $th -gt 100) { $th = 99 }
    $all = @($l.Primary, $l.Secondary) | Where-Object { $_ -and $_.ResetAt }
    $w = @($all | Where-Object { $_.ResetAt -gt $now })
    if (-not $w) { return $null }
    $b = @($w | Where-Object { $_.Used -ge $th })
    $hit = $l.LimitHitAt
    if ($hit -and @($all | Where-Object { $_.ResetAt -gt $hit -and $_.ResetAt -le $now }).Count) { $hit = $null }
    if (-not $b -and $hit) { $b = @($w | Sort-Object Used -Descending | Select-Object -First 1) }
    if (-not $b) { return $null }
    ($b | Sort-Object ResetAt -Descending | Select-Object -First 1).ResetAt
}

# Coarse age for the status line, so it does not change every second.
function Format-Age([TimeSpan]$t) {
    if ($t.TotalMinutes -lt 1) { return 'just now' }
    if ($t.TotalHours -lt 1) { return '{0}m ago' -f [int][Math]::Floor($t.TotalMinutes) }
    if ($t.Days -gt 0) { return '{0}d {1}h ago' -f $t.Days, $t.Hours }
    '{0}h {1:00}m ago' -f $t.Hours, $t.Minutes
}
function Test-Stale($l) {
    $m = 0.0; [void][double]::TryParse([string]$script:Config.StaleMinutes, [ref]$m)
    if ($m -le 0) { $m = 30 }
    $l -and ((Get-Date) - $l.EventTime).TotalMinutes -gt $m
}

function Format-Span([TimeSpan]$t) {
    if ($t.TotalSeconds -le 0) { return 'now' }
    if ($t.Days -gt 0) { return '{0}d {1}h {2:00}m' -f $t.Days, $t.Hours, $t.Minutes }
    '{0}h {1:00}m {2:00}s' -f $t.Hours, $t.Minutes, $t.Seconds
}

function Get-CommandTemplate {
    if ([string]$script:Config.ContinueMode -eq 'Background') { [string]$script:Config.BackgroundTemplate }
    else { [string]$script:Config.InteractiveTemplate }
}
# The id can come from inside a session file, so only a plain UUID is used.
function Get-SessionArg {
    $id = if ($script:Limits) { [string]$script:Limits.SessionId } else { '' }
    if ($id -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { $id } else { '--last' }
}
# Splits a command template into words (double or single quotes group words)
# and fills in {session} and {prompt} per word, so a value can never add
# arguments or code.
function Split-Template([string]$template, [string]$session, [string]$prompt) {
    foreach ($m in [regex]::Matches($template, '"([^"]*)"|''([^'']*)''|(\S+)')) {
        $w = ($m.Groups[1..3] | Where-Object Success | Select-Object -First 1).Value
        $w.Replace('{session}', $session).Replace('{prompt}', $prompt)
    }
}
function Get-ResumeCommand {
    if ([string]$script:Config.ContinueMode -eq 'Type') {
        return 'Types "{0}" + Enter into the open Codex window' -f $script:Config.Prompt
    }
    (Get-CommandTemplate).Replace('{session}', (Get-SessionArg)).Replace('{prompt}', ('"{0}"' -f $script:Config.Prompt))
}

function Get-LastResumeFromLog {
    if (-not (Test-Path -LiteralPath $LogPath)) { return $null }
    $line = Get-Content -LiteralPath $LogPath -Tail 200 | Where-Object { $_ -match '\] Resumed' } | Select-Object -Last 1
    if ($line -match '^\[([^\]]+)\]') { try { return [datetime]$Matches[1] } catch { } }
    $null
}

# ------------------------------------------------------------ resuming -------
$script:ContinuesSent = 0
function Start-Resume([string]$reason) {
    $cfg = $script:Config
    $max = [int]$cfg.MaxContinues
    if ($reason -ne 'manual' -and $max -gt 0 -and $script:ContinuesSent -ge $max) {
        Write-Log "Stopped: reached MaxContinues ($max)"
        Set-Notice "Stopped after $max automatic continues (MaxContinues in config.json)."
        return
    }
    if ([string]$cfg.ContinueMode -eq 'Type') {
        $sel = Get-TargetCodex
        $open = @($sel.Open)
        if ($open.Count -eq 0) {
            Write-Log "Nothing to continue ($reason): no open Codex window"
            Set-Notice 'No open Codex window to continue. Start Codex, or switch Mode to open a new window.'
            Show-Tip 'Codex Resume' 'No open Codex window to type into.' 'Warning'
            return
        }
        if (-not $sel.Target) {
            Write-Log "Not typing ($reason): $($open.Count) Codex windows open and none picked"
            Set-Notice "$($open.Count) Codex windows are open. Pick the one to continue in the Target list, then press Continue now."
            Show-Tip 'Codex Resume' 'Several Codex windows are open. Pick one in the Target list.' 'Warning'
            Show-Main
            return
        }
        $procId = [int]$sel.Target.ProcessId
        if (Send-ToCodex $procId ([string]$cfg.Prompt)) {
            $script:LastResume = Get-Date
            $script:LastResumeWhat = 'Typed your prompt into the Codex window'
            if ($reason -ne 'manual') { $script:ContinuesSent++ }
            Write-Log "Typed the prompt ($(([string]$cfg.Prompt).Length) characters) into Codex (pid $procId) ($reason)"
            Show-Tip 'Codex continued' 'Typed your prompt into the Codex window.' 'Info'
        } else {
            Write-Log "Typing into Codex failed (pid $procId, exit $($script:TypeExit))"
            $why = switch ($script:TypeExit) {
                2  { 'could not attach to its console (it may run as administrator while this app does not)' }
                3  { 'its console has no input' }
                4  { 'Windows refused the key presses' }
                20 { 'the typing helper could not be built; see the log' }
                default { "code $($script:TypeExit)" }
            }
            Set-Notice "Could not type into the Codex window: $why. Try Continue now, or switch Mode to New window."
            Show-Tip 'Codex Resume' 'Could not type into the Codex window.' 'Error'
        }
        return
    }
    $dir = Get-ResumeFolder
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-Log "Resume skipped ($reason): project folder '$(Get-Leaf $dir)' not found"
        Set-Notice "Could not continue: project folder not found ($dir). Choose a folder with Browse."
        Show-Tip 'Codex Resume' 'Project folder not found. Choose one with Browse.' 'Error'
        return
    }
    $codex = Resolve-Codex
    if (-not $codex) {
        Write-Log "Resume skipped ($reason): Codex CLI not found"
        Set-Notice 'Could not continue: Codex CLI not found. Use Browse next to Codex CLI to pick codex.cmd or codex.exe.'
        Show-Tip 'Codex Resume' 'Codex CLI not found. Pick it with Browse next to Codex CLI.' 'Error'
        Show-Main
        return
    }
    # A Codex that is still open holds the session, and a second one cannot
    # resume it. Close it first when there is exactly one; with several open we
    # cannot tell which is this session, so ask instead of guessing.
    $open = @(Get-OpenCodex)
    if ($open.Count -gt 0) {
        if (-not $cfg.CloseOpenCodex) {
            Write-Log "Resume skipped ($reason): Codex is still open"
            Set-Notice 'Could not continue: Codex is still open with this session. Close it, or turn on "close it first".'
            Show-Tip 'Codex Resume' 'Codex is still open. Close it so the session can be resumed.' 'Warning'
            return
        }
        if ($open.Count -gt 1) {
            Write-Log "Resume skipped ($reason): $($open.Count) Codex processes open"
            Set-Notice "Could not continue: $($open.Count) Codex windows are open. Close the one for this session, then press Continue now."
            Show-Tip 'Codex Resume' "$($open.Count) Codex windows are open. Close the one for this session." 'Warning'
            Show-Main
            return
        }
        Write-Log "Closing open Codex (pid $($open[0].ProcessId)) so the session can be resumed"
        try {
            Stop-Process -Id $open[0].ProcessId -ErrorAction Stop
            Wait-Process -Id $open[0].ProcessId -Timeout 10 -ErrorAction SilentlyContinue
        } catch {
            Write-Log "Resume skipped ($reason): could not close Codex (pid $($open[0].ProcessId)): $($_.Exception.Message)"
            Set-Notice 'Could not continue: the open Codex could not be closed. Close it yourself, then press Continue now.'
            Show-Tip 'Codex Resume' 'Could not close the open Codex.' 'Warning'
            return
        }
        Start-Sleep -Seconds 2   # let it release the session lock
    }

    # Run the exact executable found, so PATH differences cannot break it. The
    # runner script is fixed text; folder, program and arguments travel in a
    # data file it reads and deletes, so no value is ever run as code.
    $words = @(Split-Template (Get-CommandTemplate) (Get-SessionArg) ([string]$cfg.Prompt))
    if ($words.Count -eq 0) {
        Set-Notice 'Could not continue: the command template in config.json is empty.'
        return
    }
    $program = $words[0]
    $argv = @($words | Select-Object -Skip 1)
    if ($program -match '^codex(\.cmd|\.exe)?$') {
        $launch = Get-CodexLaunch $codex
        $program = $launch.Program
        $argv = @($launch.Prefix) + $argv
    }
    # A .cmd or .bat still goes through cmd.exe; refuse what cmd.exe would reinterpret.
    if ($program -match '\.(cmd|bat)$' -and @($argv -match "[`"%^&|<>!`r`n]").Count -gt 0) {
        Write-Log "Resume skipped ($reason): prompt or template has characters cmd.exe would change"
        Set-Notice 'Could not continue: Codex runs through cmd.exe here, which would change " % ^ & | < > ! and line breaks in your prompt. Remove them, or pick codex.exe with Browse.'
        return
    }
    # A bare program name would be searched for in the project folder first;
    # resolve it from PATH now instead.
    if (-not [IO.Path]::IsPathRooted($program)) {
        $found = Get-Command $program -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) {
            Write-Log "Resume skipped ($reason): program in the command template not found"
            Set-Notice "Could not continue: '$program' from the command template was not found."
            return
        }
        $program = $found.Source
    }
    $runner = Join-Path $ConfigDir 'run-resume.ps1'
    $data = Join-Path $ConfigDir 'run-resume.json'
    $body = @'
param([string]$DataPath)
$d = Get-Content -LiteralPath $DataPath -Raw -Encoding UTF8 | ConvertFrom-Json
Remove-Item -LiteralPath $DataPath -ErrorAction SilentlyContinue
$Host.UI.RawUI.WindowTitle = 'Codex Resume'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
Set-Location -LiteralPath $d.Dir
Write-Host "Resuming Codex in $PWD ..." -ForegroundColor Cyan
Write-Host "Using $($d.Program)" -ForegroundColor DarkGray
# Quote each argument by the Windows rules, so it arrives exactly as written
# (Windows PowerShell 5.1 does not escape quotes inside arguments itself).
$line = (@($d.Args) | ForEach-Object { '"' + (([string]$_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }) -join ' '
$psi = New-Object Diagnostics.ProcessStartInfo ([string]$d.Program), $line
$psi.UseShellExecute = $false
$psi.WorkingDirectory = $d.Dir
$p = [Diagnostics.Process]::Start($psi)
$p.WaitForExit()
'@
    Set-Content -LiteralPath $runner -Value $body -Encoding UTF8
    ConvertTo-Json -InputObject @{ Dir = $dir; Program = $program; Args = [object[]]$argv } |
        Set-Content -LiteralPath $data -Encoding UTF8
    Start-Process $WinPowerShell -WorkingDirectory $dir -ArgumentList @(
        '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$runner`"", '-DataPath', "`"$data`"")
    $script:LastResume = Get-Date
    $script:LastResumeWhat = 'Resumed your last session in a new window'
    if ($reason -ne 'manual') { $script:ContinuesSent++ }
    Write-Log "Resumed ($reason) in folder '$(Get-Leaf $dir)', mode $($cfg.ContinueMode)"
    Show-Tip 'Codex resumed' 'Sent your prompt to your last session.' 'Info'
}

function Use-ResetCredit([string]$reason) {
    $cfg = $script:Config
    $script:ResetTriedFor = $script:ArmedFor
    $cmd = [string]$cfg.UseResetCommand
    if ($cmd.Trim()) {
        # The command may hold a token, so it is never logged and never put on a
        # command line: it runs from a script in the user-only settings folder,
        # deleted when it finishes. The last line keeps -Command's exit rule
        # (1 when the last command failed).
        Write-Log "Using reset credit ($reason) with your reset command"
        $script:ResetScript = Join-Path $ConfigDir 'reset-command.ps1'
        # The blank line ends a command that finishes with a ` line continuation.
        Set-Content -LiteralPath $script:ResetScript -Value "$cmd`r`n`r`nif (-not `$?) { exit 1 }" -Encoding UTF8
        $script:ResetProc = Start-Process $WinPowerShell -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($script:ResetScript)`"")
        Show-Tip 'Codex Resume' 'Using a reset credit...' 'Info'
    } else {
        $u = $null
        if (-not ([Uri]::TryCreate([string]$cfg.UsagePageUrl, [UriKind]::Absolute, [ref]$u) -and $u.Scheme -eq 'https')) {
            Write-Log "Reset not started ($reason): UsagePageUrl is not an https address"
            Set-Notice 'UsagePageUrl in config.json must be an https:// address.'
            return
        }
        $script:AwaitingManualReset = $true
        if ($reason -eq 'manual') {
            Write-Log 'Opened the Usage page to redeem a reset'
            Start-Process $u.AbsoluteUri
            Show-Tip 'Use your reset' 'Click "Use reset" on the Usage page, then press Continue now.' 'Info'
        } else {
            # Unattended: never open the browser on its own; ask instead.
            Write-Log "A reset credit could shorten the wait ($reason); asked you to redeem it"
            Show-Tip 'Use a reset?' 'The wait is long. Press "Use reset" in Codex Resume to open the Usage page.' 'Info'
        }
        Show-Main
    }
}

# Called each tick: decides whether to spend a reset, and handles the result.
function Check-Reset {
    $p = $script:ResetProc
    if ($p -and $p.HasExited) {
        $script:ResetProc = $null
        if ($script:ResetScript) { Remove-Item -LiteralPath $script:ResetScript -ErrorAction SilentlyContinue }
        if ($p.ExitCode -eq 0) {
            Write-Log 'Reset credit used'
            Consume-Reset
            $script:ArmedFor = $null
            Start-Resume 'reset credit'
        } else {
            Write-Log "Reset command failed (exit $($p.ExitCode)); waiting for the normal reset"
            Set-Notice "Using a reset failed (exit code $($p.ExitCode)). Waiting for the normal reset instead."
            Show-Tip 'Reset failed' 'Waiting for the normal reset instead.' 'Warning'
        }
        return
    }
    $cfg = $script:Config
    if (-not ($script:ArmedFor -and $cfg.AutoResume -and $cfg.UseReset)) { return }
    if ($script:ResetTriedFor -eq $script:ArmedFor -or $script:ResetProc) { return }
    if (($script:ArmedFor - (Get-Date)).TotalMinutes -le [double]$cfg.ResetMinWaitMinutes) { return }
    $avail = Get-ResetsAvailable $script:Limits
    if ($null -ne $avail -and $avail -le 0) { return }
    Use-ResetCredit 'auto'
}

# ------------------------------------------------------------- state ---------
$script:Config      = Load-Config
$script:Limits      = $null
$script:ArmedFor    = $null
$script:LastRefresh = [datetime]::MinValue
$script:ReadError   = $null
$script:LastResume  = Get-LastResumeFromLog
$script:ResetProc   = $null
$script:ResetTriedFor = $null
$script:AwaitingManualReset = $false
$script:Notice = $null
$script:NoticeUntil = [datetime]::MinValue
function Set-Notice([string]$text) { $script:Notice = $text; $script:NoticeUntil = (Get-Date).AddMinutes(10) }

$script:CodexExe = $null
function Refresh-Limits {
    $script:LastRefresh = Get-Date
    # The runner deletes its data file at once; one still here after 2 minutes was never read.
    $rj = Join-Path $ConfigDir 'run-resume.json'
    if ((Test-Path -LiteralPath $rj) -and ((Get-Date) - (Get-Item -LiteralPath $rj).LastWriteTime).TotalMinutes -gt 2) {
        Remove-Item -LiteralPath $rj -ErrorAction SilentlyContinue
    }
    try { if ($cmbTarget) { Update-CodexScan; Update-TargetList } } catch { }
    try { $script:CodexExe = Resolve-Codex } catch { $script:CodexExe = $null }
    try {
        $script:Limits = Get-RateLimits
        $script:ReadError = $null
    } catch {
        $script:ReadError = $_.Exception.Message
    }
    # Only arm when we see a reset that is still in the future, so stale data
    # from an old session never triggers a surprise resume.
    # A reset that has already arrived is never replaced: the timer continues
    # once BufferSeconds have passed.
    $r = Get-BlockingReset $script:Limits
    $due = $script:Config.AutoResume -and $script:ArmedFor -and $script:ArmedFor -le (Get-Date)
    if ($r -and $r -gt (Get-Date) -and $script:ArmedFor -ne $r -and -not $due) {
        $script:ArmedFor = $r
        Write-Log ('Armed: limit resets at {0:G}' -f $r)
    }
    $flags = if ($script:ArmedFor -and $script:Config.AutoResume -and $script:Config.KeepAwake) { $ES_KEEP_AWAKE } else { $ES_CONTINUOUS }
    [void][CodexResume.Power]::SetThreadExecutionState($flags)
    $script:Warnings = @(Get-Warnings)
    $script:FirstScanDone = $true
}

# Problems that stay on screen until they are fixed (a notice fades after 10
# minutes; these do not).
$script:Warnings = @()
$script:AclCache = @{}
function Get-OthersCanWriteCached([string]$path) {
    $c = $script:AclCache[$path]
    if ($c -and ((Get-Date) - $c.At).TotalMinutes -lt 10) { return $c.Value }
    $v = Test-OthersCanWrite $path
    $script:AclCache[$path] = @{ Value = $v; At = Get-Date }
    $v
}
function Get-Warnings {
    if ($script:ConfigError) { $script:ConfigError }
    if ([string]$script:Config.ContinueMode -ne 'Type' -and -not $script:CodexExe) {
        'Codex CLI not found, so a new window cannot be opened. Use Browse next to Codex CLI.'
    }
    # Paths are listed under Details (Sessions folder, Codex CLI).
    if ((Test-Path -LiteralPath $SessionsPath) -and (Get-OthersCanWriteCached $SessionsPath)) {
        'Other accounts on this PC may be able to write to the Codex sessions folder and fake usage data. Limit it to your account.'
    }
    if ($script:CodexExe -and (Get-OthersCanWriteCached (Split-Path $script:CodexExe))) {
        'Other accounts on this PC may be able to change the folder the Codex CLI runs from.'
    }
}

# ---------------------------------------------------------------- theme ------
# Every text color below meets WCAG 2.0 AA (4.5:1) against the backgrounds it
# is drawn on. Status text always says its meaning in words, so color is never
# the only cue. Windows High Contrast mode overrides these with system colors.
$Palettes = @{
    Light = @{
        Back = [Drawing.Color]::FromArgb(240, 240, 240); Fore = [Drawing.Color]::Black
        Input = [Drawing.Color]::White;                  InputFore = [Drawing.Color]::Black
        Muted = [Drawing.Color]::FromArgb(90, 90, 90);   Button = [Drawing.Color]::FromArgb(225, 225, 225)
        Border = [Drawing.Color]::FromArgb(118, 118, 118)
        Red = [Drawing.Color]::FromArgb(178, 34, 34);    Green = [Drawing.Color]::FromArgb(0, 118, 50)
        Yellow = [Drawing.Color]::FromArgb(138, 88, 0);  Link = [Drawing.Color]::FromArgb(0, 95, 184)
        Bar = [Drawing.Color]::FromArgb(0, 118, 50);     BarBack = [Drawing.Color]::FromArgb(214, 214, 214)
        Focus = [Drawing.Color]::FromArgb(204, 228, 247); FocusFore = [Drawing.Color]::Black
        RedBg = [Drawing.Color]::FromArgb(253, 231, 231);    RedFg = [Drawing.Color]::FromArgb(140, 20, 20)
        GreenBg = [Drawing.Color]::FromArgb(225, 244, 232);  GreenFg = [Drawing.Color]::FromArgb(0, 90, 38)
        YellowBg = [Drawing.Color]::FromArgb(255, 243, 214); YellowFg = [Drawing.Color]::FromArgb(110, 70, 0)
    }
    Dark = @{
        Back = [Drawing.Color]::FromArgb(30, 30, 30);    Fore = [Drawing.Color]::FromArgb(230, 230, 230)
        Input = [Drawing.Color]::FromArgb(45, 45, 45);   InputFore = [Drawing.Color]::FromArgb(230, 230, 230)
        Muted = [Drawing.Color]::FromArgb(157, 165, 180); Button = [Drawing.Color]::FromArgb(51, 51, 51)
        Border = [Drawing.Color]::FromArgb(128, 128, 128)
        Red = [Drawing.Color]::FromArgb(255, 160, 150);  Green = [Drawing.Color]::FromArgb(95, 211, 141)
        Yellow = [Drawing.Color]::FromArgb(229, 192, 123); Link = [Drawing.Color]::FromArgb(108, 182, 255)
        Bar = [Drawing.Color]::FromArgb(95, 211, 141);   BarBack = [Drawing.Color]::FromArgb(60, 60, 60)
        Focus = [Drawing.Color]::FromArgb(38, 79, 120);  FocusFore = [Drawing.Color]::FromArgb(230, 230, 230)
        RedBg = [Drawing.Color]::FromArgb(74, 25, 25);       RedFg = [Drawing.Color]::FromArgb(255, 220, 220)
        GreenBg = [Drawing.Color]::FromArgb(22, 58, 38);     GreenFg = [Drawing.Color]::FromArgb(205, 245, 220)
        YellowBg = [Drawing.Color]::FromArgb(66, 52, 20);    YellowFg = [Drawing.Color]::FromArgb(255, 236, 190)
    }
}
function Get-HighContrastPalette {
    $s = [Drawing.SystemColors]
    @{
        Back = $s::Control; Fore = $s::ControlText; Input = $s::Window; InputFore = $s::WindowText
        Muted = $s::ControlText; Button = $s::Control; Border = $s::ControlText
        Red = $s::ControlText; Green = $s::ControlText; Yellow = $s::ControlText; Link = $s::HotTrack
        Bar = $s::Highlight; BarBack = $s::Window; Focus = $s::Highlight; FocusFore = $s::HighlightText
        RedBg = $s::Control; RedFg = $s::ControlText; GreenBg = $s::Control; GreenFg = $s::ControlText
        YellowBg = $s::Control; YellowFg = $s::ControlText
    }
}

function Get-SystemTheme {
    try {
        $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme
        if ($v -eq 0) { return 'Dark' }
    } catch { }
    'Light'
}
function Get-EffectiveTheme {
    if ([Windows.Forms.SystemInformation]::HighContrast) { return 'HighContrast' }
    switch ([string]$script:Config.Theme) { 'Dark' { 'Dark' } 'Light' { 'Light' } default { Get-SystemTheme } }
}
function Get-Palette([string]$name) { if ($name -eq 'HighContrast') { Get-HighContrastPalette } else { $Palettes[$name] } }
$script:ThemeName = Get-EffectiveTheme
$script:Pal = Get-Palette $script:ThemeName

function ColorRef([Drawing.Color]$c) { [IntPtr]([int]$c.R -bor ([int]$c.G -shl 8) -bor ([int]$c.B -shl 16)) }

# ---------------------------------------------------------------- sizing -----
# Text follows the Windows text size, times the app's own Text size setting
# (up to 200%). Every position below is in design units scaled by $Z.
$sysPt = [Drawing.SystemFonts]::MessageBoxFont.SizeInPoints
$scalePct = [Math]::Max(100, [Math]::Min(200, [int]$script:Config.TextScale))
$Z = ($scalePct / 100.0) * [Math]::Max(1.0, $sysPt / 9.0)
function S([double]$n) { [int][Math]::Round($n * $Z) }
function Pt($x, $y) { New-Object Drawing.Point((S $x), (S $y)) }
function Sz($w, $h) { New-Object Drawing.Size((S $w), (S $h)) }

# ---------------------------------------------------------------- UI ---------
$W = 600   # client width in design units
$form = New-Object Windows.Forms.Form
$form.Text            = 'Codex Resume'
$form.ClientSize      = Sz $W 794
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.StartPosition   = 'CenterScreen'
$form.TopMost         = [bool]$script:Config.AlwaysOnTop
$form.Font            = New-Object Drawing.Font('Segoe UI', (9 * $Z))
$form.KeyPreview      = $true
# At large text sizes the window can be taller than the screen; scroll instead
# of pushing controls out of reach.
$form.AutoScroll      = $true

$script:TabN = 0
function Add-Ctl([string]$type, [hashtable]$props, $parent = $form) {
    $c = New-Object "Windows.Forms.$type"
    foreach ($k in $props.Keys) { $c.$k = $props[$k] }
    $c.TabIndex = $script:TabN++
    $parent.Controls.Add($c)
    $c
}
function Set-Text($ctl, [string]$text) { if ($ctl.Text -ne $text) { $ctl.Text = $text; return $true }; $false }

$bold = New-Object Drawing.Font('Segoe UI', (9 * $Z), [Drawing.FontStyle]::Bold)
$tips = New-Object Windows.Forms.ToolTip

[void](Add-Ctl Label @{ Text = '5-hour'; Location = (Pt 12 12); Size = (Sz 70 18); Font = $bold })
$bar5   = Add-Ctl ProgressBar @{ Location = (Pt 85 12); Size = (Sz 330 16); Maximum = 100
                                AccessibleName = '5-hour window, percent remaining' }
$pct5   = Add-Ctl Label @{ Location = (Pt 425 12); Size = (Sz 163 18) }
$info5  = Add-Ctl Label @{ Location = (Pt 12 32); Size = (Sz 576 18); Tag = 'muted' }

[void](Add-Ctl Label @{ Text = 'Weekly'; Location = (Pt 12 60); Size = (Sz 70 18); Font = $bold })
$barW   = Add-Ctl ProgressBar @{ Location = (Pt 85 60); Size = (Sz 330 16); Maximum = 100
                                AccessibleName = 'Weekly window, percent remaining' }
$pctW   = Add-Ctl Label @{ Location = (Pt 425 60); Size = (Sz 163 18) }
$infoW  = Add-Ctl Label @{ Location = (Pt 12 80); Size = (Sz 576 18); Tag = 'muted' }

# Two lines tall so longer messages wrap instead of being cut off.
# Text that does not fit ends in "..."; the full text is in its tooltip and in Details > Access.
$status = Add-Ctl Label @{ Location = (Pt 12 106); Size = (Sz 576 36); Font = $bold; Tag = 'status'
                           AccessibleName = 'Status'; UseMnemonic = $false; AutoEllipsis = $true }
# Screen readers announce changes of state (not every countdown second); see Update-UI.
try { $status.LiveSetting = 'Polite' } catch { }

$chkAuto = Add-Ctl CheckBox @{ Text = '&Auto-continue when the limit resets'; Location = (Pt 12 146); Size = (Sz 400 22)
                               Checked = [bool]$script:Config.AutoResume }

$chkReset = Add-Ctl CheckBox @{ Text = '&Use a reset credit if the wait is longer than'; Location = (Pt 12 170); Size = (Sz 300 22)
                                Checked = [bool]$script:Config.UseReset }
$numReset = Add-Ctl NumericUpDown @{ Location = (Pt 314 170); Size = (Sz 64 22); Minimum = 0; Maximum = 10080
                                     Value = [decimal][Math]::Max(0, [Math]::Min(10080, [double]$script:Config.ResetMinWaitMinutes))
                                     AccessibleName = 'Minimum wait in minutes before using a reset credit' }
[void](Add-Ctl Label @{ Text = 'minutes'; Location = (Pt 382 173); Size = (Sz 80 18) })

[void](Add-Ctl Label @{ Text = 'Resets on hand (&k)'; Location = (Pt 30 199); Size = (Sz 100 18) })
$numHave = Add-Ctl NumericUpDown @{ Location = (Pt 132 196); Size = (Sz 56 22); Minimum = 0; Maximum = 99
                                    Value = [decimal][Math]::Max(0, [Math]::Min(99, [int]$script:Config.ResetsOnHand))
                                    AccessibleName = 'Number of banked reset credits you have' }
[void](Add-Ctl Label @{ Text = '&Expires'; Location = (Pt 204 199); Size = (Sz 54 18) })
$dtExp = Add-Ctl DateTimePicker @{ Location = (Pt 260 196); Size = (Sz 150 22); Format = 'Short'; ShowCheckBox = $true
                                   AccessibleName = 'Date your next reset credit expires. Uncheck if unknown.' }
$expInit = Get-ResetExpiry
if ($expInit) { $dtExp.Value = $expInit; $dtExp.Checked = $true } else { $dtExp.Checked = $false }
$tips.SetToolTip($numHave, 'Codex logs do not report banked resets. Enter your count from Settings > Usage.')
[void](Add-Ctl Label @{ Text = 'Codex logs do not report these; copy them from Settings > Usage.'; Location = (Pt 416 193)
                        Size = (Sz 172 30); Tag = 'muted'; UseMnemonic = $false; Font = New-Object Drawing.Font('Segoe UI', (8 * $Z)) })

[void](Add-Ctl Label @{ Text = 'F&older'; Location = (Pt 12 233); Size = (Sz 48 18) })
$txtDir  = Add-Ctl TextBox @{ Location = (Pt 62 230); Size = (Sz 460 22); ReadOnly = $true; Text = [string]$script:Config.ProjectPath
                              AccessibleName = 'Project folder to resume in' }
$btnDir  = Add-Ctl Button  @{ Text = '&Browse'; Location = (Pt 528 229); Size = (Sz 60 24)
                              AccessibleName = 'Browse for project folder' }
$chkFollow = Add-Ctl CheckBox @{ Text = "Use the last Codex &session's folder"; Location = (Pt 62 256); Size = (Sz 400 22)
                                 Checked = [bool]$script:Config.FollowSession }

[void](Add-Ctl Label @{ Text = '&Prompt'; Location = (Pt 12 289); Size = (Sz 48 18) })
$txtPrompt = Add-Ctl TextBox @{ Location = (Pt 62 286); Size = (Sz 526 22); Text = [string]$script:Config.Prompt
                                AccessibleName = 'Prompt to send when continuing' }

[void](Add-Ctl Label @{ Text = 'Codex &CLI'; Location = (Pt 12 321); Size = (Sz 66 18) })
$txtCodex = Add-Ctl TextBox @{ Location = (Pt 80 318); Size = (Sz 442 22); ReadOnly = $true
                               AccessibleName = 'Codex CLI executable' }
$btnCodex = Add-Ctl Button  @{ Text = 'Bro&wse'; Location = (Pt 528 317); Size = (Sz 60 24)
                               AccessibleName = 'Browse for the Codex CLI executable' }

[void](Add-Ctl Label @{ Text = '&Mode'; Location = (Pt 12 355); Size = (Sz 42 18) })
$cmbMode = Add-Ctl ComboBox @{ Location = (Pt 56 351); Size = (Sz 230 24); DropDownStyle = 'DropDownList'; AccessibleName = 'Continue mode' }
$modeLabels = [ordered]@{ 'Type' = 'Type into the open Codex window'; 'Interactive' = 'Resume in a new window'; 'Background' = 'Resume in background (exec)' }
[void]$cmbMode.Items.AddRange(@($modeLabels.Values))
$curMode = [string]$script:Config.ContinueMode; if (-not $modeLabels.Contains($curMode)) { $curMode = 'Type' }
$cmbMode.SelectedItem = $modeLabels[$curMode]
$chkClose = Add-Ctl CheckBox @{ Text = '&If Codex is still open, close it first'; Location = (Pt 296 353); Size = (Sz 292 22)
                                Checked = [bool]$script:Config.CloseOpenCodex }
$tips.SetToolTip($chkClose, 'An open Codex locks the session. Only closes it when exactly one Codex is running.')
$lblTarget = Add-Ctl Label @{ Text = 'Tar&get'; Location = (Pt 296 355); Size = (Sz 46 18) }
$cmbTarget = Add-Ctl ComboBox @{ Location = (Pt 344 351); Size = (Sz 244 24); DropDownStyle = 'DropDownList'
                                 AccessibleName = 'Codex window to type into'; DropDownWidth = (S 420) }
$tips.SetToolTip($cmbTarget, 'Which open Codex window to type into. Only needed when more than one is open.')
$script:TargetIds = @()
$script:TargetStarts = @()

# Fills the Target list. Leaves it alone while it is open or nothing changed.
# The process scan takes about a second (two WMI queries), so the regular
# refresh runs it in a background runspace and uses the last finished result;
# the window never freezes for it. A resume still scans directly, so it acts
# on current data.
$script:ScanPS = $null; $script:ScanHandle = $null; $script:OpenCodex = @()
# Takes the finished scan's result. Returns $true when a new one arrived.
function Receive-CodexScan {
    if (-not ($script:ScanHandle -and $script:ScanHandle.IsCompleted)) { return $false }
    try { $script:OpenCodex = @($script:ScanPS.EndInvoke($script:ScanHandle)) } catch { }
    $script:ScanPS.Dispose(); $script:ScanPS = $null; $script:ScanHandle = $null
    $true
}
# Starts a scan unless one is still running.
function Update-CodexScan {
    [void](Receive-CodexScan)
    if ($script:ScanHandle) { return }
    $src ="function Get-CodexSubcommand {${function:Get-CodexSubcommand}}`nfunction Get-OpenCodex {${function:Get-OpenCodex}}`n" +
           '$NonTuiCommands = $args[0]; Get-OpenCodex'
    $script:ScanPS = [powershell]::Create().AddScript($src).AddArgument($NonTuiCommands)
    $script:ScanHandle = $script:ScanPS.BeginInvoke()
}
function Update-TargetList {
    if ($cmbTarget.DroppedDown) { return }
    $open = @($script:OpenCodex)
    $ids = @($open | ForEach-Object { $_.ProcessId })
    if (($ids -join ',') -eq ($script:TargetIds -join ',') -and $cmbTarget.Items.Count -gt 0) { return }
    $script:TargetIds = $ids
    $script:TargetStarts = @($open | ForEach-Object { Format-StartKey $_.Started })
    $script:FillingTargets = $true
    $cmbTarget.Items.Clear()
    if ($open.Count -eq 0) { [void]$cmbTarget.Items.Add('No Codex window open') }
    elseif ($open.Count -eq 1) { [void]$cmbTarget.Items.Add('Auto: ' + (Format-CodexChoice $open[0])) }
    else {
        [void]$cmbTarget.Items.Add("Pick one of $($open.Count) Codex windows...")
        foreach ($c in $open) { [void]$cmbTarget.Items.Add((Format-CodexChoice $c)) }
    }
    $pick = [int]$script:Config.TargetPid
    $idx = 0
    if ($open.Count -gt 1) { for ($i = 0; $i -lt $open.Count; $i++) { if ($open[$i].ProcessId -eq $pick) { $idx = $i + 1 } } }
    $cmbTarget.SelectedIndex = $idx
    $script:FillingTargets = $false
}
function Update-ModeControls {
    $type = [string]$script:Config.ContinueMode -eq 'Type'
    $chkClose.Visible = -not $type
    $lblTarget.Visible = $type
    $cmbTarget.Visible = $type
}

$btnNow   = Add-Ctl Button   @{ Text = 'Co&ntinue now'; Location = (Pt 12 388); Size = (Sz 104 28) }
$btnReset = Add-Ctl Button   @{ Text = 'Use &reset'; Location = (Pt 120 388); Size = (Sz 84 28) }
$btnRef   = Add-Ctl Button   @{ Text = 'Re&fresh'; Location = (Pt 208 388); Size = (Sz 72 28) }
$btnLog   = Add-Ctl Button   @{ Text = 'Open &log'; Location = (Pt 284 388); Size = (Sz 80 28) }
$chkTop   = Add-Ctl CheckBox @{ Text = 'Always on &top'; Location = (Pt 376 391); Size = (Sz 140 22)
                                Checked = [bool]$script:Config.AlwaysOnTop }

[void](Add-Ctl Label @{ Text = 'T&heme'; Location = (Pt 12 429); Size = (Sz 46 18) })
$cmbTheme = Add-Ctl ComboBox @{ Location = (Pt 60 425); Size = (Sz 90 24); DropDownStyle = 'DropDownList'; AccessibleName = 'Theme' }
[void]$cmbTheme.Items.AddRange(@('System', 'Light', 'Dark'))
$cmbTheme.SelectedItem = $(if (@('System', 'Light', 'Dark') -contains [string]$script:Config.Theme) { [string]$script:Config.Theme } else { 'System' })
$tips.SetToolTip($cmbTheme, 'Windows High Contrast mode always takes priority.')

[void](Add-Ctl Label @{ Text = 'Te&xt size'; Location = (Pt 162 429); Size = (Sz 62 18) })
$cmbSize = Add-Ctl ComboBox @{ Location = (Pt 226 425); Size = (Sz 70 24); DropDownStyle = 'DropDownList'; AccessibleName = 'Text size' }
$sizes = @('100%', '125%', '150%', '175%', '200%')
[void]$cmbSize.Items.AddRange($sizes)
$cmbSize.SelectedItem = $(if ($sizes -contains "$scalePct%") { "$scalePct%" } else { '100%' })

[void](Add-Ctl Label @{ Text = '&Display updates'; Location = (Pt 308 429); Size = (Sz 104 18) })
$cmbUpd = Add-Ctl ComboBox @{ Location = (Pt 414 425); Size = (Sz 174 24); DropDownStyle = 'DropDownList'; AccessibleName = 'Display updates' }
$updOpts = @('Every second', 'Every 30 seconds', 'Paused')
[void]$cmbUpd.Items.AddRange($updOpts)
$cmbUpd.SelectedItem = $(if ($updOpts -contains [string]$script:Config.DisplayUpdate) { [string]$script:Config.DisplayUpdate } else { 'Every second' })
$tips.SetToolTip($cmbUpd, 'How often the countdowns redraw. Auto-continue keeps working when paused.')

# ---- Details panel ----
# Values are borderless read-only text boxes: they wrap long paths onto extra
# lines, can be reached with Tab, read by screen readers, and copied.
# No AccessibleName: screen readers read the text, which says Show or Hide.
$btnDetails = Add-Ctl Button @{ Location = (Pt 12 458); Size = (Sz 120 28) }
$grp = Add-Ctl GroupBox @{ Text = 'Details'; Location = (Pt 12 492); Size = (Sz 576 300) }
$CapW   = 120
$ValX   = 136
$ValW   = 576 - $ValX - 12
$PathW  = $ValW - 52
$script:DetailRows = [ordered]@{}
$script:DetailFlags = [Windows.Forms.TextFormatFlags]'WordBreak, TextBoxControl, NoPadding'

function Add-Detail([string]$key, [string]$caption, [switch]$IsPath) {
    $cap = Add-Ctl Label @{ Text = $caption; Location = (Pt 10 0); Size = (Sz $CapW 18); Tag = 'muted'; UseMnemonic = $false } $grp
    $w = if ($IsPath) { $PathW } else { $ValW }
    $val = Add-Ctl TextBox @{ Location = (Pt $ValX 0); Size = (Sz $w 18); ReadOnly = $true; Multiline = $true
                             WordWrap = $true; BorderStyle = 'None'; TabStop = $true; Tag = 'detail'
                             AccessibleName = $caption } $grp
    # Focus shows as a fill plus a border, so it is visible even where the fill is faint.
    $val.Add_GotFocus({ param($s, $e) $s.BackColor = $script:Pal.Focus; $s.ForeColor = $script:Pal.FocusFore; $s.BorderStyle = 'FixedSingle' })
    $val.Add_LostFocus({
        param($s, $e)
        $s.BackColor = $script:Pal.Back
        $s.BorderStyle = 'None'
        foreach ($r in $script:DetailRows.Values) { if ($r.Value -eq $s) { $s.ForeColor = $script:Pal[$r.ColorKey] } }
    })
    $open = $null
    if ($IsPath) {
        $open = Add-Ctl LinkLabel @{ Text = 'Open'; Location = (Pt ($ValX + $PathW + 8) 0); Size = (Sz 44 24)
                                     AccessibleName = "Open $caption in Explorer"; UseMnemonic = $false } $grp
        $open.Tag = $val
        $open.Add_LinkClicked({
            param($sender, $e)
            $p = [string]$sender.Tag.Text
            if (-not $p -or $p -like '(*') { return }
            if (Test-Path -LiteralPath $p -PathType Leaf) { Start-Process (Join-Path $env:SystemRoot 'explorer.exe') "/select,`"$p`"" }
            elseif (Test-Path -LiteralPath $p) { Start-Process (Join-Path $env:SystemRoot 'explorer.exe') "`"$p`"" }
            else { Set-Notice "Not found: $p"; Update-UI }
        })
        $tips.SetToolTip($open, 'Open in Explorer')
    }
    $script:DetailRows[$key] = [pscustomobject]@{ Caption = $cap; Value = $val; Open = $open; ColorKey = 'Fore' }
}

function Layout-Details {
    $show = [bool]$script:Config.DetailsOpen
    [void](Set-Text $btnDetails $(if ($show) { 'Hide details' } else { 'Show details' }))
    $grp.Visible = $show
    if ($show) {
        $y = S 24
        foreach ($r in $script:DetailRows.Values) {
            $t = if ($r.Value.Text) { $r.Value.Text } else { ' ' }
            # The text box wraps a little inside its edges (and inside the focus border), so measure narrower.
            $m = [Windows.Forms.TextRenderer]::MeasureText($t, $r.Value.Font, (New-Object Drawing.Size(($r.Value.Width - (S 8)), 0)), $script:DetailFlags)
            # Rows are at least 24 units tall so the Open links are easy to hit.
            $h = [Math]::Max((S 24), $m.Height + 4)
            if ($r.Caption.Top -ne $y) { $r.Caption.Top = $y }
            if ($r.Value.Top -ne $y)   { $r.Value.Top = $y }
            if ($r.Value.Height -ne $h) { $r.Value.Height = $h }
            if ($r.Open -and $r.Open.Top -ne $y) { $r.Open.Top = $y }
            $y += $h + (S 2)
        }
        $gh = $y + (S 6)
        if ($grp.Height -ne $gh) { $grp.Height = $gh }
        $bottom = $grp.Bottom
    } else { $bottom = $btnDetails.Bottom }
    # Content height, but never taller than the screen: the rest scrolls.
    $content = New-Object Drawing.Size((S $W), ($bottom + (S 12)))
    $form.AutoScrollMinSize = $content
    $maxH = [Windows.Forms.Screen]::FromControl($form).WorkingArea.Height - ($form.Height - $form.ClientSize.Height) - 8
    $cs = New-Object Drawing.Size(($content.Width + $(if ($content.Height -gt $maxH) { [Windows.Forms.SystemInformation]::VerticalScrollBarWidth } else { 0 })),
                                  [Math]::Min($content.Height, $maxH))
    if ($form.ClientSize -ne $cs) { $form.ClientSize = $cs }
    # Keep the whole window on the screen it is on after it grows.
    $wa = [Windows.Forms.Screen]::FromControl($form).WorkingArea
    if ($form.Bottom -gt $wa.Bottom) { $form.Top = [Math]::Max($wa.Top, $wa.Bottom - $form.Height) }
}

$script:DetailsDirty = $true
function Set-Detail([string]$key, [string]$text, [string]$colorKey = 'Fore') {
    $r = $script:DetailRows[$key]
    if (Set-Text $r.Value $text) { $script:DetailsDirty = $true }
    $r.ColorKey = $colorKey
    if ($r.Value.Focused) { return }
    $c = $script:Pal[$colorKey]
    if ($r.Value.ForeColor -ne $c) { $r.Value.ForeColor = $c }
}

Add-Detail 'access'   'Access'
Add-Detail 'warnings' 'Warnings'
Add-Detail 'trigger'  'Arms when'
Add-Detail 'plan'     'Plan'
Add-Detail 'resets'   'Reset credits'
Add-Detail 'credits'  'Paid credits'
Add-Detail 'updated'  'Last usage update'
Add-Detail 'refresh'  'Logs last scanned'
Add-Detail 'resume'   'Last resume'
Add-Detail 'command'  'Resume command'
Add-Detail 'home'     'Codex home'      -IsPath
Add-Detail 'sessions' 'Sessions folder' -IsPath
Add-Detail 'source'   'Reading from'    -IsPath
Add-Detail 'project'  'Project'         -IsPath
Add-Detail 'codexexe' 'Codex CLI'       -IsPath
Add-Detail 'config'   'Config file'     -IsPath
Add-Detail 'log'      'Resume log'      -IsPath

# ---- apply theme ----
function Get-AllControls($root) {
    foreach ($c in $root.Controls) { $c; Get-AllControls $c }
}
function Apply-Theme {
    $script:ThemeName = Get-EffectiveTheme
    $p = Get-Palette $script:ThemeName
    $script:Pal = $p
    $dark = $script:ThemeName -eq 'Dark'
    $hc   = $script:ThemeName -eq 'HighContrast'

    $form.BackColor = $p.Back
    $form.ForeColor = $p.Fore
    try {
        $on = [int]$dark
        [void][CodexResume.Native]::DwmSetWindowAttribute($form.Handle, 20, [ref]$on, 4)
        [void][CodexResume.Native]::DwmSetWindowAttribute($form.Handle, 19, [ref]$on, 4)
    } catch { }

    foreach ($c in Get-AllControls $form) {
        switch ($c.GetType().Name) {
            'Button' {
                $c.FlatStyle = if ($dark) { 'Flat' } else { 'Standard' }
                $c.UseVisualStyleBackColor = -not $dark
                if ($dark) { $c.BackColor = $p.Button } else { $c.BackColor = [Drawing.SystemColors]::Control }
                $c.ForeColor = $p.Fore
                $c.FlatAppearance.BorderColor = $p.Border
                $c.FlatAppearance.BorderSize = if ($c.Focused) { 2 } else { 1 }
            }
            'TextBox' {
                if ($c.Tag -eq 'detail') {
                    $c.BackColor = if ($c.Focused) { $p.Focus } else { $p.Back }
                } else {
                    $c.BackColor = $p.Input; $c.ForeColor = $p.InputFore
                    $c.BorderStyle = if ($dark) { 'FixedSingle' } else { 'Fixed3D' }
                }
            }
            'NumericUpDown' { $c.BackColor = $p.Input; $c.ForeColor = $p.InputFore }
            'DateTimePicker' { $c.CalendarMonthBackground = $p.Input; $c.CalendarForeColor = $p.InputFore }
            'ComboBox' {
                $c.FlatStyle = if ($dark) { 'Flat' } else { 'Standard' }
                $c.BackColor = $p.Input; $c.ForeColor = $p.InputFore
            }
            'CheckBox' {
                $c.FlatStyle = if ($dark) { 'Flat' } else { 'Standard' }
                $c.BackColor = $p.Back; $c.ForeColor = $p.Fore
            }
            'GroupBox' {
                $c.FlatStyle = if ($dark) { 'Flat' } else { 'Standard' }
                $c.BackColor = $p.Back; $c.ForeColor = $p.Fore
            }
            'LinkLabel' {
                $c.BackColor = $p.Back
                $c.LinkColor = $p.Link; $c.ActiveLinkColor = $p.Link; $c.VisitedLinkColor = $p.Link
            }
            'Label' {
                $c.BackColor = $p.Back
                if ($c.Tag -eq 'muted') { $c.ForeColor = $p.Muted }
                elseif ($c.Tag -ne 'status') { $c.ForeColor = $p.Fore }
            }
            'ProgressBar' {
                if ($hc) {
                    [void][CodexResume.Native]::SetWindowTheme($c.Handle, $null, $null)
                } else {
                    # Classic bars accept custom colors; themed ones are always green.
                    [void][CodexResume.Native]::SetWindowTheme($c.Handle, ' ', ' ')
                    [void][CodexResume.Native]::SendMessage($c.Handle, 0x409, [IntPtr]::Zero, (ColorRef $p.Bar))
                    [void][CodexResume.Native]::SendMessage($c.Handle, 0x2001, [IntPtr]::Zero, (ColorRef $p.BarBack))
                }
            }
        }
    }
    foreach ($r in $script:DetailRows.Values) {
        $r.Value.ForeColor = if ($r.Value.Focused) { $p.FocusFore } else { $p[$r.ColorKey] }
    }
    $form.Invalidate($true)
}

# Visible keyboard focus on flat (dark mode) buttons: a thicker accent border.
foreach ($b in @($btnDir, $btnCodex, $btnNow, $btnReset, $btnRef, $btnLog, $btnDetails)) {
    $b.Add_GotFocus({ param($s, $e) $s.FlatAppearance.BorderSize = 2; $s.FlatAppearance.BorderColor = $script:Pal.Link })
    $b.Add_LostFocus({ param($s, $e) $s.FlatAppearance.BorderSize = 1; $s.FlatAppearance.BorderColor = $script:Pal.Border })
}

# Tray icon
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon    = [Drawing.SystemIcons]::Information
$tray.Text    = 'Codex Resume'
$tray.Visible = $true
$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('&Show', $null, { Show-Main })
[void]$menu.Items.Add('&Continue now', $null, { Start-Resume 'manual' })
[void]$menu.Items.Add('E&xit', $null, { $script:ReallyExit = $true; $form.Close() })
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ Show-Main })

function Show-Main { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() }
function Show-Tip([string]$title, [string]$text, [string]$icon = 'Info') {
    $tray.ShowBalloonTip(5000, $title, $text, [Windows.Forms.ToolTipIcon]$icon)
}

# $asOf is set when the numbers are old or could not be re-read, so each bar
# says how current it is.
function Set-Row($bar, $pct, $info, $w, $asOf) {
    if (-not $w) {
        $bar.Value = 0; [void](Set-Text $pct 'no data'); [void](Set-Text $info '')
        $bar.AccessibleDescription = 'No data yet'
        return
    }
    $now = Get-Date
    $used = $w.Used
    $refreshed = $w.ResetAt -and $w.ResetAt -le $now
    if ($refreshed) { $used = 0 }
    $left = [int][Math]::Max(0, [Math]::Min(100, [Math]::Round(100 - $used)))
    $bar.Value = $left
    # After a reset nothing has been logged yet, so the full bar is an estimate.
    if ($refreshed) { [void](Set-Text $pct "about $left% left (estimate)") }
    else { [void](Set-Text $pct ("$left% left ({0:0}% used)" -f $used)) }
    $t = if (-not $w.ResetAt) { '' }
         elseif ($refreshed) { 'Reset at {0:ddd h:mm tt}; usage since then not seen yet' -f $w.ResetAt }
         else { 'Resets {0:ddd MMM d, h:mm:ss tt}  (in {1})' -f $w.ResetAt, (Format-Span ($w.ResetAt - $now)) }
    if ($asOf) { $t = ('{0}  [as of {1:h:mm tt}]' -f $t, $asOf).TrimStart() }
    [void](Set-Text $info $t)
    $bar.AccessibleDescription = "$($pct.Text). $($info.Text)"
}

function Update-UI {
    $script:LastUIUpdate = Get-Date
    $l = $script:Limits
    $p = $script:Pal
    $now = Get-Date
    # Codex writes usage only while it works; if a Codex window is open but
    # nothing has been logged for 10 minutes, the numbers may be behind.
    $silentOpen = $l -and @($script:TargetIds).Count -gt 0 -and ($now - $l.EventTime).TotalMinutes -gt 10
    $stale = $l -and ((Test-Stale $l) -or $silentOpen)
    $asOf = if ($l -and ($stale -or $script:ReadError)) { $l.EventTime } else { $null }
    Set-Row $bar5 $pct5 $info5 $(if ($l) { $l.Primary }) $asOf
    Set-Row $barW $pctW $infoW $(if ($l) { $l.Secondary }) $asOf

    # Most urgent first. $state is a short, non-ticking summary used for the
    # tray and for screen-reader announcements.
    $sKey = 'Green'
    if ($script:Notice -and $now -lt $script:NoticeUntil) {
        $sKey = 'Red'; $sText = "Error: $($script:Notice)"; $state = 'error'
    } elseif ($script:ArmedFor) {
        # Stays on top of a read error, so the countdown is never hidden.
        $at = $script:ArmedFor.AddSeconds([double]$script:Config.BufferSeconds)
        $sKey = 'Red'; $state = 'rate limited'
        $sText = if ($script:Config.AutoResume) {
            'Rate limited. Continuing at {0:h:mm:ss tt} (in {1}).' -f $at, (Format-Span ($at - $now))
        } else { 'Rate limited. Auto-continue is off.' }
        if ($script:ReadError) { $sText += ' Codex logs could not be read just now; see Details.' }
    } elseif ($script:ReadError) {
        $sKey = 'Red'; $sText = "Error reading Codex logs: $($script:ReadError). Showing the last values read."; $state = 'error'
    } elseif (-not $script:FirstScanDone) {
        $sKey = 'Yellow'; $sText = 'Reading Codex logs...'; $state = 'starting'
    } elseif (-not $l) {
        $sKey = 'Yellow'; $sText = 'Waiting for Codex usage data. Run Codex once.'; $state = 'no data'
    } else {
        $age = Format-Age ($now - $l.EventTime)
        if ($silentOpen) {
            $sKey = 'Yellow'; $state = 'stale'
            $sText = 'Stale data: Codex is open but has not logged usage since {0:h:mm tt} ({1}). Numbers may be behind.' -f $l.EventTime, $age
        } elseif ($stale) {
            $sKey = 'Yellow'; $state = 'stale'
            $sText = 'Stale data: last usage update {0:h:mm tt} ({1}). Not rate limited as of then.' -f $l.EventTime, $age
        } else {
            $state = 'OK'
            $sText = 'OK, not rate limited. Last usage update {0:h:mm tt} ({1}).' -f $l.EventTime, $age
        }
    }
    # Warnings stay visible until fixed: on their own when all is otherwise
    # well, or as a pointer next to a more urgent message.
    $nWarn = @($script:Warnings).Count
    if ($nWarn -gt 0) {
        if ($state -in 'OK', 'no data') { $sKey = 'Yellow'; $sText = "Warning: $(@($script:Warnings)[0])"; $state = 'warning' }
        elseif ($state -ne 'error') { $sText += " Also $nWarn warning(s); see Details." }
    }
    if ([string]$script:Config.DisplayUpdate -eq 'Paused') { $sText += ' Display paused; press Refresh to update.' }
    $status.ForeColor = $p[$sKey]
    if (Set-Text $status $sText) { $tips.SetToolTip($status, $sText) }
    if ($state -ne $script:LastState) {
        $script:LastState = $state
        try { $status.AccessibilityObject.RaiseLiveRegionChanged() } catch { }
    }

    # Tray: lead with the state, since Windows cuts the tooltip at 63 characters.
    # Same rule as the bars: after a reset the window counts as full (an estimate).
    $pct = { param($w)
        if (-not $w) { '?' }
        elseif ($w.ResetAt -and $w.ResetAt -le $now) { '~100' }
        else { [int][Math]::Round([Math]::Max(0, 100 - $w.Used)) } }
    $tip = switch ($state) {
        'rate limited' { if ($script:Config.AutoResume) { 'Codex: RATE LIMITED, continues {0:h:mm tt}' -f $at } else { 'Codex: RATE LIMITED, auto-continue off' } }
        'error'        { 'Codex Resume: error, open for details' }
        'warning'      { 'Codex Resume: warning, open for details' }
        'starting'     { 'Codex Resume: reading logs...' }
        'no data'      { 'Codex Resume: no usage data yet' }
        'stale'        { 'Codex: {0}% 5h, {1}% wk left as of {2:h:mm tt}' -f (& $pct $l.Primary), (& $pct $l.Secondary), $l.EventTime }
        default        { 'Codex: {0}% 5h, {1}% wk left' -f (& $pct $l.Primary), (& $pct $l.Secondary) }
    }
    $tray.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
    $icon = switch ($state) { { $_ -in 'rate limited', 'error' } { [Drawing.SystemIcons]::Error } { $_ -in 'warning', 'stale' } { [Drawing.SystemIcons]::Warning } default { [Drawing.SystemIcons]::Information } }
    if ($tray.Icon -ne $icon) { $tray.Icon = $icon }

    # Details
    Set-Detail 'access' $sText $sKey
    Set-Detail 'warnings' $(if (@($script:Warnings).Count) { @($script:Warnings) -join ' ' } else { 'none' }) $(if (@($script:Warnings).Count) { 'Yellow' } else { 'Fore' })
    $trig = 'a window reaches {0}% used, or Codex logs a usage-limit error' -f $script:Config.LimitThreshold
    if ($l -and $l.LimitHitAt) { $trig += '. Usage-limit error seen {0:ddd h:mm tt}.' -f $l.LimitHitAt }
    Set-Detail 'trigger' $trig
    Set-Detail 'plan' $(if ($l -and $l.Plan) { [string]$l.Plan } elseif ($l) { 'not reported by Codex logs' } else { 'unknown' })

    $fromLogs = $null -ne (Get-ResetsFromLogs $l)
    $ra  = Get-ResetsAvailable $l
    $exp = Get-ResetExpiry
    $how = if (([string]$script:Config.UseResetCommand).Trim()) { 'redeemed with your command' } else { 'redeemed on the Usage page' }
    $rKey = 'Fore'
    if ($script:ResetProc) { $rtext = 'Using one now...' }
    elseif ($script:AwaitingManualReset) { $rtext = 'Waiting for you to redeem it on the Usage page, then press Continue now.'; $rKey = 'Yellow' }
    elseif ($null -eq $ra) { $rtext = 'Unknown. Codex logs do not report resets; enter your count under Resets on hand.'; $rKey = 'Yellow' }
    else {
        $src = if ($fromLogs) { 'from Codex' } else { 'entered by you' }
        $rtext = "$ra available ($src)"
        if ($exp -and -not $fromLogs) { $rtext += ', next expires {0:MMM d, yyyy}' -f $exp }
        $rtext += ", $how"
        $rKey = if ($ra -gt 0) { 'Green' } else { 'Fore' }
    }
    Set-Detail 'resets' $rtext $rKey
    Set-Detail 'credits' $(if ($l) { Format-Credits $l.Credits } else { 'unknown' })
    if ($l) {
        $upd = '{0:ddd MMM d, h:mm:ss tt}  ({1} ago)' -f $l.EventTime, (Format-Span ($now - $l.EventTime))
        if ($stale) { $upd += '. Stale: Codex has not logged usage since then.' }
        Set-Detail 'updated' $upd $(if ($stale) { 'Yellow' } else { 'Fore' })
    } else { Set-Detail 'updated' 'never' }
    Set-Detail 'refresh' ('{0:h:mm:ss tt}  (every {1}s; this is when the logs were checked, not how new the data is)' -f $script:LastRefresh, $script:Config.RefreshSeconds)
    $cnt = "$($script:ContinuesSent) automatic continue(s) this run"
    if ([int]$script:Config.MaxContinues -gt 0) { $cnt += " (limit $($script:Config.MaxContinues))" }
    $what = if ($script:LastResumeWhat) { " $($script:LastResumeWhat)." } else { '' }
    Set-Detail 'resume'  $(if ($script:LastResume) { '{0:ddd MMM d, h:mm:ss tt}.{1} {2}' -f $script:LastResume, $what, $cnt } else { "never. $cnt" })
    Set-Detail 'command' (Get-ResumeCommand)
    Set-Detail 'home'     $CodexHome
    Set-Detail 'sessions' $SessionsPath
    Set-Detail 'source'   $(if ($l) { $l.Source } else { '(none yet)' })
    $folder = Get-ResumeFolder
    Set-Detail 'project'  $folder
    [void](Set-Text $txtDir $folder)
    $txtDir.Enabled = $true
    $codexExe = $script:CodexExe
    Set-Detail 'codexexe' $(if ($codexExe) { $codexExe } else { '(not found: use Browse next to Codex CLI)' }) $(if ($codexExe) { 'Fore' } else { 'Red' })
    [void](Set-Text $txtCodex $(if ($codexExe) { $codexExe } else { 'Not found. Click Browse to pick codex.cmd or codex.exe.' }))
    Set-Detail 'config'   $ConfigPath
    Set-Detail 'log'      $LogPath
    if ($script:DetailsDirty) { $script:DetailsDirty = $false; Layout-Details }

    # Keep the on-hand box in sync when the app uses a reset.
    $have = [decimal][Math]::Max(0, [int]$script:Config.ResetsOnHand)
    if ($numHave.Value -ne $have -and -not $numHave.Focused) { $script:SyncingHave = $true; $numHave.Value = $have; $script:SyncingHave = $false }
}

function Restart-App {
    $script:ReallyExit = $true
    Start-Process $WinPowerShell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA',
        '-File', "`"$PSCommandPath`"")
    $form.Close()
}

# Events
$chkAuto.Add_CheckedChanged({ $script:Config.AutoResume = $chkAuto.Checked; Save-Config; Refresh-Limits; Update-UI })
$chkTop.Add_CheckedChanged({ $script:Config.AlwaysOnTop = $chkTop.Checked; $form.TopMost = $chkTop.Checked; Save-Config })
$cmbTheme.Add_SelectedIndexChanged({ $script:Config.Theme = [string]$cmbTheme.SelectedItem; Save-Config; Apply-Theme; Update-UI })
$cmbUpd.Add_SelectedIndexChanged({ $script:Config.DisplayUpdate = [string]$cmbUpd.SelectedItem; Save-Config; Update-UI })
# Changing text size needs a restart; ask first rather than restarting on selection.
$cmbSize.Add_SelectionChangeCommitted({
    $pct = [int](([string]$cmbSize.SelectedItem).TrimEnd('%'))
    if ($pct -eq $scalePct) { return }
    $script:Config.TextScale = $pct; Save-Config
    $ans = [Windows.Forms.MessageBox]::Show($form, "Restart Codex Resume now to show text at $pct%?",
        'Text size', 'YesNo', 'Question')
    if ($ans -eq 'Yes') { Restart-App }
})
$numHave.Add_ValueChanged({
    if ($script:SyncingHave) { return }
    $script:Config.ResetsOnHand = [int]$numHave.Value; Save-Config; Update-UI
})
$dtExp.Add_ValueChanged({
    $script:Config.ResetExpires = if ($dtExp.Checked) { $dtExp.Value.ToString('yyyy-MM-dd') } else { '' }
    Save-Config; Update-UI
})
$txtPrompt.Add_Leave({ $script:Config.Prompt = $txtPrompt.Text; Save-Config })
$txtPrompt.Add_TextChanged({ $script:Config.Prompt = $txtPrompt.Text })
$cmbMode.Add_SelectedIndexChanged({
    foreach ($k in $modeLabels.Keys) { if ($modeLabels[$k] -eq [string]$cmbMode.SelectedItem) { $script:Config.ContinueMode = $k } }
    Update-ModeControls
    Save-Config; Update-UI
})
Update-ModeControls
$cmbTarget.Add_SelectedIndexChanged({
    if ($script:FillingTargets) { return }
    $i = $cmbTarget.SelectedIndex
    if ($script:TargetIds.Count -gt 1 -and $i -ge 1) {
        $script:Config.TargetPid = [int]$script:TargetIds[$i - 1]
        $script:Config.TargetStarted = [string]$script:TargetStarts[$i - 1]
        $script:Notice = $null
    } else { $script:Config.TargetPid = 0; $script:Config.TargetStarted = '' }
    Save-Config; Update-UI
})
$chkClose.Add_CheckedChanged({ $script:Config.CloseOpenCodex = $chkClose.Checked; Save-Config })
$chkFollow.Add_CheckedChanged({ $script:Config.FollowSession = $chkFollow.Checked; Save-Config; Update-UI })
$btnCodex.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Title  = 'Pick the Codex CLI (codex.cmd or codex.exe)'
    $dlg.Filter = 'Codex CLI|codex.cmd;codex.exe;codex.bat|Programs|*.cmd;*.exe;*.bat'
    $cur = $script:CodexExe
    if ($cur) { $dlg.InitialDirectory = Split-Path $cur } else { $dlg.InitialDirectory = Join-Path $env:APPDATA 'npm' }
    if ($dlg.ShowDialog($form) -eq 'OK') {
        $script:Config.CodexPath = $dlg.FileName
        $script:CodexExe = Resolve-Codex
        $script:Notice = $null
        Save-Config; Update-UI
    }
})
$btnDir.Add_Click({
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description  = 'Folder of the Codex project to resume'
    $dlg.SelectedPath = [string]$script:Config.ProjectPath
    if ($dlg.ShowDialog($form) -eq 'OK') {
        $script:Config.ProjectPath = $dlg.SelectedPath
        $script:Config.FollowSession = $false; $chkFollow.Checked = $false
        $script:Notice = $null
        Save-Config; Update-UI
    }
})
$btnNow.Add_Click({
    $script:Config.Prompt = $txtPrompt.Text; Save-Config
    if ($script:AwaitingManualReset) {
        $script:AwaitingManualReset = $false; $script:ArmedFor = $null
        Consume-Reset
    }
    Start-Resume 'manual'
    Update-UI
})
$btnReset.Add_Click({ Use-ResetCredit 'manual'; Update-UI })
$chkReset.Add_CheckedChanged({ $script:Config.UseReset = $chkReset.Checked; Save-Config })
$numReset.Add_ValueChanged({ $script:Config.ResetMinWaitMinutes = [int]$numReset.Value; Save-Config })
$btnLog.Add_Click({ if (-not (Test-Path -LiteralPath $LogPath)) { Write-Log 'Log created' }; Start-Process (Join-Path $env:SystemRoot 'System32\notepad.exe') "`"$LogPath`"" })
$btnRef.Add_Click({ Refresh-Limits; Update-UI })
$btnDetails.Add_Click({ $script:Config.DetailsOpen = -not [bool]$script:Config.DetailsOpen; Save-Config; $script:DetailsDirty = $true; Update-UI })

# Minimise and the X button both hide to the tray, so auto-continue keeps
# working; Exit in the tray menu really quits. The tray hint shows once per run.
function Hide-ToTray {
    $form.Hide()
    if (-not $script:TrayHintShown) {
        $script:TrayHintShown = $true
        Show-Tip 'Codex Resume' 'Still watching from the tray. Right-click the tray icon and choose Exit to quit.'
    }
}
$form.Add_Resize({ if ($form.WindowState -eq 'Minimized') { Hide-ToTray } })
# After the window is dragged (perhaps to a smaller screen), fit it again.
$form.Add_ResizeEnd({ Layout-Details })
$form.Add_FormClosing({
    param($s, $e)
    # None is a plain close message from another program (e.g. the taskbar); treat it like the X button.
    if (-not $script:ReallyExit -and [string]$e.CloseReason -in 'UserClosing', 'None') { $e.Cancel = $true; Hide-ToTray }
})
# Esc hides to the tray, F5 re-reads the logs.
$form.Add_KeyDown({
    param($s, $e)
    # Esc first closes any open list or calendar; only then does it hide the window.
    $ac = $form.ActiveControl
    $popup = ($ac -is [Windows.Forms.ComboBox] -and $ac.DroppedDown) -or $ac -is [Windows.Forms.DateTimePicker]
    if ($e.KeyCode -eq 'Escape' -and -not $popup) { $e.Handled = $true; Hide-ToTray }
    elseif ($e.KeyCode -eq 'F5') { $e.Handled = $true; Refresh-Limits; Update-UI }
})

$script:LastUIUpdate = [datetime]::MinValue
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        $now = Get-Date
        $refreshed = $false
        if (($now - $script:LastRefresh).TotalSeconds -ge [double]$script:Config.RefreshSeconds) {
            Refresh-Limits; $refreshed = $true
            # Follow Windows if the theme is System, or High Contrast was toggled.
            if ((Get-EffectiveTheme) -ne $script:ThemeName) { Apply-Theme }
        }
        if (Receive-CodexScan) { Update-TargetList }
        Check-Reset
        $acted = $false
        if ($script:ArmedFor -and $script:Config.AutoResume -and
            $now -ge $script:ArmedFor.AddSeconds([double]$script:Config.BufferSeconds)) {
            $script:ArmedFor = $null
            Start-Resume 'limit reset'
            $acted = $true
        }
        $every = switch ([string]$script:Config.DisplayUpdate) { 'Every 30 seconds' { 30 } 'Paused' { [double]::PositiveInfinity } default { 1 } }
        if ($acted -or ($now - $script:LastUIUpdate).TotalSeconds -ge $every) { Update-UI }
    } catch {
        try { Write-Log "Tick error: $($_.Exception.Message)" } catch { }
    }
})

$form.Add_FormClosed({
    $timer.Stop()
    if ($script:ScanPS) { try { $script:ScanPS.Stop(); $script:ScanPS.Dispose() } catch { } }
    $tray.Visible = $false
    $tray.Dispose()
    [void][CodexResume.Power]::SetThreadExecutionState($ES_CONTINUOUS)
})

Save-Config
Apply-Theme
Update-UI
# The first scan can take a moment; show the window ("Reading Codex logs...") first.
$form.Add_Shown({
    $form.Refresh()
    Refresh-Limits
    Update-UI
    $timer.Start()
})
[Windows.Forms.Application]::Run($form)
