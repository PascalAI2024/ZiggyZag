# Alpha Task List

This page is the working checklist for the implementation wave after the current alpha. It separates what is already in the repo from what is still planned, so README and release notes can stay honest.

## Current Status

| Area | Status | Notes |
| --- | --- | --- |
| Shell core | Alpha-ready | REPL, builtins, history, completions, prompt themes, aliases, abbreviations, redirection, background jobs, project tasks, and simple native pipelines are present. |
| Windows desktop host | Alpha | Win32/ConPTY host, terminal grid, keyboard input, resize, bounded scrollback, search, quick select, command palette, settings overlay, themes, copy-visible, paste, alternate screen, mouse-wheel handling, and OSC 777 parsing are present. |
| macOS/Linux desktop host | Alpha launcher only | `ziggyzag-desktop` builds and launches ZiggyZag in the calling terminal, preferring the native POSIX PTY relay, then `script(1)`, then direct stdio. It is not a native graphical window yet. |
| AgentD runtime | Alpha | `ziggyzag-agentd` exposes JSON-lines health, tool discovery, local read/search/git/build tools, approval metadata, host actions, and provider request shaping. |
| AgentD desktop panel | Alpha | The Windows desktop host spawns AgentD, renders a bounded transcript, requests health/tools, previews `terminal.write`, and requires explicit approval before writing to the active PTY. |
| Split panes | Alpha | The Windows host supports PTY-backed vertical/horizontal splits, next-pane focus, active-pane close, per-pane scrollback/status, and config-restored pane count/orientation. Tabs are still planned work. |
| Unicode terminal | Alpha | Cells store Unicode scalars, decode UTF-8 with invalid-byte replacement, emit UTF-8 for text extraction, and track wide-cell continuations. Combining marks, emoji grapheme clusters, fallback fonts, and ligatures remain TODO. |
| Pipelines | Alpha | Simple pipelines use a native stage path with concurrent stdout/stderr draining and temp-file handoff for large stage output. True streaming pipe chains, deeper redirection composition, and more parser coverage remain TODO. |
| POSIX PTY work | Alpha | The macOS/Linux launcher now tries the native POSIX PTY relay first, including raw input, byte relay, child polling, terminal-size propagation, and tested platform fallbacks. |
| Release QA | Alpha-ready | Windows scripts cover build, tests, shell smoke, AgentD smoke, desktop launch/close smoke, cross-built archive structure, checksums, and extracted Windows runtime smoke. Linux/macOS runtime smoke still needs real hosts or CI runners. |

## Near-Term Implementation Tasks

| Priority | Task | Acceptance signal |
| --- | --- | --- |
| P0 | Keep `zig build`, `zig build test`, `scripts/smoke.ps1`, and `scripts/smoke.sh` green | Local shell behavior stays stable before desktop work lands. |
| P0 | Preserve platform wording in docs | Windows claims native desktop alpha; macOS/Linux claims shell, AgentD, and terminal-attached launcher only. |
| Done | Split panes | Windows desktop can create PTY-backed vertical/horizontal panes, focus them by keyboard, resize layout, and close one without killing the others. |
| Done | AgentD panel | Desktop can launch `ziggyzag-agentd --stdio`, show `agent/health`, list tools, preview host actions, and require explicit approval for `terminal.write`. |
| P1 | Unicode terminal hardening | Add tests for wide characters, combining marks, emoji, invalid UTF-8, paste, copy-visible, resize, and search behavior. Document any remaining limitations. |
| P1 | Streaming pipeline engine | Replace bounded stage buffering with real pipe handles between child processes while preserving simple fallback behavior for complex syntax. |
| P1 | POSIX/macOS/Linux smoke runners | Run release zips on real Linux x86_64, Linux aarch64, macOS Intel, and macOS Apple Silicon hosts or CI runners. |
| P2 | Native POSIX graphical host | Open a real macOS/Linux window, launch the shell through a PTY, handle resize, and pass the same launch/close smoke shape as Windows. |
| P2 | Settings editor writes config | The Windows settings overlay can save a valid `desktop.conf`; docs describe file-based config until then. |
| P2 | Tabs and deeper session restore | Pane count/orientation restore is in; tabs and restoring richer workspace/session state remain planned. |
| P2 | Deeper terminal compatibility | Broaden ANSI/xterm coverage, selection, bracketed paste edge cases, alternate-screen behavior, mouse modes, and TUI app testing. |

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
