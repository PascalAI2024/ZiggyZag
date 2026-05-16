# Alpha Task List And Missing Work

This page is the source-of-truth checklist for the current alpha. It separates what is already shipped from what is still missing, so README, release notes, and implementation waves do not accidentally overclaim.

The alpha target is practical: move toward a main local terminal and shell with honest cross-platform builds, reliable release artifacts, safe AgentD actions, and a smooth Windows-native desktop experience. Main-terminal readiness is not claimed until the gates in [DAILY_DRIVER_QA.md](DAILY_DRIVER_QA.md) pass. Remote SSH, cloud sync, multiplayer/team features, app-store packaging, and embedding WezTerm wholesale are intentionally out of scope for this alpha line.

Navigation: use [TASK_SYSTEM.md](TASK_SYSTEM.md) for how task status moves, [NEXT_20_FEATURES.md](NEXT_20_FEATURES.md) for the research-backed execution backlog, [RESEARCH.md](RESEARCH.md) for source traceability, and [DATA_MAP.md](DATA_MAP.md) for QA/release evidence.

## Current Status

| Area | Status | Notes |
| --- | --- | --- |
| Shell core | Alpha-ready | REPL, builtins, history, completions, prompt themes, aliases, abbreviations, redirection, background jobs, project tasks, and simple native pipelines are present. |
| Windows desktop host | Alpha | Win32/ConPTY host, terminal grid, keyboard input, resize, bounded scrollback, search, quick select, command palette, settings overlay, themes, copy-visible, paste, alternate screen, mouse-wheel handling, split panes, AgentD panel, and OSC 777 parsing are present. |
| macOS/Linux desktop host | Alpha launcher only | `ziggyzag-desktop` builds and launches ZiggyZag in the calling terminal, preferring the native POSIX PTY relay, then `script(1)`, then direct stdio. It is not a native graphical window yet. |
| AgentD runtime | Alpha | `ziggyzag-agentd` exposes JSON-lines health, tool discovery, local read/search/git/build tools, approval metadata, host actions, and provider request shaping. |
| AgentD desktop panel | Alpha | The Windows desktop host spawns AgentD, renders a bounded transcript, requests health/tools, previews `terminal.write`, and requires explicit approval before writing to the active PTY. |
| Split panes | Alpha | The Windows host supports PTY-backed vertical/horizontal splits, next-pane focus, active-pane close, per-pane scrollback/status, and config-restored pane count/orientation. Tabs are still missing. |
| Unicode terminal | Alpha | Cells store Unicode scalars, decode UTF-8 with invalid-byte replacement, emit UTF-8 for text extraction, and track wide-cell continuations. Combining marks, emoji grapheme clusters, fallback fonts, and ligatures remain TODO. |
| Pipelines | Alpha | Simple pipelines use a native stage path with concurrent stdout/stderr draining and temp-file handoff for large stage output. True streaming pipe chains, deeper redirection composition, and more parser coverage remain TODO. |
| POSIX PTY work | Alpha | The macOS/Linux launcher now tries the native POSIX PTY relay first, including raw input, byte relay, child polling, terminal-size propagation, and fallback paths. Real-host runtime stress still needs Linux/macOS coverage. |
| Release QA | Windows/archive alpha-ready; POSIX runtime QA pending | Windows scripts cover build, tests, shell smoke, AgentD smoke, desktop launch/close smoke, cross-built archive structure, checksums, and extracted Windows runtime smoke. Linux/macOS runtime smoke still needs real hosts or CI runners. |

## Shipped In The Current Alpha

