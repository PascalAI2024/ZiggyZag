# Product Scope

ZiggyZag is scoped as a workspace for three related products:

1. A compact Zig shell that remains readable, testable, and useful on its own.
2. A Zig-native desktop terminal app that hosts that shell through a PTY and adds a unified visual/product experience.
3. A slim Zig-native agent runtime for terminal-aware assistance experiments.

The shell is the source of truth. The desktop app is a host and enhancer.

## In Scope

| Area | Commitment |
| --- | --- |
| Shell runtime | Keep improving parsing, execution, history, completions, prompts, jobs, project tasks, and shell-native learning features. |
| Terminal compatibility | Keep ZiggyZag usable in normal terminals with stable stdout/stderr behavior and optional integration hints. |
| Desktop host | Keep hardening the first-party Zig-native app around a real PTY, terminal grid rendering, tabs, search, themes, settings, and command palette actions. |
| Agent runtime | Keep AI assistance slim and native with a Zig `agentd` process, JSON-lines protocol, approval-aware terminal/file/build tools, and OpenAI-compatible/Ollama provider hooks. |
| Shell integration | Add optional, versioned events for command lifecycle, cwd, status, duration, jobs, prompt context, and capabilities. |
| Unified themes | Share a theme vocabulary between prompt colors, syntax highlighting, and the terminal app. |
| Product spikes | Keep non-Zig scaffolds only as temporary experiments, not the primary product direction. |
| Documentation | Keep the repo organized so contributors can tell what belongs to the shell, the desktop host, and shared product direction. |

## Out Of Scope For Now

- Replacing mature shells such as zsh, fish, PowerShell, or Nushell.
- Embedding WezTerm wholesale or depending on WezTerm internals.
- Depending on Tauri, xterm.js, or Rust for the long-term first-party terminal host.
- Building remote SSH, multiplexing, cloud sync, team accounts, or app-store-grade packaging before the local desktop host is solid.
- Moving command parsing or execution responsibility from ZiggyZag into the desktop UI.

## Product Principles

- Keep the CLI excellent without the desktop app.
- Use conventional PTY behavior first; add ZiggyZag-specific intelligence beside it.
- Prefer Zig for primary product code when the tradeoff is reasonable.
- Prefer explicit structured events over screen scraping.
- Keep root commands stable: `zig build`, `zig build run`, and `zig build test`.
- Let the app make the shell more discoverable without hiding how shells work.

## Repo Ownership

| Path | Owner |
| --- | --- |
| `apps/shell` | Zig shell runtime and tests. |
| `apps/desktop` | All-Zig desktop terminal host MVP. |
| `apps/agentd` | Zig-native JSON-lines agent runtime. |
| `apps/desktop-tauri-spike` | Temporary webview prototype preserved for reference. |
| `docs` | Architecture, scope, roadmap, and strategy. |
| `scripts` | Local smoke and verification scripts. |
| `assets` | Shared branding and visual assets. |

## Next Scope Gate

The next major scope decision is the all-Zig desktop stack: windowing/rendering layer, PTY abstraction, and whether to use `libghostty-vt` immediately or after a small local ANSI parser proves the host boundary.
