# Quick Start

This page is the practical path for building and trying ZiggyZag locally.

Install [Zig 0.16.0](https://ziglang.org/download/) first. From a fresh checkout:

```sh
git clone https://github.com/PascalAI2024/ZiggyZag.git
cd ZiggyZag
zig build
./zig-out/bin/ziggyzag
```

On Windows PowerShell:

```powershell
git clone https://github.com/PascalAI2024/ZiggyZag.git
cd ZiggyZag
zig build
.\zig-out\bin\ziggyzag.exe
```

## Desktop Host

On Windows, use the launcher for the native desktop terminal host:

```powershell
.\zig-out\bin\ziggyzag-launcher.exe
```

You can also run the desktop host through the Zig build graph:

```powershell
zig build run-desktop
```

On macOS/Linux, the desktop command currently launches ZiggyZag in the calling terminal. It prefers `script(1)` as a PTY wrapper and falls back to direct stdio when needed. A separate native window is not expected on those platforms yet.

```sh
zig build
./zig-out/bin/ziggyzag
./zig-out/bin/ziggyzag-agentd --describe-tools
./scripts/smoke.sh
zig build run-desktop
```

## Desktop Themes And Settings

On Windows, press `Ctrl+,` in the native desktop window to open the settings overlay. Press `Ctrl+Shift+P` for the command palette, `Ctrl+Shift+F` for scrollback search, `Ctrl+Shift+O` for quick select, and `Ctrl+Shift+T` to cycle the built-in themes live.

Built-in theme ids:

```text
ziggy
catppuccin-mocha
tokyo-night
dracula
nord
rose-pine
gruvbox-dark
everforest-dark
kanagawa-wave
solarized-dark
one-dark
paper
ember
```

Persistent desktop settings load from `%APPDATA%\ZiggyZag\desktop.conf` on Windows. You can point at a custom file with `ZIGGYZAG_DESKTOP_CONFIG`.

Example `desktop.conf`:

```ini
theme = catppuccin-mocha
font.family = Cascadia Mono
font.size = 14
show_status_bar = true
smooth_scroll = true
bell = false
scrollback.lines = 10000

# Optional host profile
profile.shell = C:\path\to\ziggyzag.exe
profile.cwd = C:\Users\you\dev
profile.term = xterm-256color

# Optional per-theme overrides
theme.background = #1e1e2e
theme.foreground = #cdd6f4
theme.cursor = #f5e0dc
theme.accent = #89b4fa
theme.panel = #181825
theme.muted = #a6adc8
```

The shell startup config is separate. ZiggyZag shell commands still load from `$ZIGGYZAG_CONFIG` or `~/.ziggyzagrc`:

```sh
alias gs='git status --short'
abbr gco='git checkout'
complete -c zig -a 'build fmt test' -d 'common Zig command'
prompt dev
export ZIGGYZAG_HISTORY_DB=~/.ziggyzag-history.tsv
```

## Prompt Themes

List the shell prompt themes:

```sh
prompt themes
```

Switch prompt themes:

```sh
prompt smart
prompt compact
prompt dev
prompt dashboard
```

Useful slash shortcuts:

```sh
/smart
/compact
/dev
/dashboard
/themes
```

The visual prompt themes can show project type, git branch, staged/changed/untracked/conflict counts, ahead/behind counts, exit status, command duration, and background jobs. Set `ZIGGYZAG_PROMPT_GIT_STATUS=0` if you want branch-only git prompts.

## AgentD

List the terminal-aware tools exposed by the agent sidecar:

```sh
zig build run-agentd -- --describe-tools
```

Start the JSON-lines protocol:

```sh
zig build run-agentd -- --stdio
```

Health check example:

```sh
printf '%s\n' '{"id":1,"method":"agent/health"}' | ./zig-out/bin/ziggyzag-agentd --stdio
```

On Windows:

```powershell
'{"id":1,"method":"agent/health"}' | .\zig-out\bin\ziggyzag-agentd.exe --stdio
```

## CodeCrafters Wrapper

The CodeCrafters-compatible wrapper still works:

```sh
./your_program.sh
```

## Try This

```sh
declare project=ZiggyZag
echo hello_${project}

alias gs='git status --short'
gs

abbr gco='git checkout'
gco main

complete -c zig -a 'build fmt test' -d 'common Zig command'
prompt dev

export EDITOR=vim
echo $EDITOR

which zig
path --json
timeit echo quick
repeat 2 echo again
project
run --list
dirs
history --stats
history status
history export .ziggyzag-history.json --json

inspect echo hello | grep hello
doctor
history --search zig
```

## Development Commands

Build:

```sh
zig build
```

Run:

```sh
zig build run
```

Run the all-Zig desktop target:

```sh
./zig-out/bin/ziggyzag-launcher
zig build run-desktop
```

Run the Zig-native agent runtime:

```sh
zig build run-agentd -- --describe-tools
zig build run-agentd -- --stdio
```

Unit tests:

```sh
zig build test
```

Smoke test:

```sh
printf "help\nalias hi='echo hello'\nhi world\nexit\n" | ./zig-out/bin/ziggyzag
```

Feature smoke:

```sh
./scripts/smoke.sh
```

On Windows:

```powershell
.\scripts\smoke.ps1
.\scripts\qa-tomorrow.ps1
```

## Friend Testing

For normal desktop testing today, use the all-Zig Windows app. On macOS/Linux, test the shell, AgentD, smoke script, and terminal-attached desktop launcher. The Tauri/xterm.js version is preserved only as a spike under `apps/desktop-tauri-spike`.

Windows order:

1. Install Zig 0.16.0 and confirm `zig version` prints `0.16.0`.
2. Run `zig build`.
3. Run `.\scripts\qa-tomorrow.ps1`.
4. Run `.\zig-out\bin\ziggyzag.exe` and try `help`, `doctor`, `history --stats`, `project`, and `exit`.
5. Run `.\scripts\smoke.ps1`.
6. Run `.\zig-out\bin\ziggyzag-launcher.exe` and test typing, Enter, Backspace, Ctrl+C interrupt, paste, copy-visible text, resize, scrollback, `Ctrl+,` settings, `Ctrl+Shift+P` palette, `Ctrl+Shift+F` search, `Ctrl+Shift+O` quick select, and `Ctrl+Shift+T` theme cycling.
7. Run `zig build run-agentd -- --describe-tools`.
8. Run `zig build run-agentd -- --stdio` and send `{"id":1,"method":"agent/health"}`.

macOS/Linux alpha order:

1. Install Zig 0.16.0 and confirm `zig version` prints `0.16.0`.
2. Run `zig build`.
3. Run `./scripts/smoke.sh`.
4. Run `./zig-out/bin/ziggyzag` and try `help`, `doctor`, `history --stats`, `project`, and `exit`.
5. Run `./zig-out/bin/ziggyzag-agentd --describe-tools`.
6. Run `printf '%s\n' '{"id":1,"method":"agent/health"}' | ./zig-out/bin/ziggyzag-agentd --stdio`.
7. Run `zig build run-desktop`, confirm it launches ZiggyZag in the current terminal, then type `exit`.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `zig` is not recognized | Install Zig 0.16.0 and open a fresh terminal, or add the Zig folder to `PATH`. On Windows, `winget install zig.zig` is usually enough. |
| `.\zig-out\bin\ziggyzag.exe` is missing | Run `zig build` from the repo root first. |
| `.\scripts\smoke.ps1` says the binary is missing | Run `zig build`, then rerun the smoke script from the repo root. |
| Desktop window opens but shell does not start | Confirm `zig-out\bin\ziggyzag.exe` exists and that antivirus did not quarantine a local build artifact. |
| macOS/Linux `zig build run-desktop` does not open a window | Expected for this alpha. It should launch ZiggyZag in the current terminal through `script(1)` when available; use `./zig-out/bin/ziggyzag` directly if you do not want the launcher banner. |
| AgentD returns `provider_error` from `--oneshot` or `agent/run` | This is expected when Ollama or the configured OpenAI-compatible provider is not running. Tool listing, `agent/health`, and local tool calls should still work. |
| Ollama request fails | Start Ollama, confirm `http://127.0.0.1:11434` is reachable, and set `ZIGGYZAG_AGENT_MODEL` to a local model you have pulled. |