- [x] Shell REPL, builtins, history, completions, prompt themes, aliases, abbreviations, project tasks, and startup config.
- [x] Parser diagnostics for unterminated quotes, missing redirect targets, invalid builtins, and useful `type`/`which` failure statuses.
- [x] Practical job table with background jobs, reaping, `wait`, `kill`, `disown`, `fg`, and `bg`; full POSIX process-group control is not claimed.
- [x] Prompt snapshot cache, bounded git status, branch fallback, and prompt timeout controls.
- [x] Native simple pipelines with concurrent stdout/stderr draining and temp-file handoff for large stage output.
- [x] Windows Win32/ConPTY desktop host with bounded scrollback, search, quick select, themes, settings overlay, command palette, paste, copy-visible, alternate screen, bracketed paste, app cursor mode, mouse-wheel reports, and shell status events.
- [x] PTY-backed split panes on Windows with vertical/horizontal split commands, next-pane focus, close-active-pane, per-pane scrollback/status, and startup pane count/orientation config.
- [x] First AgentD desktop panel on Windows with `agent/health`, `tools/list`, `terminal.write` preview, and explicit approval before writing to the active PTY.
- [x] Unicode scalar cells, UTF-8 decode with invalid-byte replacement, UTF-8 text extraction, and wide-cell continuation tracking.
- [x] POSIX terminal-attached desktop launcher with native PTY relay first, then `script(1)`, then direct stdio fallback.
- [x] Cross-built release zip assembly for Windows x86_64, Linux x86_64, Linux aarch64, macOS x86_64, and macOS aarch64, plus checksums and artifact QA.

## Complete List Of Missing Work

### P0: Correctness, Stability, And Release Honesty

- [ ] Keep `zig build`, `zig build test`, `scripts/smoke.ps1`, `scripts/smoke.sh`, `scripts/qa-tomorrow.ps1`, and `scripts/daily-driver-qa.ps1 -Automated` green on every implementation wave.
- [ ] Add a standalone terminal compatibility harness for CSI/OSC parsing, cursor state, erase behavior, scrollback, alternate screen, private modes, malformed escape recovery, and renderer/grid snapshots.
- [ ] Decide the VT parser boundary: keep expanding the local parser only if the harness stays manageable; otherwise integrate or wrap a proven Zig-compatible parser such as `libghostty-vt`.
- [ ] Finish full-screen terminal behavior: scroll margins, origin mode, soft-wrap tracking, bottom anchoring, resize reflow, and TUI app torture tests.
- [ ] Finish keyboard and mouse protocols: modifier-aware function keys, Alt/meta input, application keypad, IME/dead-key handling, focus events, full xterm/SGR mouse button reports, and wheel behavior across normal and alternate screen.
- [ ] Finish Unicode rendering correctness: combining marks, grapheme clusters, emoji width, ambiguous-width policy, fallback fonts, ligatures, box drawing alignment, copy/search behavior, and tests for invalid UTF-8.
- [ ] Replace native pipeline buffering with true streaming pipe chains, bounded captures, spill-to-temp behavior where needed, and deadlock tests.
- [ ] Implement Windows raw interactive input for the standalone shell so ZiggyZag has first-class cursor editing when run directly inside Windows terminals.
- [ ] Stress the POSIX PTY relay on real Linux/macOS hosts: raw-mode restore after errors, Ctrl+C/Ctrl+D, resize propagation during interactive sessions, piped stdin EOF, non-TTY stdin/stdout, child exit status, and fallback behavior.
- [ ] Harden OSC 777 and shell-integration trust boundaries so untrusted terminal output cannot spoof privileged UI state, AgentD context, or approval decisions.
- [ ] Run release zips on real or CI Linux x86_64, Linux aarch64, macOS Intel, and macOS Apple Silicon hosts; record the exact pass/fail matrix before calling cross-platform artifacts tested.
- [ ] Add crash diagnostics and support bundles: version info, config path, recent AgentD audit events, last renderer mode, and sanitized logs.

### P1: Daily-Driver UX

