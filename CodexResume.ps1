<#
  Codex Resume
  Tiny tray app that watches your Codex usage windows and resumes your last
  Codex session once the 5-hour (or weekly) limit resets.

  Data source: the rate_limits events Codex CLI writes into
  %USERPROFILE%\.codex\sessions\**\*.jsonl (or $env:CODEX_HOME\sessions).
  Settings and log: %APPDATA%\CodexResume\
#>
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
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
$ES_CONTINUOUS      = [uint32]2147483648
$ES_KEEP_AWAKE      = [uint32]2147483649   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED

# ---------------------------------------------------------------- paths -----
$ConfigDir    = Join-Path $env:APPDATA 'CodexResume'
$ConfigPath   = Join-Path $ConfigDir 'config.json'
$LogPath      = Join-Path $ConfigDir 'resume.log'
$CodexHome    = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$SessionsPath = Join-Path $CodexHome 'sessions'
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

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
        MaxContinues        = 0       # stop after this many automatic continues; 0 = no limit
        TargetPid           = 0       # which Codex window to type into when several are open
        ConfigVersion       = 2
        InteractiveTemplate = 'codex resume {session} {prompt}'
        BackgroundTemplate  = 'codex exec --skip-git-repo-check resume {session} {prompt}'
        CloseOpenCodex      = $true   # close a still-open Codex first (it locks the session)
        # Codex usually logs 99% (not 100%) before refusing, so arm at this level.
        # A "You've hit your usage limit" error in the logs also arms it.
        LimitThreshold  = 99
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
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $j = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        } catch { }
    }
    # Configs saved before typing mode existed: switch them to it.
    $ver = 1; try { if ($j -and $j.ConfigVersion) { $ver = [int]$j.ConfigVersion } } catch { }
    if ($ver -lt 2) { $cfg.ContinueMode = 'Type'; $cfg.ConfigVersion = 2 }
    # Older versions used a single CommandTemplate; replaced by the modes.
    if ($cfg.ContainsKey('CommandTemplate')) { $cfg.Remove('CommandTemplate') }
    $cfg
}
function Save-Config { $script:Config | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8 }
function Write-Log([string]$msg) {
    Add-Content -LiteralPath $LogPath -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $msg)
}

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
    foreach ($f in $files) {
        if ($f.LastWriteTime -le $since) { continue }
        foreach ($line in (Read-Tail $f.FullName 262144)) {
            if ($line -notmatch $LimitPattern) { continue }
            $t = $null
            try { $t = Get-EventTime ($line | ConvertFrom-Json) $f.LastWriteTime } catch { $t = $f.LastWriteTime }
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
    try {
        $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            for ($n = 0; $n -lt 50; $n++) {
                $line = $sr.ReadLine(); if ($null -eq $line) { break }
                if ($line -notmatch '"cwd"') { continue }
                try { $o = $line | ConvertFrom-Json } catch { continue }
                foreach ($c in @($o.payload.cwd, $o.cwd)) { if ($c) { return [string]$c } }
            }
        } finally { $fs.Dispose() }
    } catch { }
    $null
}

