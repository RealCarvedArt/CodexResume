<#
  CI test: feeds hostile session-file and config values through the real
  functions of CodexResume.ps1 and fails (exit 1) if any of them can run code,
  add arguments, reach the network or arm the app on bad data.
  Runs without the UI: functions are loaded from the script's syntax tree.
#>
param([string]$Script = 'CodexResume.ps1')
$ErrorActionPreference = 'Stop'
$work = Join-Path ([IO.Path]::GetTempPath()) ("cr-hostile-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
$script:Failures = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Output "PASS $name" } else { Write-Output "FAIL $name $detail"; $script:Failures++ }
}

# Load every function except the ones that touch the UI or the real system.
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Script), [ref]$null, [ref]$null)
$stub = 'Write-Log', 'Show-Tip', 'Set-Notice', 'Show-Main', 'Resolve-Codex', 'Get-OpenCodex', 'Update-UI'
$ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    Where-Object { $stub -notcontains $_.Name } | ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
$script:Notices = @()
function Write-Log { } function Show-Tip { } function Show-Main { } function Get-OpenCodex { @() }
function Set-Notice($t) { $script:Notices += $t }

# A console program that prints its arguments as JSON, standing in for codex.exe.
$echo = Join-Path $work 'echoargs.exe'
Add-Type -OutputAssembly $echo -OutputType ConsoleApplication -TypeDefinition @'
public static class EchoArgs {
    public static void Main(string[] a) {
        var s = new System.Text.StringBuilder("ARGS");
        foreach (var x in a) s.Append('\u0001').Append(x);
        System.Console.WriteLine(s.ToString());
    }
}
'@
function Resolve-Codex { $echo }

$ConfigDir = Join-Path $work 'cfg'; New-Item -ItemType Directory $ConfigDir | Out-Null
$WinPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ConfigPath = Join-Path $ConfigDir 'config.json'; $LogPath = Join-Path $ConfigDir 'resume.log'
$script:ContinuesSent = 0

