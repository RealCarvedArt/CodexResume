# CI Gates: CodexResume

Workflow: `.github/workflows/ci.yml`. It runs on push to `main` and on every pull request, with read-only token permissions. Every action is pinned to a commit SHA.

| Gate | Tool | Fails the build on | Status |
|---|---|---|---|
| Parse | PowerShell parser (Windows PowerShell 5.1) | Any parse error | Blocking |
| SAST / lint | PSScriptAnalyzer 1.25.0 via `tools/ci/Invoke-Lint.ps1` | Error-severity findings; any finding from the security rule set (Invoke-Expression, plaintext passwords, broken hashes, unencrypted auth, hardcoded computer names) | Blocking |
| Style | PSScriptAnalyzer warnings outside the security set | Nothing (reported as `warn`) | Advisory |
| Secrets | gitleaks 8.30.1, binary SHA-256 verified, full history | Any leak | Blocking |
| Hostile input | `tools/ci/Test-Hostile.ps1` (17 checks on the real functions: injection, UNC, timing data, config) | Any failed check | Blocking |
| SCA / dependencies | Not applicable: no package dependencies; uses only Windows and .NET Framework built-ins | n/a | n/a |
| SBOM | Not applicable for the same reason. The CI tools are pinned by version and hash instead | n/a | n/a |
| a11y | No automated WinForms checker exists in CI. Accessibility is checked by `ux-reviewer` in each phase 7 audit | n/a | Manual gate |

## Seeded-violation test (2026-10-12, run locally with the same commands)
| Gate | Seed | Result |
|---|---|---|
| Lint | Appended `Invoke-Expression $env:X` to a copy of CodexResume.ps1 | `FAIL ... PSAvoidUsingInvokeExpression`, exit 1 |
| Lint | Unmodified CodexResume.ps1 and Invoke-Lint.ps1 | 0 blocking findings, exit 0 |
| Secrets | Throwaway repo with an AWS-style key pair committed | `leaks found: 2`, exit 1 |
| Secrets | This repo, full history | no leaks, exit 0 |
| Hostile input | v1.0.0 `CodexResume.ps1` | 4 checks fail, exit 1 |
| Hostile input | v1.1 `CodexResume.ps1` | 17 pass, exit 0 |

Verified on GitHub's runners: both jobs green on PR #1 (2026-10-12).

## Suppression log
None.
