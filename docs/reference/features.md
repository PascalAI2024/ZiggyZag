# Features And Roadmap

This file tracks what ZiggyZag already does and what would make it more useful as an everyday shell experiment.

For navigation across the documentation system, start with [README.md](../README.md). For alpha remaining work, use [alpha-tasks.md](../vision/alpha-tasks.md); for research traceability, use [research.md](../vision/research.md); for task flow and evidence rules, use [task-system.md](task-system.md) and [data-map.md](data-map.md).

## Completed Capabilities

| Capability | Details |
| --- | --- |
| Interactive REPL | Prompt loop, command input, cursor-aware editing, terminal mode, manual echo handling, and Ghostty-friendly title/CWD hints. |
| Builtins | `about`, `abbr`, `alias`, `back`, `bg`, `cd`, `complete`, `config`, `declare`, `dirs`, `disown`, `doctor`, `echo`, `env`, `exit`, `export`, `fg`, `forward`, `help`, `history`, `inspect`, `jobs`, `jump`, `kill`, `mkcd`, `path`, `project`, `prompt`, `pwd`, `repeat`, `run`, `source`, `timeit`, `type`, `unalias`, `unabbr`, `unset`, `up`, `vars`, `wait`, `which`. |
| Command lookup | PATH search and executable detection. |
| Quoting | Single quotes, double quotes, and backslash handling. |
| Redirection | stdout/stderr redirect and append. |
| Completion | Builtin completion, executable completion, path completion, programmable completion, declarative specs, and pager descriptions. |
| History | Listing, limits, Up/Down navigation, command recall, fuzzy search, failed/slow/cwd/stats queries, metadata capture, read/write/append/export/clear, enable/disable/private controls, startup and exit persistence. |
| Jobs | Background execution, `jobs`, job number reuse, reaping, and practical `wait`/`kill`/`disown`/`fg`/`bg` builtins. |
| Variables | `declare`, validation, `$VAR`, `${VAR}`, and unset expansion behavior. |
| Modern UX | Startup config, abbreviations, cursor-aware tab completion (quoted/escaped paths), durable cross-session history, autosuggestion hooks, Ctrl-F accept, Ctrl-R fuzzy recall, syntax highlighting on by default, visual prompt themes, and smart prompt modules. |
| Introspection | `about`, `doctor`, `inspect`, `which`, `path`, `project`, slash shortcuts, JSON output for history/jobs/prompt/env/doctor/project/dirs, and config validation/reload. |
| Convenience commands | `mkcd`, `up`, `back`, `forward`, `jump`, `repeat`, `timeit`, `source`, `env`, `vars`, and project-aware `run` make ZiggyZag more useful as a daily shell lab. |
| Pipelines | Native simple pipelines for straightforward stdout chains, concurrent stdout/stderr draining per stage, temp-file handoff for large stage output, and fallback for complex shell syntax. |
| Desktop terminal | Native hosts for Windows (Win32 + ConPTY) and macOS (Cocoa + CoreText). PTY-backed split panes (Windows), styled grid, bounded scrollback, alternate screen, 16/256/RGB colors, bracketed paste, app cursor mode, mouse-wheel reports, command palette, scrollback search, quick select, settings/themes overlay, theme cycling with live OSC 7777 broadcast, copy visible text, Cmd+V paste, AgentD universal input (type → preview → insert), and shell integration events. Tabs, mouse selection, and deeper session restore remain planned hardening work. |
| Unicode terminal | Alpha: cells store Unicode scalars, decode UTF-8 safely, emit UTF-8 text for copy/search/extraction, and track wide-cell continuations. Combining marks, emoji grapheme clusters, fallback fonts, ligatures, and broader TUI compatibility remain planned hardening work. |
| Agent runtime | `ziggyzag-agentd` provides a slim Zig-native JSON-lines agent process with tool discovery, schemas, approval metadata, redacted bounded local file/search/git output, host-action audit events, terminal host actions, and Ollama/OpenAI-compatible provider calls. |
| Tests | Zig unit tests, Windows smoke script, POSIX smoke script, and GitHub Actions CI. |
| Repo polish | Logo, diagrams, public docs, contribution notes, and a project-named binary. |

## Planned Product Tracks

