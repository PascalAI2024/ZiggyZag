# Contributing

Thanks for taking a look at ZiggyZag. This project is meant to be readable, useful, and friendly to people learning how shells work.

## Setup

Install Zig 0.16.0, then build:

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

## Before Opening A PR

Run:

```sh
zig fmt src/main.zig
zig build
```

Try a tiny smoke test:

```sh
printf "help\nalias hi='echo hello'\nhi world\nexit\n" | ./zig-out/bin/ziggyzag
```

## Code Style

- Prefer straightforward code over abstractions that hide shell behavior.
- Keep comments short and useful.
- Avoid changing CodeCrafters-compatible output unless the change is intentional.
- Keep docs updated when adding user-facing behavior.

## Good First Contributions

- Add focused tests for builtins and parsing behavior.
- Improve parser diagnostics.
- Add prompt customization.
- Add a config file for startup aliases.
- Improve docs with examples and diagrams.
