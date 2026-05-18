# ZiggyZag Desktop

This is the primary lane for the all-Zig desktop terminal host.

On Windows, the app launches `ziggyzag` through a real ConPTY, renders terminal output in its own native Win32 window, and uses ZiggyZag's OSC 777 shell-integration events for cwd, command status, duration, jobs, and shell-aware UI.

See also: [desktop terminal strategy](../../docs/reference/terminal-app.md), [all-Zig terminal direction](../../docs/reference/all-zig-terminal.md), [alpha task list](../../docs/vision/alpha-tasks.md), and [research traceability](../../docs/vision/research.md).

On macOS/Linux, the desktop binary is currently a terminal-attached launcher: it resolves the ZiggyZag shell binary, prints the selected POSIX backend, and starts the shell in the calling terminal. It first tries ZiggyZag's slim native POSIX PTY host, including byte relay, raw input, child status polling, and terminal-size propagation. If that fails, it falls back to `script(1)`, then direct stdio. It does not open a native graphical window yet.

## Current Status

This directory contains a buildable Zig executable named `ziggyzag-desktop` plus the desktop core modules:

- `windows_app.zig`: Win32 window, GDI renderer, keyboard input, copy/paste, bracketed paste wrapping, alternate-screen mouse-wheel reports, mouse-wheel scrollback, Windows ConPTY bridge, PTY-backed splits, shell lifecycle, AgentD panel, command palette, search/quick-select overlays, and shell-aware status bar with project/git context.
- `terminal.zig`: terminal grid with Unicode scalar cells, UTF-8 decode/replacement, wide-cell continuations, richer SGR styling, 16/256/RGB colors, alternate screen, bracketed paste/app-cursor/mouse mode tracking, newline, carriage return, deferred wrapping, scrollback capture, resize, and a growing CSI/DEC private-mode subset.
- `integration.zig`: OSC 777 ZiggyZag event extraction that strips app-only events from display bytes.
- `config.zig`: lightweight desktop settings model and key=value parser.
- `theme.zig`: typed color, theme presets, lookup, and override primitives.
- `pty.zig`: Wave 3 scaffold for a platform-abstracting `Pty` interface. Every backend currently returns `error.NotImplemented`; the working ConPTY path lives inline in `windows_app.zig` and is not yet behind this vtable.
- `posix_app.zig`: macOS/Linux terminal-attached launcher used by alpha release artifacts, with native PTY relay and fallback launch paths.
- `posix_pty.zig`: low-level POSIX PTY spawn, resize, relay, child-status, and tests for the future native POSIX host.

The Windows implementation is the first complete native alpha. The POSIX launcher is useful for release artifacts and friend testing while native POSIX graphical hosting and a stronger terminal core follow without changing the shell boundary.

## Desktop Settings

Desktop settings are intentionally separate from the shell startup config. The shell keeps loading commands from `$ZIGGYZAG_CONFIG` or `~/.ziggyzagrc`; the desktop app loads visual and host options before creating its native window, then passes the selected values into the renderer, font setup, status bar, and PTY host.

The parser in `src/config.zig` accepts small `key=value` files with blank lines and `#` comments. Values are borrowed slices from the loaded file buffer, and the Windows app keeps that buffer alive while the parsed config is used. The Windows host loads `%APPDATA%\ZiggyZag\desktop.conf` by default, or the file named by `ZIGGYZAG_DESKTOP_CONFIG`.

Press `Ctrl+,` in the Windows desktop host to open the settings overlay. Press `Ctrl+Shift+P` for the command palette, `Ctrl+Shift+F` for scrollback search, `Ctrl+Shift+O` for quick select, `Ctrl+Shift+D`/`Ctrl+Shift+E` for vertical/horizontal splits, `Ctrl+Shift+N` to focus the next pane, `Ctrl+Shift+W` to close the active pane, `Ctrl+Shift+A` for AgentD, `Ctrl+Shift+R` to reload desktop config, and `Ctrl+Shift+T` to cycle themes live without editing a file.

Supported keys:

```ini
theme = ziggy
theme.background = #111315
theme.foreground = #eef2e2
theme.cursor = #b6f09c
theme.accent = #9be28f
theme.panel = #191c1d
theme.muted = #6a7072
font.family = Cascadia Mono
font.size = 14
show_status_bar = true
smooth_scroll = true
bell = false
scrollback.lines = 10000
profile.shell = C:\path\to\ziggyzag.exe
profile.cwd = C:\Users\you\dev
profile.term = xterm-256color
session.panes = 1
session.orientation = vertical
```

Known themes are `ziggy`, `catppuccin-mocha`, `tokyo-night`, `dracula`, `nord`, `rose-pine`, `gruvbox-dark`, `everforest-dark`, `kanagawa-wave`, `solarized-dark`, `one-dark`, `paper`, and `ember`. Theme color overrides apply on top of the selected preset. Booleans accept `true/false`, `yes/no`, `on/off`, and `1/0`. `scrollback.lines` is capped at `250000`. `session.panes` restores a startup split layout from `1` through `6`, and `session.orientation` accepts `vertical` or `horizontal`.

## Development

From the repository root, all platforms:

```sh
zig build
zig build test
./zig-out/bin/ziggyzag
./zig-out/bin/ziggyzag-agentd --describe-tools
zig build run-desktop
```

