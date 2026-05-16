# ZiggyZag Desktop

This is the primary lane for the all-Zig desktop terminal host.

The app launches `ziggyzag` through a real Windows ConPTY, renders terminal output in its own native Win32 window, and uses ZiggyZag's OSC 777 shell-integration events for cwd, command status, duration, jobs, and shell-aware UI.

The previous Tauri/xterm.js prototype lives in `apps/desktop-tauri-spike` as a product spike.

## Current Status

This directory contains a buildable Zig executable named `ziggyzag-desktop` plus the desktop core modules:

- `windows_app.zig`: Win32 window, GDI renderer, keyboard input, copy/paste, mouse-wheel scrollback, Windows ConPTY bridge, shell lifecycle, and status bar.
- `terminal.zig`: terminal grid with printable text, SGR styling, newline, carriage return, deferred wrapping, scrollback capture, resize, and a small CSI subset.
- `integration.zig`: OSC 777 ZiggyZag event extraction that strips app-only events from display bytes.
- `config.zig`: lightweight desktop settings model and key=value parser.
- `theme.zig`: typed color, theme presets, lookup, and override primitives.
- `pty.zig`: platform backend selector for Windows ConPTY and POSIX PTY work.

The Windows implementation is the first complete native MVP. POSIX PTY and a stronger terminal core can follow without changing the shell boundary.

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

From the repository root:

```sh
zig build
zig build test
zig build run-desktop
```

On Windows PowerShell:

```powershell
zig build
zig build test
zig build run-desktop
```

`zig build run-desktop` expects the shell binary to be available from the same build output. If the desktop starts but the terminal is blank or exits quickly, run `zig build` again and confirm `zig-out\bin\ziggyzag.exe` exists.

## Manual Test Checklist

Use this checklist before sharing a build with friends:

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

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `zig build run-desktop` fails before opening a window | Confirm Zig 0.16.0 is installed and available on `PATH`. |
| Window opens but no prompt appears | Run `zig build` first and confirm `zig-out\bin\ziggyzag.exe` exists. |
| Clipboard shortcuts do nothing | Make sure the desktop window has focus. Ctrl+V and Shift+Insert paste; Ctrl+Shift+C copies visible text. |
| Ctrl+C does not copy text | Ctrl+C is reserved for shell interrupt. Use Ctrl+Shift+C for copy-visible. |
| Mouse wheel does not show old output | Produce enough terminal output first; current scrollback is local and bounded. |
| Theme/config changes do not affect the window yet | `config.zig` parses the settings model; full persisted loading into the Win32 host is still a near-term integration task. |

## Next Milestones

1. Add mouse selection and selection-aware copy.
2. Improve ANSI/CSI coverage or integrate `libghostty-vt`.
3. Add POSIX PTY support for Linux/macOS.
4. Wire persisted desktop settings into the Win32 host and future POSIX hosts.
5. Add search, tabs, and split panes.
6. Move rendering from GDI to a faster GPU path when the terminal model demands it.