| Track | Shape |
| --- | --- |
| Shell core | Keep deepening ZiggyZag as a compact shell with true streaming pipelines, richer completion schemas, prompt modules, and parser diagnostics. |
| Desktop terminal | Windows-native all-Zig alpha with Win32 windowing, GDI terminal rendering, ConPTY shell hosting, PTY-backed splits, keyboard input, copy/paste, wheel scrollback, resize handling, status bar, tested styled terminal grid, alternate screen, bracketed paste, mouse mode tracking, command palette, search, quick select, AgentD panel, OSC 777 event extraction, themes, profile/session config parsing/application, and a POSIX PTY-first terminal-attached release launcher. Tabs, mouse selection, deeper session restore, and native POSIX graphical windows are next-wave work. |
| Agent panel | First-party `apps/agentd` binary exposes schemas, approval metadata, audit/event host actions, and redacted bounded context; the Windows desktop panel now spawns it, renders health/tool responses, previews `terminal.write`, and requires explicit approval before writing to the active pane. |
| Shared integration | Added a small optional OSC 777 protocol for command lifecycle, cwd, status, duration, jobs, project kind, git state, and prompt context. |

## User Experience Roadmap

```mermaid
flowchart TD
    now["Current: compact modern shell lab"] --> prompt["Deeper prompt modules"]
    now --> suggest["Cursor-aware autosuggestion UI"]
    now --> completion["Completion option schemas"]
    now --> sqlite["Real SQLite history backend"]
    now --> native["Streaming native pipelines"]
    now --> desktop["Desktop terminal host"]
    now --> agentd["Zig-native agentd"]
    desktop --> protocol["Shell integration events"]
    desktop --> agentd
    desktop --> themes["Unified themes"]
    now --> tests["Cross-platform test harness"]
    completion --> descriptions["Dynamic completion descriptions"]
    tests --> releases["Release confidence"]
```

## Engineering Roadmap

| Priority | Feature | Why it matters | Size |
| --- | --- | --- | --- |
| 1 | Cursor-aware line editor | Makes autosuggestions, highlighting, and Ctrl-R work with mid-line edits. | L |
| 2 | Full SQLite backend | Turns the current metadata log into indexed queryable history. | M |
| 3 | Streaming pipelines | Replaces the safer stage-buffered native pipeline with true pipe handles. | L |
| 4 | Completion option schemas | Adds flags, file filters, and dynamic completions. | M |
| 5 | Cross-platform smoke tests | Keeps open-source contributions safe on Windows, Linux, and macOS. | M |
| 6 | Shell integration protocol hardening | Lets the desktop app understand command lifecycle and shell context without screen scraping. | M |
| 7 | Desktop terminal MVP hardening | Makes ZiggyZag easier to try with tabs, splits, selection-aware copy, native POSIX windows, and stronger settings editing. | L |
| 8 | Agent panel hardening | Extends the new panel with richer prompts, read-only tool browsing, audit export, and provider streaming without embedding a heavy app stack. | M |
| 9 | Better diagnostics | Clear parser errors make the shell easier to learn from. | S |
| 10 | Release builds | Tagged binaries make the repo easier to try. | M |

## Feature Shape

```mermaid
quadrantChart
    title Potential feature fit
    x-axis Low implementation effort --> High implementation effort
    y-axis Small user impact --> Large user impact
    quadrant-1 Strategic bets
    quadrant-2 Quick wins
    quadrant-3 Backlog
    quadrant-4 Big bets
    Help builtin: [0.15, 0.45]
    Aliases: [0.30, 0.70]
    Abbreviations: [0.25, 0.76]
    Prompt themes: [0.25, 0.62]
    Autosuggestions: [0.55, 0.82]
    Rich completion pager: [0.52, 0.80]
    Native pipelines: [0.82, 0.70]
    Config file: [0.48, 0.72]
    Metadata history: [0.55, 0.74]
    Smart prompt: [0.45, 0.65]
    Local test harness: [0.55, 0.65]
```

For the longer research list and source links, see [roadmap.md](../vision/roadmap.md) and [research.md](../vision/research.md). For the current daily-driver execution backlog, see [next-20-features.md](../vision/next-20-features.md). For the implementation-wave task list and alpha/TODO labels, see [alpha-tasks.md](../vision/alpha-tasks.md). Component drill-downs live in [apps/desktop](../../apps/desktop/README.md) and [apps/agentd](../../apps/agentd/README.md).

## Open Questions

- Should ZiggyZag stay a learning shell or grow toward daily-driver use?
- Should shell variables and exported environment variables be split into separate stores?
- Should native pipelines move from safer stage buffering to a true streaming pipe chain next?
- Should the config format stay shell-like or grow a JSON/TOML profile format?
- Should the PTY backend strip app-only OSC events from terminal output and emit them separately, or should the frontend continue parsing raw terminal data?
