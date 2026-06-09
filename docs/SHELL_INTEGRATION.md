# Shell Integration Protocol

ZiggyZag implements a two-directional shell integration protocol using OSC escape sequences. This document is the authoritative reference for both directions.

## Overview

| Direction | OSC code | Purpose |
|-----------|----------|---------|
| Shell → Desktop | `OSC 777` | Shell lifecycle events (prompt, commands, CWD) |
| Desktop → Shell | `OSC 7777` | Theme updates |
| Shell → Desktop | `OSC 0` | Window title |
| Shell → Desktop | `OSC 7` | CWD as `file://` URI (WezTerm-compatible) |

Integration is **opt-in**: the shell emits events only when `ZIGGYZAG_INTEGRATION=1` or `ZIGGYZAG_APP=1` is present in the environment. The desktop host sets both when it spawns the shell.

---

## Activation

```sh
# Set by the desktop host automatically when spawning the shell.
export ZIGGYZAG_INTEGRATION=1
```

To test integration manually in any terminal:

```sh
ZIGGYZAG_INTEGRATION=1 ziggyzag
```

---

## Shell → Desktop (OSC 777)

### Wire format

```
ESC ] 777 ; ziggyzag:event: <json-payload> BEL
```

- Introducer: `\x1b]777;ziggyzag:event:`
- Terminator: `\x07` (BEL)
- Payload: a single JSON object, no newlines, UTF-8

String values inside the JSON are JSON-escaped (e.g. `\n`, `\"`). Paths use the native separator.

### Events

#### `session.ready`

Emitted once at shell startup, before the first prompt.

