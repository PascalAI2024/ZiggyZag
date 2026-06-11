# Wave Deployment Plan

How ZiggyZag ships: in waves, with explicit entry gates, rollback criteria, and a friend-tester cohort that grows with each release.

This document is the operational counterpart to [`masterplan.md`](masterplan.md). Waves are not dates — they are configurations of the project that meet specific gates. A wave is reached when every gate is green; it is not reached on a calendar.

Companion documents: [`alpha-tasks.md`](alpha-tasks.md) is the line-by-line task list, [`daily-driver-qa.md`](../guides/daily-driver-qa.md) is the manual QA checklist, [`release-checklist.md`](../guides/release-checklist.md) is the per-tag procedure.

## Wave overview

| Wave | Codename | Audience | Headline | Status |
| --- | --- | --- | --- | --- |
| 1 | Dogfood | Pascal only | Pascal uses ZiggyZag every day | Complete |
| 2 | Unified theme | Pascal + reviewer | One theme drives shell + desktop · brand · landing · ops | **Complete — tagged `v0.1.0-alpha.3`** |
| 3 | Cross-platform | 3 friend testers | Native macOS & Linux desktop · AgentD universal input | **Active — macOS window shipped 2026-06-10; Linux native window + friend-tester cohort remaining** |
| 4 | Durable state | 6 friend testers | SQLite history · streaming pipelines | Planned (streaming pipelines + durable history pulled forward into W3) |
| 5 | Tabs & session | Public alpha | Tabs · session restore · keybindings · theme/prompt sync | Planned |
| 6 | 1.0 | Public | Signed releases · 5 testers × 2 weeks · cross-platform parity | Planned |

## Wave 1 — Dogfood (complete)

**Entry gate.** Pascal can launch the Windows desktop host and complete a typical work session: build, test, debug, search history, switch panes, type a prompt with autosuggestions, run AgentD health check. Crashes are zero in a 4-hour session.

**Audience.** Pascal only.

**Headline.** The shell is real. The desktop runs. AgentD answers.

**Rollback.** N/A — this is the baseline.

**Status.** Complete as of `v0.1.0-alpha.2`.

## Wave 2 — Unified theme & portfolio polish (complete on disk · `alpha.3` pending)

**Entry gate.** ✓ Nothing required to start.

**Exit gate.**
- ⏳ `zig build` and `zig build test` green on Windows / Linux / macOS — *requires a compile-equipped session; CI matrix is configured but the polish-pass changes are not yet compiler-verified locally.*
- ✓ `ZIGGYZAG_THEME` env var drives shell prompt accent in addition to the desktop palette.
- ✓ `theme` shell builtin: `theme`, `theme list`, `theme <id>`, `theme --json` work and have 6 tests in `apps/shell/src/main.zig`.
- ✓ `docs/index.html` opens to a portfolio-grade landing page with working install one-liner, theme gallery, wave timeline, stats panel.
- ✓ `README.md` rewritten for impact with hero, theme gallery, status section, masterplan link.
- ✓ `CHANGELOG.md`, `SECURITY.md`, `docs/vision/masterplan.md`, `docs/vision/references.md`, `docs/reference/brand.md`, `docs/vision/waves.md`, `docs/reference/theme-protocol.md` all exist (doc folder reorganised this wave).
- ✓ `scripts/install.sh` and `scripts/install.ps1` exist with SHA-256 verification.
- ✓ `.github/workflows/release.yml` triggers on `v*` tags and produces a draft GitHub Release with attached zips.
- ✓ `.gitignore` excludes `.opencode/`, `.worktrees/`, `.mavis/`, `.idea/`, `.vscode/`.
- ✓ External review (`docs/reviews/2026-05-17-baseline.md`) completed and answered by the four-round polish log at `docs/reviews/2026-05-17-polish.md`.

**Bonus deliverables that landed beyond the original exit gate.**
- ✓ Twenty themes (up from 13), with WCAG AA contrast audit across every one. Script `scripts/audit_contrast.py` re-runnable; report at `docs/reference/accessibility.md`.
- ✓ Five real bugs found and fixed, seven false alarms documented. Full ledger at `docs/reviews/2026-05-17-polish.md`.
- ✓ Wave-3+ specs written but unimplemented: `docs/reference/history-backend.md`, `docs/reference/sessions.md`, `docs/reference/osc8-hyperlinks.md`, `docs/guides/vt-conformance.md`.
- ✓ Cohort 1 onboarding: `docs/guides/friend-testing.md` and `docs/guides/faq.md`.
- ✓ Eleven SVG assets cover the visual story.
- ✓ `scripts/demo.sh` — canonical feature walkthrough, foundation for the eventual demo GIF.

**Audience.** Pascal plus one external reviewer (audit closed).

**Headline.** "One theme selection drives shell and terminal. Looks intentional from the first launch."

**Rollback criteria** (active until `alpha.3` ships):
- `zig build test` fails on any platform.
- The smoke script fails after a theme change.
- The shell crashes when `ZIGGYZAG_THEME` is set to a malicious value.

