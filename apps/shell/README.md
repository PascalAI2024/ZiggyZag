# ZiggyZag Shell

This app contains the working Zig shell runtime. Root-level `zig build`, `zig build run`, and `zig build test` target this binary so CI, smoke scripts, and local development keep the same command surface.

The executable name remains `ziggyzag`. Desktop or editor integrations should launch the built binary through a PTY rather than linking against shell internals.

## Prompt Themes

`prompt themes` lists the built-in shell prompt themes. `classic` stays plain, while `smart`, `compact`, `dev`, and `dashboard` add useful context such as cwd, project type, git branch/status counts, ahead/behind counts, last exit status, command duration, and background jobs.

Set `ZIGGYZAG_PROMPT=dev` or put `prompt dev` in `~/.ziggyzagrc` to start with the richest prompt. Set `ZIGGYZAG_PROMPT_GIT_STATUS=0` to keep branch detection but skip `git status` counts.

## Source

- `src/main.zig`: REPL, parsing, execution, builtins, history, completions, jobs, prompts, and terminal integration hints.

## Development

```sh
zig fmt apps/shell/src/main.zig build.zig
zig build
zig build test
```