try {
# 1. Session id from inside a file must be a plain UUID.
$script:Limits = [pscustomobject]@{ SessionId = '--last; calc.exe #'; Cwd = $null }
Check 'planted session id becomes --last' ((Get-SessionArg) -eq '--last')
$script:Limits.SessionId = '3f2b8c1e-4d5a-4b6c-9e7f-0a1b2c3d4e5f'
Check 'real UUID is kept' ((Get-SessionArg) -eq '3f2b8c1e-4d5a-4b6c-9e7f-0a1b2c3d4e5f')

# 2. Folder from a session file: local drive paths only.
$script:Config = @{ FollowSession = $true; ProjectPath = 'C:\fallback' }
# Test-Path on a UNC path would itself contact the host, so record every call.
$script:Probed = @()
function Test-Path { param([string]$LiteralPath, $PathType) $script:Probed += $LiteralPath; $true }
$script:Limits = [pscustomobject]@{ SessionId = $null; Cwd = '\\attacker\share' }
$f = Get-ResumeFolder
Remove-Item Function:\Test-Path
Check 'UNC folder is ignored' ($f -eq 'C:\fallback') "got $f"
Check 'UNC folder is never probed' (@($script:Probed | Where-Object { $_ -like '\\*' }).Count -eq 0) ($script:Probed -join ', ')

# 3. End to end: hostile folder name, session id and prompt reach the program
#    as plain arguments, and nothing else runs.
$evil = Join-Path $work ("a" + [char]0x2019 + ";New-Item PWNED1;" + [char]0x2019)
[void][IO.Directory]::CreateDirectory($evil)
$prompt = "go'@`nNew-Item PWNED2`n'@ & echo %USERNAME% `"q`" \"
$script:Limits = [pscustomobject]@{ SessionId = '--last; New-Item PWNED3 #'; Cwd = $evil }
$script:Config = @{ ContinueMode = 'Interactive'; MaxContinues = 0; CloseOpenCodex = $true; FollowSession = $true
                    InteractiveTemplate = 'codex resume {session} {prompt}'; Prompt = $prompt }
function Start-Process { param($FilePath, $WorkingDirectory, $ArgumentList)
    $script:RunnerOut = & $FilePath -NoProfile -ExecutionPolicy Bypass -File ($ArgumentList[4].Trim('"')) -DataPath ($ArgumentList[6].Trim('"')) 2>&1 }
Start-Resume 'ci'
# The prompt has line breaks, so rejoin the output before splitting on the separator.
$all = (@($script:RunnerOut) | ForEach-Object { "$_" }) -join "`n"
$i = $all.IndexOf('ARGS')
$got = if ($i -ge 0) { @($all.Substring($i).TrimEnd("`r", "`n").Split([char]1) | Select-Object -Skip 1) } else { @() }
Check 'program got exactly 3 arguments' ($got.Count -eq 3) "got $($got.Count): $($got -join ' | ')"
Check 'session argument is --last' ($got[1] -eq '--last')
Check 'prompt arrives unchanged' ($got[2] -eq $prompt) "got [$($got[2])]"
Check 'no injected command ran' (@(Get-ChildItem -Recurse $work -Filter 'PWNED*').Count -eq 0)
Check 'runner holds no values' (-not (Select-String -LiteralPath (Join-Path $ConfigDir 'run-resume.ps1') -Pattern 'PWNED|calc|go' -Quiet))
Check 'data file deleted' (-not (Test-Path (Join-Path $ConfigDir 'run-resume.json')))

# 4. Bad timing data cannot arm the app.
$t = Get-Date
$far = Convert-Window ([pscustomobject]@{ used_percent = 99; window_minutes = 300
                                          resets_at = ([DateTimeOffset]$t.AddDays(30)).ToUnixTimeSeconds() }) $t
Check 'reset beyond the window length is dropped' ($null -eq $far.ResetAt)
$CodexHome = $work; $SessionsPath = Join-Path $work 'sessions'; New-Item -ItemType Directory $SessionsPath | Out-Null
$LimitPattern = 'hit your usage limit|usage_limit_reached|usage limit reached'; $script:SessionCache = @{}
function Ev($ts, $pct) { '{"timestamp":"' + $ts + '","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":' + $pct + ',"window_minutes":300,"resets_at":' + ([DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()) + '}}}}' }
Set-Content (Join-Path $SessionsPath 'real.jsonl') (Ev ((Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o')) 40)
Set-Content (Join-Path $SessionsPath 'planted.jsonl') (Ev '2099-01-01T00:00:00Z' 99)
$r = Get-RateLimits
Check 'future-dated event is ignored' ($r -and $r.Primary.Used -eq 40) "used=$($r.Primary.Used)"

$noLen = Convert-Window ([pscustomobject]@{ used_percent = 99
                                            resets_at = ([DateTimeOffset]$t.AddDays(30)).ToUnixTimeSeconds() }) $t
Check 'reset 30 days out with no window length is dropped' ($null -eq $noLen.ResetAt)

# 4a. After the 5-hour window resets, an old usage-limit error must not move
#     the wait to the weekly reset, and a reset that has arrived is not replaced.
$script:Config = @{ LimitThreshold = 99; AutoResume = $true; BufferSeconds = 60 }
$now = Get-Date
$five = [pscustomobject]@{ Used = 100; ResetAt = $now.AddMinutes(-1) }
$week = [pscustomobject]@{ Used = 40;  ResetAt = $now.AddDays(5) }
$l = [pscustomobject]@{ Primary = $five; Secondary = $week; LimitHitAt = $now.AddHours(-4) }
Check 'old limit error is cleared by the 5-hour reset' ($null -eq (Get-BlockingReset $l))
$l.LimitHitAt = $now.AddSeconds(-10)
Check 'limit error after the reset still counts' ((Get-BlockingReset $l) -eq $week.ResetAt)
$five.ResetAt = $now.AddHours(2); $l.LimitHitAt = $now.AddMinutes(-5)
Check 'limit error before the reset waits for the fullest window' ((Get-BlockingReset $l) -eq $five.ResetAt)

# 4b. A program run through cmd.exe never gets characters cmd.exe would change.
$cmdStub = Join-Path $work 'codex.cmd'; Set-Content $cmdStub '@echo off'
function Resolve-Codex { $cmdStub }
$script:Notices = @(); $script:RunnerOut = $null
$script:Config = @{ ContinueMode = 'Interactive'; MaxContinues = 0; CloseOpenCodex = $true; FollowSession = $false
                    ProjectPath = $work; InteractiveTemplate = 'codex resume {prompt}'; Prompt = "line one`nline two" }
Start-Resume 'ci'
Check 'line break refused when cmd.exe would run Codex' (-not $script:RunnerOut -and ($script:Notices -join ' ') -like '*cmd.exe*')
function Resolve-Codex { $echo }

# 5. A broken config starts safely.
Set-Content $ConfigPath '{ "AutoResume": true, broken'
$script:ConfigError = $null
$c = Load-Config
Check 'broken config turns auto-continue off' ($c.AutoResume -eq $false -and $script:ConfigError)

# 6. Upgraded settings get the limit on automatic continues; a deliberate 0 later is kept.
Set-Content $ConfigPath '{ "MaxContinues": 0, "ConfigVersion": 2, "RefreshSeconds": 1 }'
$c = Load-Config
Check 'pre-1.1 config gets MaxContinues 10 and a 5 s refresh floor' ($c.MaxContinues -eq 10 -and $c.RefreshSeconds -eq 5 -and $c.ConfigVersion -eq 3)
Set-Content $ConfigPath '{ "MaxContinues": 0, "ConfigVersion": 3 }'
Check 'MaxContinues 0 chosen in 1.1 is kept' ((Load-Config).MaxContinues -eq 0)

} catch { Check 'test run finished' $false $_.Exception.Message }

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Output "Failures: $script:Failures"
exit [int]($script:Failures -gt 0)