On Windows PowerShell:

```powershell
zig build
zig build test
.\zig-out\bin\ziggyzag-launcher.exe
.\zig-out\bin\ziggyzag.exe
.\zig-out\bin\ziggyzag-agentd.exe --describe-tools
zig build run-desktop
```

`ziggyzag-launcher.exe` is the dev launcher path: it opens the same native terminal host directly from a friendlier app entry. Release zips copy it to top-level `ZiggyZag.exe`, outside `bin`, so Windows does not confuse it with `bin\ziggyzag.exe`. `zig build run-desktop` is still useful while developing and expects the shell binary to be available from the same build output.

- Windows: opens the native terminal host. If the desktop starts but the terminal is blank or exits quickly, run `zig build` again and confirm `zig-out\bin\ziggyzag.exe` exists.
- macOS/Linux: launches `ziggyzag` in the calling terminal. It uses the native POSIX PTY host first, propagates terminal-size changes while the session runs, falls back to `script(1)` if native PTY setup fails, and finally falls back to direct stdio. If the shell binary is not in `zig-out/bin`, put `ziggyzag` beside `ziggyzag-desktop` in the release package or set `ZIGGYZAG_SHELL_PATH` to the shell executable. A native graphical window is not expected in this alpha. Set `ZIGGYZAG_DESKTOP_NO_PTY=1` to skip PTY launch; false-like values such as `0`, `false`, `no`, and `off` leave PTY mode enabled.

## Manual Test Checklist

Use this Windows checklist before sharing a build with friends:

1. Launch with `.\zig-out\bin\ziggyzag-launcher.exe`.
2. Confirm the shell prompt appears.
3. Type `help`, press Enter, and confirm output scrolls.
4. Type a long command line and use Backspace.
5. Paste text with Ctrl+V and Shift+Insert.
6. Send Ctrl+C during a running command and confirm it behaves like a terminal interrupt.
7. Copy visible terminal text with Ctrl+Shift+C, then paste into Notepad or another editor.
8. Resize the window smaller and larger; the prompt should remain usable.
9. Run commands that change status, such as `doctor`, `pwd`, `history --stats`, `prompt dev`, and an invalid command.
10. Use the mouse wheel after producing more output than fits on screen.
11. Confirm the status bar shows project/git context when launched inside a repo.
12. Press `Ctrl+,` and confirm the settings overlay opens; press `Ctrl+Shift+P`, `Ctrl+Shift+F`, and `Ctrl+Shift+O` to check palette/search/quick-select overlays; press `Ctrl+Shift+T` and confirm the theme changes.
13. Press `Ctrl+Shift+D` and `Ctrl+Shift+E` to create split panes, `Ctrl+Shift+N` to focus panes, and `Ctrl+Shift+W` to close the active pane.
14. Press `Ctrl+Shift+A`, run AgentD health/tools/preview write from the palette, and approve only after the preview is visible.
15. Close the window and confirm no stuck `ziggyzag.exe` child process remains.

For macOS/Linux friends, use this alpha checklist:

1. Run `zig build`.
2. Run `./scripts/smoke.sh`.
3. Run `./zig-out/bin/ziggyzag` and try `help`, `doctor`, `history --stats`, `project`, and `exit`.
4. Run `./zig-out/bin/ziggyzag-agentd --describe-tools`.
5. Run `printf '%s\n' '{"id":1,"method":"agent/health"}' | ./zig-out/bin/ziggyzag-agentd --stdio`.
6. Run `zig build run-desktop`, confirm it prints `ZiggyZag Desktop (POSIX PTY)` and launches a shell prompt, then type `exit`.

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `zig build run-desktop` fails before opening a window | Confirm Zig 0.16.0 is installed and available on `PATH`. |
| Window opens but no prompt appears | Run `zig build` first and confirm `zig-out\bin\ziggyzag.exe` exists. |
| Clipboard shortcuts do nothing | Make sure the desktop window has focus. Ctrl+V and Shift+Insert paste; Ctrl+Shift+C copies visible text. |
| Ctrl+C does not copy text | Ctrl+C is reserved for shell interrupt. Use Ctrl+Shift+C for copy-visible. |
| Mouse wheel does not show old output | Produce enough terminal output first; current scrollback is local and bounded. |
| Theme/config changes do not affect the current window | Press `Ctrl+Shift+R` to reload safe desktop settings or restart the desktop host. Use `Ctrl+Shift+T` for live one-session theme cycling. Pane count changes add panes on reload but do not close live panes. |
| macOS/Linux desktop command does not open a window | Expected for this alpha. It should launch ZiggyZag in the calling terminal through the native POSIX PTY host, with `script(1)` and direct stdio as fallbacks. Use `./zig-out/bin/ziggyzag` directly if you do not want the launcher banner. |

## Next Milestones

1. Add mouse selection and selection-aware copy.
2. Continue ANSI/CSI coverage or integrate `libghostty-vt` once the boundary is proven.
3. Add native POSIX graphical hosting with first-party PTY management for Linux/macOS.
4. Add settings persistence helpers and a first-class settings editor instead of requiring manual `desktop.conf` edits.
5. Add tabs and deeper process/session restore beyond startup pane layout.
6. Move rendering from GDI to a faster GPU path when the terminal model demands it.
