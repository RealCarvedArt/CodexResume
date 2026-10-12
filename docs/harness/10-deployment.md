# Phase 10: Deployment (v1.1.0)

Project: CodexResume · Date: 2026-10-12 · Lead: main session · Status: gate passed

## Objective
Publish v1.1.0 as a GitHub release that users can verify and roll back from.

## Key Activities
- [SEC] Merged through PR #1 with both CI jobs green on GitHub (lint, including the hostile-input test, and the secret scan).
- [SEC] Built the zip with `git archive` from the tagged commit, not from a working folder, and published a SHA-256 file next to it.
- [SEC] Turned on branch protection for `main` (required checks: `lint` and `secrets`; no force pushes or deletion) and private vulnerability reporting.
- [PRIV] Release notes explain the settings move, the deletion of the v1.0 log, and the new MaxContinues default.
- [UX] Release notes explain the new window behaviour (close hides to the tray) and the stale-data display.

## Deliverables
| Deliverable | Path / link | Priority it serves |
|---|---|---|
| Release v1.1.0 | GitHub release `v1.1.0`: `CodexResume-v1.1.0.zip` + `.sha256` | SEC / UX |
| Release notes | the release page | PRIV / UX |
| Rollback procedure | release notes; rehearsed in `09-staging-qa.md` | SEC |

## Tools/Best Practices
| Tool or standard | Used for | Priority |
|---|---|---|
| `git archive` from the tag | Reproducible artifact | SEC |
| SHA-256 checksum | Download verification | SEC |
| GitHub branch protection, private vulnerability reporting | Change control, intake | SEC |

## Reasoning

### 1. Security (paramount)
- **No server or infrastructure:** "deployment" means publishing a download.
- **Integrity:** the zip is built from the tagged commit, which went through CI, and users can check it against the published checksum.
- **Change control:** from now on, changes to `main` need the two checks to pass.
- **Immediate rollback trigger:** any report of the app resuming at the wrong time or running something it should not. The fix is to mark v1.1.0 as a pre-release and point users to 1.0.0 (procedure below).

### 2. Privacy
The app runs entirely on the user's PC, so there is no production data or region to confirm. The release notes tell upgrading users that their v1.0 log will be deleted, and why.

### 3. UI/UX
The behaviour changes users will notice are listed at the top of the notes. Users upgrade when they choose to, which is the gradual rollout available for a download.

### Trade-offs
No signed script: there is no code-signing certificate, so the launcher keeps `-ExecutionPolicy Bypass` (R7, awaiting the owner's acceptance).

## Summary/Conclusions
v1.1.0 is published with a checksum, a rehearsed rollback, and protected `main`. Next is phase 11: watch for issues and vulnerability reports.

## Exit Gate
- [x] [SEC] Artifact built from the tagged commit; checksum published; `main` protected
- [x] [PRIV] Logging level and data location as documented (local only; no telemetry)
- [x] [UX] Smoke test of the release build (window, status, tray) passed before release
- [x] Rollback path confirmed available (v1.0.0 release kept; procedure rehearsed)
- [x] User confirmed the release: "fix everything then release" and "i still need the updated release too" (2026-10-12)

## Rollback
1. Choose **Exit** in the tray menu.
2. Extract `CodexResume-v1.0.0.zip`.
3. Copy `%LOCALAPPDATA%\CodexResume\config.json` to `%APPDATA%\CodexResume\`.
