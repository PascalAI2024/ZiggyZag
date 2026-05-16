# Contributing Tour

A practical orientation for new contributors. Read [ARCHITECTURE.md](ARCHITECTURE.md) for the high-level design picture; this guide focuses on where the code lives and how to move through it quickly.

## Repo Layout

```
ZiggyZag/
  apps/
    shell/          Shell REPL, builtins, parser, completions, history, prompt themes
    desktop/        Windows Win32/ConPTY host, terminal grid/parser, themes, AgentD panel
    agentd/         JSON-lines sidecar daemon: tools, protocol, provider shaping
    launcher/       macOS/Linux POSIX PTY launcher (thin; imports desktop lib)
  docs/             All documentation (you are here)
  scripts/          PowerShell and shell QA/smoke/release scripts
  build.zig         Single build entry point for all four binaries
  CONTRIBUTING.md   Setup, code style, before-PR checklist
```

## The Four Binaries

| Binary | Source root | Purpose |
| --- | --- | --- |
| `ziggyzag` | `apps/shell/src/main.zig` | Shell REPL and builtins |
| `ziggyzag-desktop` | `apps/desktop/src/main.zig` | Windows native graphical terminal host |
| `ziggyzag-agentd` | `apps/agentd/src/main.zig` | AgentD sidecar (stdio JSON-lines) |
| `ziggyzag-launcher` | `apps/launcher/src/main.zig` | macOS/Linux PTY launcher; imports desktop lib |

All four are declared in `build.zig` and built together by `zig build`. The launcher imports a `desktop` module exported from `apps/desktop/src/lib.zig`.

Windows-specific: `ziggyzag-desktop` and `ziggyzag-launcher` link `user32`, `gdi32`, and `kernel32`. The launcher uses `.windows` subsystem on Windows.

## Build And Test Entry Points

```powershell
# Build all four binaries (outputs to zig-out/bin/)
zig build

# Build and run the shell REPL
zig build run

# Build and run the desktop host
zig build run-desktop

# Build and run agentd (--stdio, --describe-tools, etc.)
zig build run-agentd -- --describe-tools

# Run all test suites
zig build test
```

`zig build test` aggregates test steps from each app's source root. Adding a `test` block anywhere in a `.zig` file that is reachable from the test root (`lib.zig` or `main.zig` for each app) will automatically be picked up.

## Where Each Concern Lives

| Concern | File(s) |
| --- | --- |
| Shell REPL loop | `apps/shell/src/main.zig` or `repl.zig` |
| Command parser | `apps/shell/src/parser.zig` |
| Builtins | `apps/shell/src/builtins.zig` |
| Tab completions | `apps/shell/src/completions.zig` |
| Prompt themes | `apps/shell/src/prompt.zig` |
| Aliases and abbreviations | `apps/shell/src/aliases.zig` |
| Background jobs | `apps/shell/src/jobs.zig` |
| History | `apps/shell/src/history.zig` |
| VT escape parser and grid | `apps/desktop/src/terminal.zig` |
| Desktop themes | `apps/desktop/src/theme.zig` |
| Win32/ConPTY PTY bridge | `apps/desktop/src/pty.zig` |
| Desktop renderer (GDI) | `apps/desktop/src/renderer.zig` |
| AgentD JSON-lines protocol | `apps/agentd/src/protocol.zig` |
| AgentD tools registry | `apps/agentd/src/tools.zig` |
| AgentD entry point / dispatch | `apps/agentd/src/main.zig` |
| POSIX PTY relay | `apps/launcher/src/main.zig` |
| Smoke QA (Windows) | `scripts/smoke.ps1`, `scripts/qa-tomorrow.ps1` |
| Smoke QA (POSIX) | `scripts/smoke.sh` |
| Daily-driver QA | `scripts/daily-driver-qa.ps1` |
| Release artifact build | `scripts/build-release.ps1` |
| Release artifact QA | `scripts/qa-release-artifacts.ps1` |

## How To Add A Test

Zig test blocks live alongside the code they test, not in a separate directory. The pattern is:

1. Add a `test "description" { ... }` block in the relevant `.zig` source file.
2. Make sure the file is reachable from the test root. `build.zig` passes `apps/<app>/src/main.zig` (or `lib.zig` where it exists) as the test root for each app. Any file that is `@import`-ed transitively from that root will have its test blocks included.
3. Run `zig build test` to confirm the new test passes.

Example for a new VT escape sequence test in `apps/desktop/src/terminal.zig`:

```zig
test "new escape sequence smoke" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 80, 24, 1000);
    defer grid.deinit(alloc);
    try grid.feed("\x1b[<params><final>");
    // assert cursor or cell state
    try std.testing.expectEqual(@as(u32, expected_x), grid.cursor_x);
}
```

For protocol or tool tests in `apps/agentd/`, follow the existing patterns in `protocol.zig` and `tools.zig` — both files already have test blocks that cover request parsing and tool dispatch.

## Before Sending A PR

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the full checklist. The short version:

```powershell
zig build
zig build test
.\scripts\smoke.ps1        # Windows
# or: bash scripts/smoke.sh  # POSIX
```

For desktop or AgentD changes, also run:

```powershell
.\scripts\qa-tomorrow.ps1
.\scripts\daily-driver-qa.ps1 -Automated
```

See [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) for the release-artifact build and QA steps.