- [ ] Add mouse selection and selection-aware copy in the Windows desktop host, then add keyboard copy mode and rectangular selection.
- [ ] Add prompt-jump and semantic output navigation using ZiggyZag shell integration events.
- [ ] Add tabs with per-tab PTY/grid/session state, persisted titles, close confirmation, startup cwd inheritance, and richer session restore beyond pane count/orientation.
- [ ] Make the settings overlay write a valid `desktop.conf`, validate changes before saving, expose profile fields, and recover cleanly from config errors.
- [ ] Add profile and keybinding support for shell path, startup directory, environment variables, font family/size, scrollback, theme, panes, tabs, and AgentD behavior.
- [ ] Sync prompt themes and terminal themes so shell git/status colors and desktop palette choices feel like one product.
- [ ] Add quick-select open actions for URLs, paths, IPs, git hashes, issue keys, and OSC 8 hyperlinks instead of copy-only behavior.
- [ ] Build completion engine v2: cursor-position-aware completion, quoted/escaped paths on Windows and POSIX, option schemas, dynamic values, file filters, descriptions, cancellation, timeouts, and bounded programmable completer output.
- [ ] Add a durable metadata-history backend by default, reload it on startup, support import/export/clear/disable flows, and strengthen secret redaction.
- [ ] Deepen autosuggestions, prompt modules, and shell-aware navigation so the README roadmap language maps to executable work rather than loose aspiration.
- [ ] Harden AgentD panel workflows: read-only tool browsing from the UI, build-action approval, audit export, provider streaming, tool cancellation/timeouts, clearer error states, and stronger secret redaction.
- [ ] Add accessibility passes for keyboard-only usage, high-contrast themes, readable focus indicators, font scaling, and screen-reader-friendly labels where the native stack supports them.
- [ ] Profile large output, scrollback search, split-pane rendering, AgentD transcripts, and startup time; set simple performance budgets before adding heavier renderer work.

### P2: Platform, Packaging, And Product Polish

- [ ] Build a native macOS/Linux graphical host on top of the shared PTY boundary instead of only the terminal-attached launcher.
- [ ] Decide whether the renderer remains GDI/CPU for the next alpha or moves toward a GPU-backed renderer; document the tradeoff before changing the rendering stack.
- [ ] Add install/uninstall/rollback paths for friend testers, including config/history preservation and a documented way to remove ZiggyZag cleanly.
- [ ] Add signed or notarized release packaging when the project is ready to distribute outside trusted testers.
- [ ] Add config migration/versioning so future desktop and shell config changes do not strand older users.
- [ ] Add richer docs for contributors: architecture tour, terminal parser guide, AgentD protocol guide, theme authoring guide, and release checklist.
- [x] Removed the Tauri/xterm.js spike; the all-Zig host is the only desktop lane.
- [ ] Add long-session manual QA notes from friend testers and promote recurring failures into automated tests or explicit known edges.

## QA Checklist For This Wave

Before calling the next alpha ready:

1. Run `zig build` and `zig build test`.
2. Run `.\scripts\qa-tomorrow.ps1` on Windows.
3. Run `.\scripts\daily-driver-qa.ps1 -Automated` on Windows, then complete the manual daily-driver checklist in [DAILY_DRIVER_QA.md](DAILY_DRIVER_QA.md).
4. Build release zips with `.\scripts\build-release.ps1 -Version <version>` and verify with `.\scripts\qa-release-artifacts.ps1 -Version <version>`.
5. On Linux and macOS hosts, run the release zip smoke commands in [QA_TOMORROW.md](QA_TOMORROW.md).
6. For split panes, verify each pane has an independent shell process, cwd, scrollback, and Ctrl+C behavior.
7. For the AgentD panel, verify read-only tools stay read-only and state-changing host actions require approval before anything is written to the terminal.
8. For Unicode, record any unsupported width or rendering cases as known edges instead of implying full compatibility.

## GitHub Repo Description Suggestion

```text
Alpha Zig shell workspace with a readable shell core, Windows-native terminal host, POSIX launcher, and slim AgentD sidecar.
```

Shorter option:

```text
A readable Zig shell lab with a Windows-native terminal alpha and AgentD sidecar.
```
