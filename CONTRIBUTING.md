# Contributing

Thanks for taking a look at ZiggyZag. This project is meant to be readable, useful, and friendly to people learning how shells work.

## Setup

Install Zig 0.16.0, then build from the repository root:

```sh
zig build
```

Run the shell:

```sh
./zig-out/bin/ziggyzag
```

On Windows:

```powershell
.\zig-out\bin\ziggyzag.exe
```

Run the Windows desktop MVP:

```powershell
zig build run-desktop
```

Inspect the agent sidecar tools:

```sh
zig build run-agentd -- --describe-tools
```

## Before Opening A PR

Run:

```sh
zig build
zig build test
```

Try a tiny smoke test:

```sh
printf "help\nalias hi='echo hello'\nhi world\nexit\n" | ./zig-out/bin/ziggyzag
```

On Windows, run the feature smoke:

```powershell
.\scripts\smoke.ps1
```

On Linux or macOS:

```sh
./scripts/smoke.sh
```

For desktop or agent changes, also run the relevant manual checks:

```powershell
zig build run-desktop
zig build run-agentd -- --describe-tools
'{"id":1,"method":"tools/list"}' | .\zig-out\bin\ziggyzag-agentd.exe --stdio
```

Desktop changes should be tested for launch, typing, Ctrl+C interrupt, paste, Ctrl+Shift+C copy-visible, resize, wheel scrollback, and clean close. AgentD provider changes should report a structured error when the configured Ollama/OpenAI-compatible provider is unavailable.

## Code Style

- Prefer straightforward code over abstractions that hide shell behavior.
- Keep comments short and useful.
- Avoid changing CodeCrafters-compatible output unless the change is intentional.
- Keep docs updated when adding user-facing behavior.
- Keep friend-test instructions accurate when changing build, desktop, or AgentD behavior.

## Good First Contributions

- Add focused tests for builtins and parsing behavior.
- Improve parser diagnostics.
- Add completion specs for real tools.
- Deepen prompt modules.
- Move metadata history to SQLite.
- Improve docs with examples and diagrams.
- Help harden the desktop terminal host under `apps/desktop`.