```json
{
  "type": "session.ready",
  "protocol": 1,
  "shell": "ziggyzag",
  "version": "0.1.0",
  "prompt_mode": "classic"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `protocol` | integer | Protocol version — always `1` for this spec |
| `shell` | string | Always `"ziggyzag"` |
| `version` | string | Shell binary version |
| `prompt_mode` | string | Active prompt theme (`classic`, `smart`, `compact`, `dev`, `dashboard`) |

#### `prompt.rendered`

Emitted after every prompt is drawn (i.e. when the shell is waiting for input).

```json
{
  "type": "prompt.rendered",
  "cwd": "/home/user/project",
  "prompt_mode": "smart",
  "last_status": 0,
  "last_duration_ms": 142,
  "jobs": 0,
  "project_kind": "zig",
  "git": {
    "branch": "main",
    "staged": 0,
    "changed": 1,
    "untracked": 2,
    "conflicts": 0,
    "ahead": 0,
    "behind": 0
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `cwd` | string | Current working directory |
| `prompt_mode` | string | Active prompt theme |
| `last_status` | integer | Exit status of the previous command (0 on first prompt) |
| `last_duration_ms` | integer | Wall-clock duration of the previous command in milliseconds |
| `jobs` | integer | Number of active background jobs |
| `project_kind` | string \| null | Detected project type (`zig`, `node`, `python`, `rust`, `go`, …) or `null` |
| `git` | object \| null | Git status snapshot, or `null` when not in a repository |
| `git.branch` | string | Current branch name or short SHA |
| `git.staged` | integer | Number of staged files |
| `git.changed` | integer | Number of unstaged tracked changes |
| `git.untracked` | integer | Number of untracked files |
| `git.conflicts` | integer | Number of merge conflicts |
| `git.ahead` | integer | Commits ahead of upstream |
| `git.behind` | integer | Commits behind upstream |

#### `command.started`

Emitted immediately after the user submits a command line, before the child process runs.

```json
{
  "type": "command.started",
  "id": 42,
  "command": "cargo build --release",
  "cwd": "/home/user/project",
  "timestamp": 1748736000000
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Monotonically increasing command identifier, unique within the session |
| `command` | string | The raw command line as submitted |
| `cwd` | string | Working directory at the time of submission |
| `timestamp` | integer | Unix timestamp in milliseconds |

#### `command.finished`

Emitted after every command completes (including builtins).

```json
{
  "type": "command.finished",
  "id": 42,
  "status": 0,
  "duration_ms": 3201,
  "cwd": "/home/user/project"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Matches the `id` from the corresponding `command.started` |
| `status` | integer | Exit status (0 = success) |
| `duration_ms` | integer | Wall-clock duration in milliseconds |
| `cwd` | string | Working directory at completion time (may differ from start if the command used `cd`) |

### Standard OSC companions

The shell also emits standard sequences on every prompt render:

```
ESC ] 0 ; ZiggyZag: <basename(cwd)> BEL    # window title
ESC ] 7 ; file://<hostname><cwd>            # CWD URI (WezTerm / Ghostty compatible)
```

These use the standard `OSC 0` and `OSC 7` codes and are compatible with WezTerm, Ghostty, and other terminals that consume shell integration.

---

## Desktop → Shell (OSC 7777)

### Wire format

```
ESC ] 7777 ; ziggyzag.theme=<theme-id> ESC \
```

- Introducer: `\x1b]7777;`
- Terminator: `\x1b\\` (ST, string terminator)
- `<theme-id>`: a theme identifier recognised by the shell (see `theme list`)

**Why `7777` and not `777`?** OSC 777 is already used for the shell→desktop direction and is consumed by xterm-derived terminals. Reusing it for desktop→shell would cause loops. OSC 7777 is in the application-private range and is unique to ZiggyZag.

### Effect

On receiving this sequence the shell:

1. Updates `Shell.current_theme` in place.
2. Clears the prompt snapshot cache.
3. Redraws the prompt with the new accent colours on the next render cycle.

No restart required. The sequence is consumed silently — it does not appear on screen and is not treated as a command.

### Trigger

The Windows desktop host emits this sequence when the user presses `Ctrl+Shift+T` (cycle theme) or selects a theme via the command palette. The shell ignores sequences with unknown theme IDs without changing state.

---

## Implementing a Host

A third-party terminal host that wants to consume ZiggyZag shell integration should:

1. **Spawn the shell** with `ZIGGYZAG_INTEGRATION=1` in the environment.
2. **Parse the PTY output stream** for the OSC 777 prefix `\x1b]777;ziggyzag:event:` terminated by `\x07`.
3. **Extract the JSON payload** and dispatch on `type`.
4. **Optionally send** OSC 7777 theme updates when the user changes the terminal theme.

Unknown event `type` values must be ignored to allow forward compatibility.

### Minimal parser (pseudocode)

```
state = :normal

for each byte b in pty_output:
  if state == :normal:
    if b == ESC: state = :esc
    else: emit(b)
  elif state == :esc:
    if b == ']': state = :osc; osc_buf = ""
    else: emit(ESC); emit(b); state = :normal
  elif state == :osc:
    if b == BEL or b == ST:
      handle_osc(osc_buf)
      state = :normal
    else:
      osc_buf += b

fn handle_osc(payload):
  if payload.starts_with("777;ziggyzag:event:"):
    json = payload[len("777;ziggyzag:event:"):]
    dispatch_event(parse_json(json))
  elif payload.starts_with("0;"):
    set_window_title(payload[2:])
  elif payload.starts_with("7;file://"):
    set_cwd_uri(payload[2:])
  # ignore others
```

---

## Compatibility

| Terminal | OSC 7 (CWD) | OSC 777 (events) |
|----------|-------------|------------------|
| ZiggyZag desktop | ✓ | ✓ |
| WezTerm | ✓ | partial (reads OSC 777 natively) |
| Ghostty | ✓ | — |
| iTerm2 | ✓ | — |
| kitty | ✓ | — |

ZiggyZag's OSC 777 payload uses `ziggyzag:event:` as a namespace prefix. WezTerm reads OSC 777 with a different namespace (`notify:` etc.) — ZiggyZag events are safely ignored by other terminals.

---

## Security

- The `OSC 777 UI-trust boundary` — deciding which event payloads the desktop may act on without user confirmation — is an open work item. Currently the desktop host uses integration events for UI decoration only (status bar, prompt jump markers); it does not execute shell commands based on event content.
- OSC 7777 theme changes are low-risk: they only update the accent palette, not execute code.
- Hosts should validate JSON payloads and cap payload length. The shell caps outgoing OSC payloads at `max_osc_payload_bytes` (defined in `apps/shell/src/main.zig` line 19).

---

*Source of truth: `apps/shell/src/main.zig` (`writeIntegration*` functions, lines 836–932). Protocol version bumps require updating `protocol` in `session.ready` and this document.*
