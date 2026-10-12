<#
  CI lint gate. Fails (exit 1) on any parse error, any PSScriptAnalyzer
  Error-severity finding, or any finding from the security rule set below.
  Style warnings are reported but do not fail the build.
#>
param([string[]]$Path = @('CodexResume.ps1'))
$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer

$SecurityRules = @(
    'PSAvoidUsingInvokeExpression'
    'PSAvoidUsingPlainTextForPassword'
    'PSAvoidUsingConvertToSecureStringWithPlainText'
    'PSAvoidUsingUsernameAndPasswordParams'
    'PSUsePSCredentialType'
    'PSAvoidUsingComputerNameHardcoded'
    'PSAvoidUsingAllowUnencryptedAuthentication'
    'PSAvoidUsingBrokenHashAlgorithms'
)

$fail = 0
foreach ($p in $Path) {
    $errs = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path $p), [ref]$null, [ref]$errs)
    foreach ($e in $errs) { Write-Output "PARSE $p`:$($e.Extent.StartLineNumber) $($e.Message)"; $fail++ }

    foreach ($r in (Invoke-ScriptAnalyzer -Path $p)) {
        $blocking = $r.Severity -eq 'Error' -or $SecurityRules -contains $r.RuleName
        $tag = if ($blocking) { 'FAIL' } else { 'warn' }
        Write-Output ("{0} {1}:{2} {3} {4}" -f $tag, $p, $r.Line, $r.RuleName, $r.Message)
        if ($blocking) { $fail++ }
    }
}
Write-Output "Blocking findings: $fail"
exit [int]($fail -gt 0)
