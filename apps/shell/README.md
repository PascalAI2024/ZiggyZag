# ZiggyZag Shell

This app contains the working Zig shell runtime. Root-level `zig build`, `zig build run`, and `zig build test` still target this binary so CodeCrafters, CI, smoke scripts, and local development keep the same command surface.

The executable name remains `ziggyzag`. Desktop or editor integrations should launch the built binary through a PTY rather than linking against shell internals.

## Source

- `src/main.zig`: REPL, parsing, execution, builtins, history, completions, jobs, prompts, and terminal integration hints.

## Development

```sh
zig fmt apps/shell/src/main.zig build.zig
zig build
zig build test
```