# Session id: the UUID at the end of the rollout file name, or session_meta id.
function Get-SessionId([string]$path) {
    $name = [IO.Path]::GetFileNameWithoutExtension($path)
    if ($name -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$') { return $Matches[1] }
    try {
        $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            for ($n = 0; $n -lt 20; $n++) {
                $line = $sr.ReadLine(); if ($null -eq $line) { break }
                if ($line -notmatch 'session_meta') { continue }
                $o = $line | ConvertFrom-Json
                if ($o.payload.id) { return [string]$o.payload.id }
            }
        } finally { $fs.Dispose() }
    } catch { }
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
function Get-OpenCodex {
    try { $all = @(Get-CimInstance Win32_Process -ErrorAction Stop) } catch { return @() }
    $byId = @{}; foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
    $isCodex = { param($p) $p -and $p.Name -like 'codex*.exe' }
    $out = foreach ($p in $all) {
        if (-not (& $isCodex $p)) { continue }
        if ($NonTuiCommands -contains (Get-CodexSubcommand ([string]$p.CommandLine))) { continue }
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
        [pscustomobject]@{ ProcessId = [int]$p.ProcessId; Started = $started; Host = $where; CommandLine = [string]$p.CommandLine }
    }
    @($out)
}

function Format-CodexChoice($c) {
    $t = if ($c.Started) { '{0:ddd h:mm tt}' -f $c.Started } else { 'unknown time' }
    'PID {0}, started {1}, {2}' -f $c.ProcessId, $t, $c.Host
}

# The Codex window to type into: your pick if it is still running, or the only
# one open. Returns @{ Target; Open } where Target may be $null.
function Get-TargetCodex {
    $open = @(Get-OpenCodex)
    $pick = [int]$script:Config.TargetPid
    $t = $open | Where-Object { $_.ProcessId -eq $pick } | Select-Object -First 1
    if (-not $t -and $open.Count -eq 1) { $t = $open[0] }
    [pscustomobject]@{ Target = $t; Open = $open }
}

# Keystroke helper: a tiny Windows program (no console of its own) that
# attaches to the Codex console and writes key presses into its input, exactly
# as if typed on the keyboard. No window focus needed, and it cannot type into
# any other window. Compiled once with the C# compiler built into Windows.
$TypeHelperVersion = 2
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

    // Arguments: <pid> <text> [charDelayMs] [enterDelayMs]
    static int Main(string[] a) {
        if (a.Length < 2) return 10;
        uint pid; if (!uint.TryParse(a[0], out pid)) return 10;
        string text = a[1];
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
    Test-Path -LiteralPath $TypeHelperExe
}

# Types $text + Enter into the console of Codex process $procId. Returns $true on success.
# Exit codes: 2 = could not attach to that console, 3 = no console input,
# 4 = writing keys failed, 10 = bad arguments, 20 = helper could not be built.
function Send-ToCodex([int]$procId, [string]$text) {
    if (-not (Ensure-TypeHelper)) { $script:TypeExit = 20; return $false }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $TypeHelperExe
    # Windows argument quoting: escape quotes, and double backslashes before a quote or the end.
    $quoted = '"' + (($text -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
    $psi.Arguments = '{0} {1} {2} {3}' -f $procId, $quoted, [int]$script:Config.TypeCharDelayMs, [int]$script:Config.TypeEnterDelayMs
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
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
    Update-PathFromRegistry
    $cmd = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue |
           Where-Object { $_.Source -match '\.(cmd|exe|bat)$' } | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
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
    $null
}

# Folder Codex will be resumed in.
function Get-ResumeFolder {
    if ($script:Config.FollowSession -and $script:Limits -and $script:Limits.Cwd -and
        (Test-Path -LiteralPath $script:Limits.Cwd)) { return [string]$script:Limits.Cwd }
    [string]$script:Config.ProjectPath
}

function Get-RateLimits {
    if (-not (Test-Path -LiteralPath $SessionsPath)) { return $null }
    $files = Get-ChildItem -LiteralPath $SessionsPath -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 5
    foreach ($f in $files) {
        $lines = Read-Tail $f.FullName
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
            return [pscustomobject]@{
                Primary    = $p
                Secondary  = $s
                Plan       = $rl.plan_type
                Credits    = $rl.credits
                EventTime  = $t
                Source     = $f.FullName
                LimitHitAt = (Find-LimitError $files $t)
                Cwd        = (Get-SessionCwd $f.FullName $lines)
                SessionId  = (Get-SessionId $f.FullName)
            }
        }
    }
    $null
}

# A window is blocking when it reaches the threshold. If both are, wait for the
# later reset. If Codex logged a usage-limit error but no window is over the
# threshold, the fullest window is the one that ran out.
function Get-BlockingReset($l) {
    if (-not $l) { return $null }
    $now = Get-Date
    $th = [double]$script:Config.LimitThreshold
    if ($th -le 0 -or $th -gt 100) { $th = 99 }
    $w = @($l.Primary, $l.Secondary) | Where-Object { $_ -and $_.ResetAt -and $_.ResetAt -gt $now }
    if (-not $w) { return $null }
    $b = @($w | Where-Object { $_.Used -ge $th })
    if (-not $b -and $l.LimitHitAt) { $b = @($w | Sort-Object Used -Descending | Select-Object -First 1) }
    if (-not $b) { return $null }
    ($b | Sort-Object ResetAt -Descending | Select-Object -First 1).ResetAt
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
function Get-SessionArg {
    if ($script:Limits -and $script:Limits.SessionId) { [string]$script:Limits.SessionId } else { '--last' }
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
            if ($reason -ne 'manual') { $script:ContinuesSent++ }
            Write-Log "Typed '$($cfg.Prompt)' into Codex (pid $procId) ($reason)"
            Show-Tip 'Codex continued' "Typed '$($cfg.Prompt)' into your Codex window." 'Info'
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
        Write-Log "Resume skipped ($reason): folder not found: $dir"
        Set-Notice "Could not continue: project folder not found ($dir). Choose a folder with Browse."
        Show-Tip 'Codex Resume' "Project folder not found: $dir" 'Error'
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
        } catch { }
        Start-Sleep -Seconds 2   # let it release the session lock
    }

    # Run the exact executable found, so PATH differences cannot break it.
    $cmd = (Get-CommandTemplate).Replace('{session}', (Get-SessionArg)).Replace('{prompt}', '$prompt')
    $cmd = $cmd -replace '^\s*codex(\.cmd|\.exe)?(?=\s|$)', '& $$codex'
    $runner = Join-Path $ConfigDir 'run-resume.ps1'
    $safeDir = $dir -replace "'", "''"
    $safeCodex = $codex -replace "'", "''"
    $body = @"
`$Host.UI.RawUI.WindowTitle = 'Codex Resume'
`$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
Set-Location -LiteralPath '$safeDir'
`$codex = '$safeCodex'
`$prompt = @'
$($cfg.Prompt)
'@
Write-Host "Resuming Codex in `$PWD ..." -ForegroundColor Cyan
Write-Host "Using `$codex" -ForegroundColor DarkGray
$cmd
"@
    Set-Content -LiteralPath $runner -Value $body -Encoding UTF8
    Start-Process powershell.exe -WorkingDirectory $dir -ArgumentList @(
        '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$runner`"")
    $script:LastResume = Get-Date
    if ($reason -ne 'manual') { $script:ContinuesSent++ }
    Write-Log "Resumed ($reason) in $dir :: $cmd"
    Show-Tip 'Codex resumed' "Sent '$($cfg.Prompt)' to your last session." 'Info'
}

function Use-ResetCredit([string]$reason) {
    $cfg = $script:Config
    $script:ResetTriedFor = $script:ArmedFor
    $cmd = [string]$cfg.UseResetCommand
    if ($cmd.Trim()) {
        Write-Log "Using reset credit ($reason): $cmd"
        $script:ResetProc = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
        Show-Tip 'Codex Resume' 'Using a reset credit...' 'Info'
    } else {
        Write-Log "Opened usage page to redeem a reset ($reason)"
        Start-Process ([string]$cfg.UsagePageUrl)
        $script:AwaitingManualReset = $true
        Show-Tip 'Use your reset' 'Click "Use reset" on the Usage page, then press Continue now.' 'Info'
        Show-Main
    }
}

# Called each tick: decides whether to spend a reset, and handles the result.
function Check-Reset {
    $p = $script:ResetProc
    if ($p -and $p.HasExited) {
        $script:ResetProc = $null
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
    try { if ($cmbTarget) { Update-TargetList } } catch { }
    try { $script:CodexExe = Resolve-Codex } catch { $script:CodexExe = $null }
    try {
        $script:Limits = Get-RateLimits
        $script:ReadError = $null
    } catch {
        $script:ReadError = $_.Exception.Message
    }
    # Only arm when we see a reset that is still in the future, so stale data
    # from an old session never triggers a surprise resume.
    $r = Get-BlockingReset $script:Limits
    if ($r -and $r -gt (Get-Date) -and $script:ArmedFor -ne $r) {
        $script:ArmedFor = $r
        Write-Log ('Armed: limit resets at {0:G}' -f $r)
    }
    $flags = if ($script:ArmedFor -and $script:Config.AutoResume -and $script:Config.KeepAwake) { $ES_KEEP_AWAKE } else { $ES_CONTINUOUS }
    [void][CodexResume.Power]::SetThreadExecutionState($flags)
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
$status = Add-Ctl Label @{ Location = (Pt 12 106); Size = (Sz 576 36); Font = $bold; Tag = 'status'
                           AccessibleName = 'Status'; AccessibleRole = 'StatusBar'; UseMnemonic = $false }

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

# Fills the Target list. Leaves it alone while it is open or nothing changed.
function Update-TargetList {
    if ($cmbTarget.DroppedDown) { return }
    $open = @(Get-OpenCodex)
    $ids = @($open | ForEach-Object { $_.ProcessId })
    if (($ids -join ',') -eq ($script:TargetIds -join ',') -and $cmbTarget.Items.Count -gt 0) { return }
    $script:TargetIds = $ids
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
$grp = Add-Ctl GroupBox @{ Text = 'Details'; Location = (Pt 12 460); Size = (Sz 576 300) }
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
    $val.Add_GotFocus({ param($s, $e) $s.BackColor = $script:Pal.Focus; $s.ForeColor = $script:Pal.FocusFore })
    $val.Add_LostFocus({
        param($s, $e)
        $s.BackColor = $script:Pal.Back
        foreach ($r in $script:DetailRows.Values) { if ($r.Value -eq $s) { $s.ForeColor = $script:Pal[$r.ColorKey] } }
    })
    $open = $null
    if ($IsPath) {
        $open = Add-Ctl LinkLabel @{ Text = 'Open'; Location = (Pt ($ValX + $PathW + 8) 0); Size = (Sz 44 18)
                                     AccessibleName = "Open $caption in Explorer"; UseMnemonic = $false } $grp
        $open.Tag = $val
        $open.Add_LinkClicked({
            param($sender, $e)
            $p = [string]$sender.Tag.Text
            if (-not $p -or $p -like '(*') { return }
            if (Test-Path -LiteralPath $p -PathType Leaf) { Start-Process explorer.exe "/select,`"$p`"" }
            elseif (Test-Path -LiteralPath $p) { Start-Process explorer.exe "`"$p`"" }
            else { Set-Notice "Not found: $p"; Update-UI }
        })
        $tips.SetToolTip($open, 'Open in Explorer')
    }
    $script:DetailRows[$key] = [pscustomobject]@{ Caption = $cap; Value = $val; Open = $open; ColorKey = 'Fore' }
}

function Layout-Details {
    $y = S 24
    foreach ($r in $script:DetailRows.Values) {
        $t = if ($r.Value.Text) { $r.Value.Text } else { ' ' }
        $m = [Windows.Forms.TextRenderer]::MeasureText($t, $r.Value.Font, (New-Object Drawing.Size($r.Value.Width, 0)), $script:DetailFlags)
        $h = [Math]::Max((S 18), $m.Height + 2)
        if ($r.Caption.Top -ne $y) { $r.Caption.Top = $y }
        if ($r.Value.Top -ne $y)   { $r.Value.Top = $y }
        if ($r.Value.Height -ne $h) { $r.Value.Height = $h }
        if ($r.Open -and $r.Open.Top -ne $y) { $r.Open.Top = $y }
        $y += $h + (S 4)
    }
    $gh = $y + (S 6)
    if ($grp.Height -ne $gh) { $grp.Height = $gh }
    $cs = New-Object Drawing.Size((S $W), ($grp.Bottom + (S 12)))
    if ($form.ClientSize -ne $cs) { $form.ClientSize = $cs }
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
Add-Detail 'trigger'  'Arms when'
Add-Detail 'plan'     'Plan'
Add-Detail 'resets'   'Reset credits'
Add-Detail 'credits'  'Paid credits'
Add-Detail 'updated'  'Last usage update'
Add-Detail 'refresh'  'Last file check'
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
foreach ($b in @($btnDir, $btnCodex, $btnNow, $btnReset, $btnRef, $btnLog)) {
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
[void]$menu.Items.Add('E&xit', $null, { $form.Close() })
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ Show-Main })

function Show-Main { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() }
function Show-Tip([string]$title, [string]$text, [string]$icon = 'Info') {
    $tray.ShowBalloonTip(5000, $title, $text, [Windows.Forms.ToolTipIcon]$icon)
}

function Set-Row($bar, $pct, $info, $w) {
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
    [void](Set-Text $pct ("$left% left ({0:0}% used)" -f $used))
    if (-not $w.ResetAt) { [void](Set-Text $info '') }
    elseif ($refreshed) { [void](Set-Text $info ('Reset at {0:ddd MMM d, h:mm tt}, window has refreshed' -f $w.ResetAt)) }
    else { [void](Set-Text $info ('Resets {0:ddd MMM d, h:mm:ss tt}  (in {1})' -f $w.ResetAt, (Format-Span ($w.ResetAt - $now)))) }
    $bar.AccessibleDescription = "$($pct.Text). $($info.Text)"
}

function Update-UI {
    $script:LastUIUpdate = Get-Date
    $l = $script:Limits
    $p = $script:Pal
    Set-Row $bar5 $pct5 $info5 $(if ($l) { $l.Primary })
    Set-Row $barW $pctW $infoW $(if ($l) { $l.Secondary })
    $now = Get-Date

    $sKey = 'Green'
    if ($script:Notice -and $now -lt $script:NoticeUntil) {
        $sKey = 'Red'; $sText = "Error: $($script:Notice)"
    } elseif ($script:ReadError) {
        $sKey = 'Red'; $sText = "Error reading Codex logs: $($script:ReadError)"
    } elseif (-not $l) {
        $sKey = 'Yellow'; $sText = 'Waiting for Codex usage data. Run Codex once.'
    } elseif ($script:ArmedFor) {
        $at = $script:ArmedFor.AddSeconds([double]$script:Config.BufferSeconds)
        $sKey = 'Red'
        $sText = if ($script:Config.AutoResume) {
            'Rate limited. Continuing at {0:h:mm:ss tt} (in {1}).' -f $at, (Format-Span ($at - $now))
        } else { 'Rate limited. Auto-continue is off.' }
    } else {
        $sText = 'OK, not rate limited. Last usage update {0:h:mm tt}.' -f $l.EventTime
    }
    if ([string]$script:Config.DisplayUpdate -eq 'Paused') { $sText += ' Display paused; press Refresh to update.' }
    $status.ForeColor = $p[$sKey]
    [void](Set-Text $status $sText)

    # Details
    Set-Detail 'access' $sText $sKey
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
    Set-Detail 'updated' $(if ($l) { '{0:ddd MMM d, h:mm:ss tt}  ({1} ago)' -f $l.EventTime, (Format-Span ($now - $l.EventTime)) } else { 'never' })
    Set-Detail 'refresh' ('{0:h:mm:ss tt}  (every {1}s)' -f $script:LastRefresh, $script:Config.RefreshSeconds)
    $cnt = "$($script:ContinuesSent) automatic continue(s) this run"
    if ([int]$script:Config.MaxContinues -gt 0) { $cnt += " (limit $($script:Config.MaxContinues))" }
    Set-Detail 'resume'  $(if ($script:LastResume) { '{0:ddd MMM d, h:mm:ss tt}. {1}' -f $script:LastResume, $cnt } else { "never. $cnt" })
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

    $tip = "Codex: $([Math]::Round($bar5.Value))% (5h), $([Math]::Round($barW.Value))% (wk) left"
    $tray.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
}

function Restart-App {
    Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA',
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
        $script:Notice = $null
    } else { $script:Config.TargetPid = 0 }
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
$btnLog.Add_Click({ if (-not (Test-Path -LiteralPath $LogPath)) { Write-Log 'Log created' }; Start-Process notepad.exe $LogPath })
$btnRef.Add_Click({ Refresh-Limits; Update-UI })
$form.Add_Resize({ if ($form.WindowState -eq 'Minimized') { $form.Hide(); Show-Tip 'Codex Resume' 'Still watching from the tray. Press Windows+B to reach the tray.' } })

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
    $tray.Visible = $false
    $tray.Dispose()
    [void][CodexResume.Power]::SetThreadExecutionState($ES_CONTINUOUS)
})

Save-Config
Apply-Theme
Refresh-Limits
Update-UI
$timer.Start()
[Windows.Forms.Application]::Run($form)
