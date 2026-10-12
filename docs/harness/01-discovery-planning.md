# Phase 01: Discovery & Planning (retroactive)

Project: CodexResume · Date: 2026-10-12 · Lead: main session · Status: retroactive, gate partly met

## Objective
Record what CodexResume is for and who uses it, so later phases have something to check against. The app was written before the harness was adopted. This record describes the shipped app (commit a7b28f6). It does not invent a plan after the fact.

## Key Activities
- [SEC] Listed assets, actors, and risks in `docs/security/threat-register.md`.
- [SEC] Authentication and authorization: none needed. It is a single-user local app with no accounts and no network service.
- [PRIV] Personal data in scope: Codex session transcripts (read), the app log and config (written). The full inventory is in phase 7 (`docs/privacy/data-inventory.md`).
- [PRIV] Applicable regimes: none as a data controller. All data stays on the user's own machine and is not sent anywhere.
- [UX] Persona and journeys (below); accessibility target WCAG 2.2 AA, applied to a WinForms desktop UI.
- Scope taken from README.md and the script header.

**Persona.** A developer on Windows using Codex CLI or the IDE extension, who hits the 5-hour or weekly limit and wants work to continue on its own once the limit resets.

**Top journeys.**
1. See how much of each usage window is left, and when it resets.
2. Hit the limit, then have the app resume Codex automatically after the reset (by typing into the open window, or launching a new one).
3. Optionally spend a banked reset credit when the wait is long.
4. Change settings: folder, prompt, mode, theme, text size.

**Trust moments.** The app typing into a terminal on its own; the app running a command the user configured; the app spending a paid reset credit.

**Non-goals.** No network calls of its own; no editing of Codex files; no handling of credentials.

## Deliverables
| Deliverable | Path / link | Priority it serves |
|---|---|---|
| Threat register | `docs/security/threat-register.md` | SEC |
| Data inventory (made in phase 7) | `docs/privacy/data-inventory.md` | PRIV |
| Persona and journeys | this record | UX |

## Tools/Best Practices
| Tool or standard | Used for | Priority |
|---|---|---|
| STRIDE (light) | Assets, actors, risks | SEC |
| OWASP ASVS 4.0, Level 1, desktop-relevant chapters (V5, V7, V12, V14) | Security target | SEC |
| Data minimization (privacy by design) | Inventory challenge | PRIV |
| WCAG 2.2 AA | Accessibility target | UX |

## Reasoning

### 1. Security (paramount)
The app has no listening socket and no accounts, so the attack surface is local:
- strings the app reads from session files and config;
- processes it starts;
- keystrokes it injects into other windows.

The costliest risks to fix later are command injection (R1) and keystrokes reaching the wrong window (R2), because both run with the user's full rights. ASVS Level 1 is enough for a local single-user tool. Only the input-handling, logging, file, and configuration chapters apply; the authentication, session, and access-control chapters have nothing to act on.

### 2. Privacy
The app does not need transcript content. It needs only the rate-limit numbers, timestamps, the session id, and the working folder. Minimization therefore means: read only those fields, never copy prompts or code into the log or the UI, and keep local files bounded. No regulation applies in the controller sense, because the data never leaves the user's machine. A DPIA (data protection impact assessment) is not needed.

### 3. UI/UX
Journey 2 carries the trust risk: the app acts on the user's behalf while they are away. The status has to be accurate and has to show how old its data is. The 2026-10-12 bug (stuck at "23% left" and "OK" after the limit was hit) is a failure of exactly this. WCAG 2.2 AA is the target because the app relies on color-coded status and a progress bar, which must also work with a screen reader and in high-contrast mode.

### Trade-offs
None between priorities at this phase.

## Summary/Conclusions
Scope, persona, journeys, and the WCAG target are recorded, and the threat register exists with an owner. The ASVS target is L1 (desktop-relevant chapters). Data categories are deferred to the phase 7 privacy review, which reads the code instead of guessing. Scope still needs the user's approval.

## Exit Gate
- [x] [SEC] Threat register has assets, actors, and top risks with owners
- [x] [SEC] ASVS target level chosen and justified (L1, desktop-relevant chapters)
- [ ] [PRIV] Every data category has purpose, basis, retention; DPIA need decided (DPIA: not needed; inventory pending phase 7 privacy review)
- [x] [UX] Personas, top journeys, and WCAG target documented
- [ ] User has approved scope

Verified by: retroactive record; security items re-checked in the phase 7 audit.
