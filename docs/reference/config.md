# Configuration Reference

This document covers all configurable options for ZiggyZag's shell and desktop host.

## Shell Config File (`~/.ziggyzagrc`)

ZiggyZag loads `~/.ziggyzagrc` at startup (or the path in `$ZIGGYZAG_CONFIG`). It runs each line as a shell command before the interactive prompt appears.

**Aliases** — `alias NAME=VALUE`
```
alias gs="git status --short"
alias ll="ls -la"
```

**Abbreviations** — `abbr NAME=VALUE`
```
abbr gco="git checkout"
abbr mkcd="mkdir $1 && cd $1"
```
Abbreviations expand on Space, Tab, or Enter — history stores the real command, not the abbreviation.

**Tab completions** — `complete -c COMMAND -a FLAGS -d DESCRIPTION`
```
complete git -a "status add commit push pull checkout branch log diff stash" -d "Git subcommand"
complete zig -a "build fmt test run clean" -d "Common Zig commands"
```

Subcommand trees — use `--options` to specify which argument position gets completions:
```
complete git -a "status add commit push pull checkout branch" -d "git subcommand"
complete git checkout -a "main develop feature/test-fix" --options 1 -d "git checkout branch"
```
When `--options 1` is set, completions for `git checkout` only appear on the second argument (after the subcommand).

**Prompt theme** — `prompt THEME`
```
prompt dev     # git branch + status + jobs + runtime
prompt smart   # git-aware, falls back to cwd
prompt classic # minimal, no git
prompt compact # cwd only
```
Run `prompt` without arguments to cycle themes.

**Config commands**
```
config path              # print config file path
config prompt           # show current prompt theme
config reload          # reload ~/.ziggyzagrc
doctor [--json]         # runtime diagnostics
```

## Desktop Config File (`%APPDATA%/ZiggyZag/desktop.conf`)

Written by the settings overlay or directly as TOML. Fields are validated on load.

```toml
schema_version = 1

[font]
family = "Cascadia Mono"
size = 14

[options]
show_status_bar = true
smooth_scroll = true
bell = false
scrollback_lines = 10000

[profile]
shell_path = ""
startup_directory = ""
term = "xterm-256color"
agentd_autostart = false
agentd_socket = ""

[session]
panes = 1
orientation = "vertical"
```

## Keyboard Shortcuts

### Desktop Host (Windows)

| Shortcut | Action |
| --- | --- |
| Ctrl+Shift+P | Open command palette |
| Ctrl+Shift+F | Open search overlay |
| Ctrl+Shift+O | Quick select (URLs, paths, hashes) |
| Ctrl+Shift+D | Split pane right (vertical split) |
| Ctrl+Shift+E | Split pane down (horizontal split) |
| Ctrl+Shift+N | Focus next pane |
| Ctrl+Shift+B | Focus previous pane |
| Ctrl+Shift+W | Close active pane |
| Ctrl+Shift+R | Reload config |
| Ctrl+Shift+T | Cycle to next theme |
| Ctrl+Shift+C | Copy visible text |
| Ctrl+Shift+A | Toggle AgentD panel |
| Ctrl+, | Toggle settings overlay |
| Ctrl+C | Send SIGINT to shell |
| Ctrl+V | Paste from clipboard |
| Shift+Insert | Paste from clipboard |
| Ctrl+L | Clear scrollback |
| Ctrl+S | Block (XOFF, prevented) |
| Ctrl+Z | Suspend shell |
| Tab | Tab completion |
| Enter | Submit line / AgentD approve write / Search jump to match |
| Escape | Close overlay / cancel |
| Up/Down | Navigate history or palette |
| Left/Right | Edit cursor |
| Mouse wheel | Scroll |

### Desktop Host (macOS)

Activate with `ZIGGYZAG_NATIVE_WINDOW=1 ziggyzag-desktop`.