**Tag at exit.** `v0.1.0-alpha.3`. Pre-tag readiness: [`../guides/alpha-3-readiness.md`](../guides/alpha-3-readiness.md). Pre-written release notes: [`../releases/v0.1.0-alpha.3.md`](../releases/v0.1.0-alpha.3.md).

## Wave 3 — Cross-platform (active — macOS window shipped 2026-06-10)

**Entry gate.** ✓ Wave 2 complete and tagged `v0.1.0-alpha.3`.

**Exit gate.**
- ✓ Native macOS desktop host launches a window, hosts a PTY, renders the grid. Cocoa NSWindow + NSView + CoreText/CoreGraphics with full overlay system (command palette, scrollback search, quick select, settings, theme cycle). AgentD universal input (`Ctrl+Space` — type natural language, preview command, insert into prompt).
- The `Pty` abstraction in `apps/desktop/src/pty.zig` is no longer a stub; both Windows and POSIX hosts go through it.
- ✓ AgentD universal input: `Ctrl+Space` opens an inline overlay above the prompt, inserts (not executes) the previewed command.
- ✓ Copy visible text (`Cmd+Shift+C` on macOS) to system clipboard via NSPasteboard.
- ✓ Live theme cycling (`Ctrl+Shift+T`) broadcasts OSC 7777 to the shell PTY.
- ✓ `docs/SHELL_INTEGRATION.md` documents the OSC 777 / WezTerm-compatible event protocol.
- ✓ The "no provider configured" inline state is shipped (per `MASTERPLAN.md` risk mitigation).
- ✓ Unicode/grapheme cell model shipped (Wave 3 pull-forward, 2026-06-11): zero-width marks, astral glyphs, wide-cell pairs, UTF-8 decode with invalid-byte replacement.
- ✓ SGR render attributes + 256/truecolor on macOS (2026-06-11): underline, italic, strikethrough, bold, double-underline, 256-color and RGB SGR sequences.
- ✓ Semantic prompt zones + prompt-jump navigation (2026-06-11): OSC 7777-driven semantic zones, `Cmd+Up`/`Cmd+Down` jumps to previous/next prompt.
- ✓ Mouse selection + double/triple-click word/line select + `Cmd+C` copy (2026-06-11).
- ✓ VT conformance harness (2026-06-11): purpose-built binary + grid snapshot diff, 15/15 cases pass, wired into CI.
- ✓ ZiggyZag.app bundle (2026-06-11): `zig build bundle` produces `.app` with `Info.plist` and bundle ID.
- ✓ Streaming native pipelines (Wave 4 pull-forward, 2026-06-11): real OS pipe chain between stages, deadlock regression test in CI.
- ✓ Durable history on by default (Wave 4 pull-forward, 2026-06-11): TSV backend, 16 secret-redaction patterns, import/export.
- ✓ Cursor-aware completion v2 (2026-06-11): quoted and escaped path tokens, programmable completer output bounded and deduplicated.
- ✓ Fish-grade syntax highlighting on the prompt (2026-06-11).
- ✓ AgentD cancel protocol + Windows panel streaming/provider-absent parity (2026-06-11).
- ✓ CI headless smoke test on macOS and Linux (2026-06-11): `zig build smoke-desktop` runs in the CI matrix.
- Same for Linux native window: not yet shipped.
- 3 friend testers have run ZiggyZag for at least 3 sessions each on their primary platform (one Windows, one macOS, one Linux).

**Done this wave:** macOS native Cocoa window with full feature parity to Windows host, plus significant Wave 4 pull-forwards (streaming pipelines, durable history, VT conformance, Unicode model, SGR truecolor, Fish-grade syntax highlighting).
**Remaining:** Linux native window, friend-tester cohort 1 onboarding.

**Audience.** 3 friend testers + Pascal.

**Headline.** "ZiggyZag is a real cross-platform terminal."

**Rollback criteria.**
- Any platform-native host crashes within 5 minutes of normal use.
- AgentD overlay can execute a command without explicit Enter.
- Any AgentD tool produces output outside its declared bound.

**Tag at exit.** `v0.2.0-alpha.1`.

## Wave 4 — Durable state (planned)

**Entry gate.** Wave 3 complete, all 3 testers signed off, at least one tester has logged 7 days of daily use.

**Exit gate.**
- SQLite history backend ships with Atuin-style schema (`id`, `command`, `cwd`, `hostname`, `exit_status`, `duration_ms`, `started_at`, `shell_session_id`). `HISTFILE` import on first run; `HISTFILE` retained as export target. New `history --where` query.
- Streaming native pipelines: real OS pipe handles between stages, bounded captures, deadlock tests in CI.
- VT conformance binary in CI runs a fixed corpus and produces a diff against the grid snapshot.
- 6 friend testers, each logging ≥ 1 week.

**Audience.** 6 friend testers + Pascal. First "public alpha" announcement.

**Headline.** "Your shell remembers everything, your pipelines stream, your themes change live."

