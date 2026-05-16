# ZiggyZag Desktop

This is the primary lane for the all-Zig desktop terminal host.

On Windows, the app launches `ziggyzag` through a real ConPTY, renders terminal output in its own native Win32 window, and uses ZiggyZag's OSC 777 shell-integration events for cwd, command status, duration, jobs, and shell-aware UI.

On macOS/Linux, the desktop binary is currently a terminal-attached launcher: it resolves the ZiggyZag shell binary, prints the selected POSIX backend, and starts the shell in the calling terminal. It does not open a native window or allocate a dedicated desktop PTY yet.

The previous Tauri/xterm.js prototype lives in `apps/desktop-tauri-spike` as a product spike.

## Current Status

This directory contains a buildable Zig executable named `ziggyzag-desktop` plus the desktop core modules:

- `windows_app.zig`: Win32 window, GDI renderer, keyboard input, copy/paste, mouse-wheel scrollback, Windows ConPTY bridge, shell lifecycle, and status bar.
- `terminal.zig`: terminal grid with printable text, SGR styling, newline, carriage return, deferred wrapping, scrollback capture, resize, and a small CSI subset.
- `integration.zig`: OSC 777 ZiggyZag event extraction that strips app-only events from display bytes.
- `config.zig`: lightweight desktop settings model and key=value parser.
- `theme.zig`: typed color, theme presets, lookup, and override primitives.
- `pty.zig`: platform backend selector for Windows ConPTY and POSIX PTY work.

The Windows implementation is the first complete native alpha. The POSIX launcher is useful for release artifacts and friend testing while native POSIX window+PTY hosting and a stronger terminal core follow without changing the shell boundary.

## Desktop Settings

Desktop settings are intentionally separate from the shell startup config. The shell keeps loading commands from `$ZIGGYZAG_CONFIG` or `~/.ziggyzagrc`; the desktop app should load visual and host options before creating its native window, then pass the selected values into the renderer, font setup, status bar, and PTY host.

The parser in `src/config.zig` accepts small `key=value` files with blank lines and `#` comments. Values are borrowed slices from the loaded file buffer, so the app should keep that buffer alive for as long as the parsed config is used. A later file-location helper can search an app-specific path such as `%APPDATA%\ZiggyZag\desktop.conf` on Windows and `$XDG_CONFIG_HOME/ziggyzag/desktop.conf` or `~/.config/ziggyzag/desktop.conf` on POSIX.

Supported keys:

```ini
theme = ziggy
theme.background = #111315
theme.foreground = #eef2e2
theme.cursor = #b6f09c
theme.accent = #9be28f
font.family = Cascadia Mono
font.size = 14
show_status_bar = true
smooth_scroll = true
bell = false
```

Known themes are `ziggy`, `paper`, and `ember`. Theme color overrides apply on top of the selected preset. Booleans accept `true/false`, `yes/no`, `on/off`, and `1/0`.

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
.\zig-out\bin\ziggyzag.exe
.\zig-out\bin\ziggyzag-agentd.exe --describe-tools
zig build run-desktop
```

`zig build run-desktop` expects the shell binary to be available from the same build output.

- Windows: opens the native terminal host. If the desktop starts but the terminal is blank or exits quickly, run `zig build` again and confirm `zig-out\bin\ziggyzag.exe` exists.
- macOS/Linux: launches `ziggyzag` in the calling terminal. If the shell binary is not in `zig-out/bin`, put `ziggyzag` beside `ziggyzag-desktop` in the release package or set `ZIGGYZAG_SHELL_PATH` to the shell executable. A native window is not expected in this alpha.

## Manual Test Checklist

Use this Windows checklist before sharing a build with friends:

1. Launch with `zig build run-desktop`.
2. Confirm the shell prompt appears.
3. Type `help`, press Enter, and confirm output scrolls.
4. Type a long command line and use Backspace.
5. Paste text with Ctrl+V and Shift+Insert.
6. Send Ctrl+C during a running command and confirm it behaves like a terminal interrupt.
7. Copy visible terminal text with Ctrl+Shift+C, then paste into Notepad or another editor.
8. Resize the window smaller and larger; the prompt should remain usable.
9. Run commands that change status, such as `doctor`, `pwd`, `history --stats`, and an invalid command.
10. Use the mouse wheel after producing more output than fits on screen.
11. Close the window and confirm no stuck `ziggyzag.exe` child process remains.

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
| Theme/config changes do not affect the window yet | `config.zig` parses the settings model; full persisted loading into the Win32 host is still a near-term integration task. |
| macOS/Linux desktop command does not open a window | Expected for this alpha. It should launch ZiggyZag in the calling terminal. Use `./zig-out/bin/ziggyzag` directly if you do not want the launcher banner. |

## Next Milestones

1. Add mouse selection and selection-aware copy.
2. Improve ANSI/CSI coverage or integrate `libghostty-vt`.
3. Add native POSIX window+PTY hosting for Linux/macOS.
4. Wire persisted desktop settings into the Win32 host and future POSIX hosts.
5. Add search, tabs, and split panes.
6. Move rendering from GDI to a faster GPU path when the terminal model demands it.
