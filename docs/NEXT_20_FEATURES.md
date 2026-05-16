# Next 20 Features

This is the daily-driver task list for making ZiggyZag good enough to become a main terminal and shell. It combines the current codebase audit with a fresh reference pass over Ghostty and WezTerm.

The conclusion is clear: stay all-Zig, keep ZiggyZag's shell as the source of truth, and borrow the quality bar rather than embedding WezTerm or wrapping another terminal. The next wave should make terminal behavior boringly correct, then make shell context, themes, settings, and agent assistance feel first-party.

## Reference Bar

- Ghostty's feature docs emphasize native UI, tabs/splits, GPU rendering, built-in themes, ligatures, grapheme clustering, and modern terminal protocols such as Kitty graphics. See [Ghostty features](https://ghostty.org/docs/features).
- Ghostty also treats zero-config startup, simple inspectable config, keybindings, reload, and huge built-in theme coverage as core product expectations. See [Ghostty configuration](https://ghostty.org/docs/config), [Ghostty keybindings](https://ghostty.org/docs/config/keybind), and [Ghostty themes](https://ghostty.org/docs/features/theme).
- WezTerm's feature list sets the daily-driver baseline: cross-platform support, panes/tabs/windows, native mouse and scrollback, ligatures, color emoji, truecolor, hyperlinks, search, selection, bracketed paste, SGR mouse reporting, render attributes, and hot-reloaded config. See [WezTerm features](https://wezterm.org/features.html).
- WezTerm's shell integration docs are the right model for shell-aware UX: use escape sequences and user vars for cwd, semantic prompt zones, command output selection, and prompt navigation. See [WezTerm shell integration](https://wezterm.org/shell-integration.html).
- WezTerm's command palette, quick select, copy mode, and split-pane docs show the interaction bar ZiggyZag should eventually meet. See [command palette](https://wezterm.org/config/lua/keyassignment/ActivateCommandPalette.html), [quick select](https://wezterm.org/quickselect.html), [copy mode](https://wezterm.org/copymode.html), and [split panes](https://wezterm.org/config/lua/keyassignment/SplitPane.html).

## Task List

- [ ] 1. Terminal compatibility harness and VT parser decision
  Build conformance tests around the current grid, CSI/OSC parsing, cursor state, scroll regions, erase behavior, save/restore cursor, private modes, and malformed sequence recovery. Decide whether to keep expanding the local parser or integrate `libghostty-vt` after the boundary is proven.
  Progress: focused terminal/integration unit coverage now includes split OSC events, scrollback caps, cursor save/restore, insert/delete, richer SGR colors/attributes, alternate screen, bracketed paste, app cursor, and mouse private modes. A standalone conformance harness and parser decision remain open.
  Primary paths: `apps/desktop/src/terminal.zig`, `apps/desktop/src/integration.zig`.

- [ ] 2. Unicode/grapheme cell model
  Replace byte cells with decoded codepoints, width metadata, combining behavior, grapheme clusters, CJK wide cells, emoji, and box drawing safety. This unlocks modern prompts and makes selection/copy sane.
  Primary paths: `apps/desktop/src/terminal.zig`, `apps/desktop/src/windows_app.zig`.

- [ ] 3. Truecolor, render attributes, and honest `TERM`
  Add 256-color and truecolor SGR, underline, double underline, italic, inverse, strikethrough, blink handling, reset variants, and a documented capability profile. Until then, stop overpromising with `xterm-256color` where unsupported.
  Progress: terminal core parses/stores 256-color, RGB color, underline color, italic, underline, double underline, inverse, hidden, strikethrough, blink, overline, and targeted resets; the Windows renderer consumes 16/256/RGB colors plus dim/bold/inverse/hidden. Visual underline/italic drawing remains open.
  Primary paths: `apps/desktop/src/terminal.zig`, `apps/desktop/src/windows_app.zig`.

- [ ] 4. Alternate screen, scroll margins, insert/delete, and resize reflow
  Support full-screen apps properly: alternate buffer, main scrollback separation, cursor/state restore, origin mode, insert/delete character and line, soft-wrap tracking, bottom anchoring, and reflow-aware resize.
  Progress: alternate buffer/state restore, no-alt-screen scrollback capture, insert/delete character and line, and resize preservation are implemented. Scroll margins, origin mode, and reflow-aware resize remain open.
  Primary paths: `apps/desktop/src/terminal.zig`, `apps/desktop/src/windows_app.zig`.

- [ ] 5. Bracketed paste, keyboard modes, and mouse reporting
  Track bracketed paste mode, application cursor/keypad mode, modifier-aware key encoding, Alt/meta input, function keys, IME/dead-key behavior, focus events, xterm/SGR mouse reporting, and wheel events inside alternate screen apps.
  Progress: bracketed paste wrapping, application cursor arrows, DEC mouse tracking/encoding state, and alternate-screen wheel reports are implemented. Modifier/function keys, IME/dead-key behavior, focus events, and full mouse button reports remain open.
  Primary paths: `apps/desktop/src/windows_app.zig`.

- [x] 6. PTY lifecycle hardening
  Store and join the reader thread, signal shutdown atomically, unblock reads safely, move UI work back onto the window thread, stop mutating process-global environment, and pass per-session environment blocks into child processes.
  Shipped: reader thread ownership/join, atomic shutdown flag, child-only environment block, UI-thread refresh posting, startup cleanup, and launch/close smoke coverage.
  Primary paths: `apps/desktop/src/windows_app.zig`, `apps/desktop/src/pty.zig`.

- [ ] 7. Shared POSIX native desktop host
  Turn the Windows ConPTY work and POSIX launcher into a shared PTY backend interface, then add real macOS/Linux graphical hosting instead of terminal-attached launcher-only behavior.
  Primary paths: `apps/desktop/src/pty.zig`, `apps/desktop/src/posix_pty.zig`, `apps/desktop/src/main.zig`.

- [ ] 8. Windows raw input for the shell
  Implement the Windows side of interactive raw mode so cursor editing, redraw, suggestions, tab UX, Ctrl-R, and manual echo are first-class when ZiggyZag runs directly in a Windows terminal.
  Primary paths: `apps/shell/src/main.zig`.

- [x] 9. Parser diagnostics and status correctness
  Make unterminated quotes, missing redirect targets, invalid builtins, failed `type`/`which`, and config errors set meaningful statuses and show precise messages. Preserve learning-friendly output while making scripts trustworthy.
  Shipped: parse errors keep the shell alive with status 2, redirect-target validation happens before mutation, and `type`/`which` set useful failure statuses.
  Primary paths: `apps/shell/src/main.zig`.

- [ ] 10. Streaming pipelines and bounded captures
  Replace buffered native pipelines with real pipe handles, concurrent stdout/stderr draining, bounded capture, spill-to-temp behavior for huge output, and deadlock tests.
  Progress: native stages now bound input, drain stdout/stderr together, and fail safely on oversized captures. A true streaming pipe chain with spill-to-temp remains open.
  Primary paths: `apps/shell/src/main.zig`.

- [ ] 11. Cross-platform background jobs
  Implement nonblocking child status on Windows, macOS, Linux, and BSD; add `fg`, `bg`, `wait`, `kill`, and `disown` or clearly document which job-control features are intentionally absent.
  Progress: practical `wait`, `kill`, `disown`, `fg`, and `bg` builtins are implemented around ZiggyZag's background job table. Full process-group job control is intentionally not claimed yet.
  Primary paths: `apps/shell/src/main.zig`.

- [x] 12. Fast prompt and git status cache
  Add prompt timeouts, cached git/project state, stale-then-refresh rendering, branch-only fallback for slow repos, and tests around large repos and network paths.
  Shipped: prompt snapshots cache briefly, git status output is bounded, slow git status has an env-configurable timeout, and branch-only fallback remains available.
  Primary paths: `apps/shell/src/main.zig`.

- [ ] 13. Durable history backend with privacy controls
  Make metadata history durable by default, reload it on startup, keep `HISTFILE` import/export, add clear/export/disable commands, document storage paths, and redact secrets from app/agent context.
  Progress: history now has clear/export/enable/disable/status/private controls, JSON/meta export, and env privacy switches. A default durable metadata backend and stronger secret redaction for shell history remain open.
  Primary paths: `apps/shell/src/main.zig`, `docs/QUICK_START.md`.

- [ ] 14. Completion engine v2
  Support completions at the cursor, quote/escape paths with spaces on Windows and POSIX, add option schemas, file filters, dynamic values, descriptions, cancellation, timeout, and bounded stdout from programmable completers.
  Primary paths: `apps/shell/src/main.zig`.

- [ ] 15. Bounded searchable scrollback and copy mode
  Add a configurable scrollback ring, Ctrl+Shift+F search, keyboard copy mode, selection-aware copy, rectangular selection later, and prompt-jump using ZiggyZag integration events.
  Progress: configurable scrollback ring, `Ctrl+Shift+F` search, and copy-visible are implemented. Keyboard copy mode, selection-aware copy, and prompt-jump remain open.
  Primary paths: `apps/desktop/src/terminal.zig`, `apps/desktop/src/windows_app.zig`.

- [ ] 16. Quick select, hyperlinks, and open actions
  Detect URLs, paths, IPs, git hashes, issue keys, and command output ranges; let users copy, paste, open, or search them without dragging a mouse. Add OSC 8 hyperlink parsing once the cell model can represent it.
  Progress: `Ctrl+Shift+O` quick select detects and copies URLs, path-like strings, issue keys, and git-hash-like tokens from the current viewport. Open actions, IPs, command ranges, and OSC 8 remain open.
  Primary paths: `apps/desktop/src/terminal.zig`, `apps/desktop/src/windows_app.zig`.

- [ ] 17. Tabs, split panes, and session restore
  Introduce `Session` objects with one PTY/grid per tab or split, keyboard navigation, close confirmation, persisted titles, startup cwd inheritance, and a minimal restore file for last window layout.
  Progress: PTY-backed vertical/horizontal split panes, next-pane focus, close-active-pane, per-pane status/scrollback, and config-restored pane count/orientation are implemented. Tabs, close confirmation, persisted titles, cwd inheritance per new pane, and richer restore remain open.
  Primary paths: `apps/desktop/src/windows_app.zig`, `apps/desktop/src/config.zig`.

- [x] 18. Command palette and action registry
  Create a searchable modal for new tab, split, close, copy, paste, search, theme, font size, settings, restart shell, open config, run project task, and agent actions. Track frecency after the first version works.
  Shipped first version: `Ctrl+Shift+P` searchable palette runs copy, paste, search, quick select, split right/down, next pane, close pane, AgentD panel/health/tools/preview/approve, settings, theme cycle, config reload, restart shell, clear scrollback, and copy cwd/config path. Tabs and frecency remain future actions.
  Primary paths: `apps/desktop/src/windows_app.zig`, `apps/desktop/src/config.zig`.

- [ ] 19. Profiles, keybindings, settings, and theme sync
  Expand desktop config into profiles for shell path, startup directory, environment, font, scrollback, keybindings, and theme. Add live reload, settings UI editing, light/dark theme pairs, and prompt/terminal color sync.
  Progress: desktop config now applies profile shell path, startup cwd, TERM, scrollback lines, and startup pane count/orientation; `Ctrl+Shift+R` reloads safe settings. Environment arrays, keybindings, settings editing, light/dark pairs, and prompt/theme sync remain open.
  Primary paths: `apps/desktop/src/config.zig`, `apps/desktop/src/theme.zig`, `apps/shell/src/main.zig`.

- [x] 20. Approval-aware agent panel
  Spawn `ziggyzag-agentd --stdio` from the desktop host, list tools, run read-only tools automatically, require approval for terminal writes/builds, preview exact text before insertion, audit every decision, minimize context, redact secrets, and harden OSC 777 as UI context rather than a trust boundary.
  Shipped first version: AgentD exposes richer tool schemas, approval metadata, audit/event host actions, and redacted bounded read/search/git output; the Windows desktop panel spawns `ziggyzag-agentd --stdio`, shows a bounded transcript, requests health/tools, previews `terminal.write`, and writes only after explicit approval. Read-only browsing, audit export, build-action approval, and provider streaming remain hardening work.
  Primary paths: `apps/agentd/src/main.zig`, `apps/agentd/src/tools.zig`, `apps/desktop/src/integration.zig`, `apps/desktop/src/windows_app.zig`.

## Execution Waves

Wave 1 should fix the things that can crash, hang, or lie: PTY lifecycle, UI-thread affinity, streaming pipelines, bounded reads, job reaping, parser statuses, and prompt timeouts.

Wave 2 should make the terminal trustworthy: VT tests, Unicode cells, truecolor, alternate screen, bracketed paste, keyboard/mouse protocols, and searchable bounded scrollback.

Wave 3 should make it feel like a modern terminal: tabs, splits, copy mode, quick select, command palette, profiles, keybindings, settings, themes, and session restore.

Wave 4 should make ZiggyZag uniquely useful: shell-aware prompt jumping, rich history, completion v2, approval-aware agent panel, audit logs, and context-minimized AI assistance.

## Main Terminal Gate

Do not label ZiggyZag as ready for daily use until these gates pass on the target platform:

- `zig build test`, shell smoke tests, desktop launch/close tests, and release artifact QA pass.
- A multi-hour interactive session survives resize, paste, copy, Ctrl+C, large output, full-screen TUI apps, background jobs, and close/reopen.
- The desktop app has bounded scrollback, clean PTY shutdown, and no detached thread using freed state.
- A user can uninstall or roll back without losing shell history.
- Agent actions require explicit approval before changing the terminal, filesystem, or build state.

Use [DAILY_DRIVER_QA.md](DAILY_DRIVER_QA.md) and `scripts/daily-driver-qa.ps1` to run and record these gates with friend testers.