**Rollback criteria.**
- SQLite migration corrupts an imported `HISTFILE`.
- Streaming pipelines deadlock under a documented test case.
- OSC 7777 race condition causes the shell to display the wrong theme.

**Tag at exit.** `v0.3.0-alpha.1`.

## Wave 5 — Tabs & session (planned)

**Entry gate.** Wave 4 complete, durability soak test passed (24h continuous session, no leak, no crash).

**Exit gate.**
- `Session` abstraction: one PTY + grid + scrollback + cwd per tab/split. Tabs in the Windows desktop, with persisted titles, close confirmation, cwd inheritance on new tab.
- Keybinding configuration: `desktop.conf` accepts a `[keybindings]` section; `Ctrl+,` overlay surfaces them.
- Theme/prompt sync: shell `prompt` themes coordinate with desktop themes so picking `tokyo-night` in either side updates the other.
- Accessibility pass: keyboard-only navigation through all desktop UI, WCAG-AA contrast verified for each theme.
- Public beta announcement.

**Audience.** Public beta. Open issues, accepted PRs, public CI.

**Headline.** "ZiggyZag is a daily-driver terminal."

**Rollback criteria.**
- Tab close loses the user's unsaved session state.
- Keybinding edits brick the settings overlay.
- Accessibility regression on any default theme.

**Tag at exit.** `v0.4.0-beta.1`.

## Wave 6 — 1.0 (planned)

**Entry gate.** Wave 5 complete. 5 friend testers have each used ZiggyZag as their primary daily terminal for ≥ 2 weeks. Public beta has been live for ≥ 30 days. Issue close rate ≥ 80% within 7 days.

**Exit gate.**
- All five gates in [`NEXT_20_FEATURES.md#main-terminal-gate`](next-20-features.md#main-terminal-gate) pass on Windows, macOS, and Linux.
- Signed Windows installer; notarized macOS app or `.pkg`; Linux `.deb` and `.rpm`.
- Crash diagnostics: support bundle command (`ziggyzag-doctor --bundle`) collects version, config, AgentD audit excerpt, renderer mode, sanitized logs.
- `CHANGELOG.md` complete back to first commit.
- Public landing page lives on a custom domain or `PascalAI2024.github.io/ZiggyZag`.

**Audience.** General public.

**Headline.** "1.0."

**Tag at exit.** `v1.0.0`.

## Gate enforcement

Each wave's exit gate is checked manually with `docs/DAILY_DRIVER_QA.md` and automatically with CI:

1. `zig build` on Windows + Linux + macOS (CI matrix).
2. `zig build test` on the same.
3. `scripts/smoke.ps1` (Windows) and `scripts/smoke.sh` (POSIX).
4. `scripts/qa-tomorrow.ps1` (Windows-only daily-driver pre-flight).
5. `scripts/daily-driver-qa.ps1 -Automated` (Windows).
6. For Wave ≥ 3: extracted-release smoke on actual macOS/Linux runners (the `release.yml` workflow already runs this).
7. For Wave ≥ 4: streaming-pipeline deadlock corpus.
8. For Wave ≥ 5: 24h soak test with `top` snapshots every 10 min.

A wave is declared complete only when every applicable item is green for two consecutive runs.

## Rollback procedure

If a wave's rollback criteria are met:

1. **Stop new tagging.** Do not cut another release in this wave's line.
2. **Open a `revert/<thing>` branch** off the failed tag's parent.
3. **Revert the failing commits** (`git revert` preferred over force-push) and tag the previous wave's commit as `vX.Y.Z-postwave-rollback`.
4. **File an incident note** in `docs/INCIDENTS.md` (created on first incident) with the trigger, the affected gate, the rollback range, and the postmortem owner.
5. **Re-enter the wave only when** the failing path has a regression test in CI.

We have not used this procedure yet. The first incident will set the tone for the rest.

## Friend-tester onboarding

Every cohort opens with a one-page brief:

- What's new this wave (linked from CHANGELOG).
- What we expect to break (linked from ALPHA_TASKS).
- How to file a report (GitHub issues; emoji-tagged template).
- How to roll back (run the previous installer; histories survive).
- What we will NOT do (no telemetry, no auto-update, no account).

Cohort 1 (Wave 3): three colleagues across Windows, macOS, Linux.
Cohort 2 (Wave 4): six people; cohort 1 introduces them.
Cohort 3 (Wave 5/6): public via Show HN / r/programming when the gates are met.

## Anti-goals for wave management

What this plan deliberately does not do:

- **No fixed dates.** Calendar pressure breaks gates. Waves ship when they are ready.
- **No "soft launches" that ship anyway.** If a gate is not met, no announcement.
- **No expanding the cohort to fix the cohort.** If three testers cannot stress-test Wave 3, recruiting six does not help; fix the product first.
- **No telemetry to "see if it's working."** We ask. If the answer is "I forgot to use it," that is real signal.

---

*Last updated: 2026-06-11. Update this document when a wave exits or a gate changes. Do not rename waves once announced.*