| Shortcut | Action |
| --- | --- |
| Ctrl+Shift+P | Open command palette (searchable action menu) |
| Ctrl+Shift+F | Scrollback search |
| Ctrl+Shift+O | Quick select (URLs, paths, hashes) |
| Ctrl+Shift+T | Cycle theme forward (live OSC 7777 broadcast) |
| Ctrl+, | Toggle settings overlay (theme grid, info) |
| Ctrl+Space | AgentD universal input (type → preview → insert) |
| Cmd+Shift+C | Copy visible terminal text |
| Cmd+V | Paste (bracketed-paste aware) |
| Ctrl+C | Send SIGINT to shell |
| Enter | Submit line / run palette action / send AgentD prompt |
| Escape | Close overlay / cancel |
| Up/Down | Navigate history or palette items |
| Left/Right | Edit cursor / navigate search/quick-select items |
| Mouse wheel | Scroll |

### Desktop Host (Linux)

Linux builds the shell and AgentD and runs a terminal-attached launcher (`ziggyzag`). No native graphical window yet — planned for a later wave. Shell shortcuts below apply on Linux.

### Shell (standalone)

| Shortcut | Action |
| --- | --- |
| Tab | Tab completion |
| Ctrl+R | History search |
| Ctrl+C | Cancel input |
| Ctrl+D | EOF / exit |
| Ctrl+Z | Suspend shell |
| Ctrl+L | Clear screen |
| Ctrl+A / Ctrl+E | Move to start/end of line |
| Alt+B / Alt+F | Word jump |
| Ctrl+W | Delete word |
| Ctrl+U | Delete to start of line |
| Ctrl+K | Delete to end of line |
| Ctrl+_ | Undo |

## Environment Variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `ZIGGYZAG_CONFIG` | Shell config path | `~/.ziggyzagrc` |
| `HISTFILE` | Shell history file | `~/.ziggyzag_history` |
| `ZIGGYZAG_HISTORY_DB` | Metadata history SQLite DB | `""` |
| `ZIGGYZAG_AGENT_PROVIDER` | AgentD provider (`ollama`, `openai-compatible`) | `ollama` |
| `ZIGGYZAG_AGENT_BASE_URL` | Provider base URL | `http://127.0.0.1:11434` |
| `ZIGGYZAG_AGENT_MODEL` | Model name | `qwen2.5-coder:1.5b` |
| `ZIGGYZAG_AGENT_API_KEY` | API key for OpenAI-compatible providers | `""` |
| `ZIGGYZAG_AGENT_TIMEOUT_MS` | Tool execution timeout in ms | `120000` |

## Built-In Abbreviations

Loaded automatically at startup (before `~/.ziggyzagrc`, so your config can override):

| Abbreviation | Expands to |
| --- | --- |
| `gco` | `git checkout` |
| `ga` | `git add` |
| `gc` | `git commit` |
| `gs` | `git status` |
| `gp` | `git push` |
| `gl` | `git pull` |
| `gd` | `git diff` |
| `glo` | `git log --oneline` |
| `mkcd` | `mkdir $1 && cd $1` |

## Built-In Tab Completions

Loaded automatically at startup (before `~/.ziggyzagrc`, so your config can override):

| Command | Completions |
| --- | --- |
| `git` | `status add commit push pull checkout branch log diff stash` |
| `zig` | `build fmt test run clean` |
| `npm` | `install run start dev test build` |
| `cargo` | `build run test fmt clippy check` |
| `go` | `run build test fmt vet` |
| `docker` | `run build pull push ps images` |

## AgentD Provider Setup

### Ollama (default)

```powershell
$env:ZIGGYZAG_AGENT_PROVIDER = "ollama"
$env:ZIGGYZAG_AGENT_BASE_URL = "http://127.0.0.1:11434"
$env:ZIGGYZAG_AGENT_MODEL = "qwen2.5-coder:1.5b"
```

### OpenAI-compatible

```powershell
$env:ZIGGYZAG_AGENT_PROVIDER = "openai-compatible"
$env:ZIGGYZAG_AGENT_BASE_URL = "https://api.openai.com"
$env:ZIGGYZAG_AGENT_MODEL = "gpt-4.1-mini"
$env:ZIGGYZAG_AGENT_API_KEY = "<your-key>"
```

Run `doctor` to see the current configuration and any diagnostics.