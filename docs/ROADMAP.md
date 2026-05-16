# Research-Backed Roadmap

This roadmap is based on a quick survey of modern shells, terminal emulators, and shell-adjacent tools. The goal is not to clone all of them. The goal is to choose features that make ZiggyZag useful while keeping it readable.

The first sprints implemented MVP versions of the top interactive ideas: autosuggestion hooks, richer completion output, declarative completions, metadata history, fuzzy recall, smart prompt modules, abbreviations, startup config, native simple pipelines, cursor-aware editing, directory history, and project-aware tasks.

The daily-driver terminal backlog now lives in [NEXT_20_FEATURES.md](NEXT_20_FEATURES.md). That list is the current execution order for the Ghostty/WezTerm-inspired terminal, shell, settings, and agent work.

## Ranked Feature Ideas

| Rank | Feature | Inspiration | Why users care | Size | Fit |
| ---: | --- | --- | --- | --- | --- |
| 1 | Inline autosuggestions | [fish autosuggestions](https://fishshell.com/docs/current/interactive.html#autosuggestions), [PowerShell predictors](https://learn.microsoft.com/en-us/powershell/scripting/learn/shell/using-predictors?view=powershell-7.6) | Makes common commands fast and makes the shell feel current. | M | Excellent: builds on existing history and readline code. |
| 2 | Rich completion pager | [fish tab completion](https://fishshell.com/docs/current/interactive.html#tab-completion), [zsh completion system](https://zsh.sourceforge.io/Doc/Release/Completion-System.html) | Users need discoverable flags, arguments, paths, and descriptions. | M | Excellent: current completion code can evolve into candidates plus metadata. |
| 3 | Declarative completion specs | [Fig autocomplete specs](https://github.com/withfig/autocomplete), [fish complete](https://fishshell.com/docs/current/cmds/complete.html) | Lets contributors add command intelligence without editing parser internals. | M | Strong: expands the existing `complete` builtin into a public extension point. |
| 4 | SQLite command history | [Atuin CLI](https://docs.atuin.sh/cli/) | Enables search by directory, host, exit code, duration, and context. | M | Strong: current `HISTFILE` can remain as import/export fallback. |
| 5 | Fuzzy Ctrl-R history UI | [Atuin search](https://docs.atuin.sh/cli/) | Fast recall is one of the most sticky shell features. | M | Strong: first TUI-style surface without becoming a terminal emulator. |
| 6 | Syntax highlighting and error underlines | [fish syntax highlighting](https://fishshell.com/docs/current/interactive.html#syntax-highlighting), [Warp input UX](https://docs.warp.dev/terminal/universal-input) | Makes quotes, pipes, redirects, and missing commands visible before Enter. | M | Strong: parser can eventually emit token spans. |
| 7 | Abbreviations | [fish abbreviations](https://fishshell.com/docs/current/interactive.html#abbreviations) | Users see expanded commands before running them, and history stores the real command. | S | Excellent: builds naturally from current alias support. |
| 8 | Context-aware prompt modules | [Starship guide](https://starship.rs/guide/), [Starship modules](https://starship.rs/config/) | Git branch, exit status, jobs, and runtime versions provide ambient context. | M | Strong: good opportunity for fast Zig-native prompt segments. |
| 9 | Structured output mode | [Nushell pipelines](https://www.nushell.sh/book/pipelines.html), [PowerShell pipelines](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_pipelines?view=powershell-7.6), [Murex typed pipelines](https://nojs.murex.rocks/docs/user-guide/pipeline.html) | Avoids brittle text parsing for JSON, process lists, git status, and tables. | L | High-upside, but should stay opt-in. |
| 10 | Inspect pipeline debug mode | [Nushell pipelines](https://www.nushell.sh/book/pipelines.html) | Helps users understand each pipeline stage while building commands. | M/L | Distinctive learning-first ZiggyZag feature. |
| 11 | Command palette or slash commands | [Warp command palette](https://docs.warp.dev/terminal/command-palette), [Warp universal input](https://docs.warp.dev/terminal/universal-input) | Makes shell actions discoverable: help, jobs, history, config, themes, completions. | M | Good fit as a shell-native `/` namespace or keybinding later. |
| 12 | Zig-native desktop terminal host | [Ghostty](https://github.com/ghostty-org/ghostty), [Ghostling](https://github.com/ghostty-org/ghostling), [WezTerm](https://wezterm.org/) | Makes the shell easy to try and gives ZiggyZag a unified themed experience. | L | Strong: host the shell through a PTY and build the primary app in Zig. |
| 13 | Shell integration protocol | [WezTerm shell integration](https://wezterm.org/shell-integration.html), [OSC conventions](https://wezterm.org/escape-sequences.html) | Lets the app show cwd, status, duration, jobs, and command lifecycle without screen scraping. | M | Strong: current title/CWD hints are the natural seed. |
| 14 | Terminal AI sidecar | Terax-style agent side panel, MCP-style tools, Ollama/OpenAI-compatible providers | Gives ZiggyZag a modern assistant without embedding Node, Tauri, or a heavy SDK. | M/L | Strong: the `apps/agentd` MVP establishes the slim Zig-native boundary. |
| 15 | Shell-native Zig scripting hooks | [xonsh tutorial](https://xon.sh/tutorial.html) | Gives ZiggyZag a unique identity beyond POSIX-like behavior. | L | Brand-defining, but later. Start with external helper hooks first. |

## Suggested Order

```mermaid
flowchart LR
    a["Done: MVP modern UX sprint"] --> b["Done: Cursor-aware line editor"]
    b --> c["1. Full SQLite history backend"]
    c --> d["2. Streaming native pipelines"]
    d --> e["3. Completion option schemas"]
    e --> f["Done: Shell integration protocol MVP"]
    f --> g["Done: Windows all-Zig desktop MVP"]
    g --> h["Done: Zig-native agentd MVP"]
    h --> i["4. Desktop hardening and packaging"]
    i --> j["5. Structured output experiments"]
```

## Product Direction

ZiggyZag should first become a delightful learning shell and then a focused terminal experience:

- Keep the code readable.
- Make interactive use feel modern.
- Add features that teach shell internals.
- Keep POSIX-like behavior as the default path.
- Add experimental features behind clear commands or config flags.
- Keep the desktop app as a host for the shell, not a replacement for it.
- Use explicit integration events instead of screen scraping.

That suggests the next five implementation targets should be:

1. A real SQLite history backend behind the current metadata history log.
2. Streaming native pipelines with redirection support.
3. Completion option schemas for flags, file filters, and dynamic descriptions.
4. Hardening the versioned shell integration event stream for prompt and command lifecycle metadata.
5. Wiring `apps/agentd` into the desktop host as an approval-aware side panel.
