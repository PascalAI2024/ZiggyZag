# Theme Protocol

How a single theme selection in the desktop host drives both the terminal palette and the shell prompt colors.

This is the headline feature of Wave 2: one config key, one keystroke (`Ctrl+Shift+T`), one coherent visual identity across two binaries that historically had no idea about each other.

## Goals

1. **One source of truth.** The theme registry lives in `apps/desktop/src/theme.zig` and is shared with the shell at build time. No copies, no drift.
2. **Static and dynamic channels.** Static (env var) covers child-process spawn. Dynamic (OSC) covers live updates without restarting the shell.
3. **Backward compatible.** A ZiggyZag shell running in `xterm`, `tmux`, or any other terminal still works. A ZiggyZag desktop hosting any other shell still works. Both forms degrade gracefully.
4. **Zero new dependencies.** Pure environment variables and ANSI/OSC sequences.

## Channels

### v1 — Environment variable (this push)

The desktop sets one variable in the spawned shell's environment:

```
ZIGGYZAG_THEME=<theme-id>
```

Where `<theme-id>` is one of the IDs in `apps/desktop/src/theme.zig` (`ziggy`, `catppuccin-mocha`, `tokyo-night`, `dracula`, `nord`, `rose-pine`, `gruvbox-dark`, `everforest-dark`, `kanagawa-wave`, `solarized-dark`, `one-dark`, `paper`, `ember`).

The shell reads this on startup, looks up the theme, and stores it on `Shell.current_theme`. If the variable is absent or unknown, the shell falls back to `ziggy` (without complaint).

**Scope.** The shell uses the theme to choose its *accent* color for the prompt arrow, and the *muted* color for autosuggestions and dim text. It does NOT change the terminal background — that is the host's job. It does NOT remap the 16-color ANSI palette — that is also the host's job and existing SGR codes (`\x1b[31m`, `\x1b[33m`, etc.) already track the theme via the host's palette.

This means a vanilla `xterm` with `ZIGGYZAG_THEME=tokyo-night` will get tokyo-night-flavored prompt accents, but the background and ANSI palette remain whatever xterm is configured with. That is correct — the env var is a signal, not a takeover.

### v2 — OSC 7777 (planned, not in this push)

For live theme updates without restarting the shell, the desktop sends:

```
ESC ] 7777 ; ziggyzag.theme=<id> ESC \
```

(OSC 7777 is the application-private range; ZiggyZag has reserved this code internally.)

The shell's input reader recognizes this sequence on its stdin, consumes it silently (no echo, no command), updates `current_theme`, and re-renders the next prompt with the new accent. Sequences for any other application-private code are passed through unchanged so other terminals' integrations are not affected.

**Why not OSC 777?** OSC 777 is already used for the shell→desktop direction (events) and is widely interpreted by xterm-derived terminals. Reusing it for desktop→shell would cause loops and ambiguity. OSC 7777 is in the application-private range and is unique to ZiggyZag.

## Builtin: `theme`

A new shell builtin makes the theme inspectable and switchable from the command line.

```
theme              # print current theme id and name
theme list         # list known theme ids
theme <id>         # switch this session's theme (does not persist)
theme --json       # emit current theme as JSON (id, name, accent, muted, bg, fg)
```

The switch form changes `Shell.current_theme` immediately. It does not write to `desktop.conf` — for persistence, use the desktop's `Ctrl+,` settings overlay or edit `%APPDATA%\ZiggyZag\desktop.conf` directly.

`theme list` is identical to the desktop's `Ctrl+Shift+T` cycle order.

## Failure modes

| Situation | Behavior |
| --- | --- |
| `ZIGGYZAG_THEME` not set | Shell uses `ziggy` (default). Silent. |
| `ZIGGYZAG_THEME=unknown-name` | Shell uses `ziggy` (default). Logs once to stderr in `--verbose` mode only. |
| `ZIGGYZAG_THEME=ziggy` running in `xterm` | Shell emits truecolor SGR for accent. xterm without truecolor support degrades to the nearest ANSI color. Standard SGR codes for status/branch/error track xterm's existing palette. |
| Desktop running without `ZIGGYZAG_THEME` set | Desktop sets the env var to its current theme id at spawn. If a user starts the shell directly, see row 1. |
| `theme <id>` for an unknown id | Builtin prints `theme: unknown theme '<id>'. Run 'theme list' for known ids.` Sets exit status 2. |
| OSC 7777 received in v2 | Consumed silently. Re-render next prompt. No echo. |

## Security

OSC 7777 is treated as UI signal only. It can change the shell's *visual* accent. It cannot change exit status, run commands, write files, or modify history. The OSC consumer is bounded to 256 bytes between `ESC ]` and `ESC \`; oversized sequences are dropped.

`ZIGGYZAG_THEME` is parsed with the same `safeRelativePath`-style discipline used elsewhere — only ASCII alphanumerics, dash, and underscore are accepted; anything else is treated as "unknown" and falls back to default.

## Implementation map

| Change | File | LOC |
| --- | --- | --- |
| Expose theme module to shell at build time | `build.zig` | +5 |
| Read env var and store current theme | `apps/shell/src/main.zig` | +20 |
| `theme` builtin (list/get/set/JSON) | `apps/shell/src/main.zig` | +60 |
| Use accent color in prompt arrow | `apps/shell/src/main.zig` | +10 |
| Set `ZIGGYZAG_THEME` in spawn env | `apps/desktop/src/windows_app.zig` | +5 |
| Tests for env-var parsing & builtin | `apps/shell/src/main.zig` | +40 |

Total: roughly 140 lines of additive code, no deletions, no semantic changes to existing prompt rendering.

## Demo script

```sh
# 1. Default
echo $ZIGGYZAG_THEME       # (empty)
theme                       # ziggy (Ziggy)

# 2. Pick a theme manually
export ZIGGYZAG_THEME=tokyo-night
exec ./zig-out/bin/ziggyzag
theme                       # tokyo-night (Tokyo Night)
# Prompt accent now picks Tokyo Night's accent color #7AA2F7

# 3. Inside the desktop host
# Ctrl+Shift+T cycles themes. The status bar reads:
# "Theme: Catppuccin Mocha. Next shells will use it."
# Open a new pane or tab — the new shell uses the new theme.
```

## v2 roadmap

- OSC 7777 plumbing in the shell's input parser.
- Desktop emits OSC 7777 on theme cycle.
- Shell re-renders prompt in place.
- Add a `--watch` flag to `theme` that watches OSC events and prints transitions.

Tracked in [`masterplan.md`](../vision/masterplan.md) as Wave 4 polish.
