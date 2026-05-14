# Features And Roadmap

This file tracks what ZiggyZag already does and what would make it more useful as an everyday shell experiment.

## Completed Capabilities

| Capability | Details |
| --- | --- |
| Interactive REPL | Prompt loop, command input, terminal mode, manual echo handling. |
| Builtins | `about`, `abbr`, `alias`, `cd`, `complete`, `config`, `declare`, `doctor`, `echo`, `env`, `exit`, `export`, `help`, `history`, `inspect`, `jobs`, `mkcd`, `path`, `prompt`, `pwd`, `repeat`, `source`, `timeit`, `type`, `unalias`, `unabbr`, `unset`, `up`, `vars`, `which`. |
| Command lookup | PATH search and executable detection. |
| Quoting | Single quotes, double quotes, and backslash handling. |
| Redirection | stdout/stderr redirect and append. |
| Completion | Builtin completion, executable completion, path completion, programmable completion, declarative specs, and pager descriptions. |
| History | Listing, limits, Up/Down navigation, command recall, fuzzy search, metadata capture, read/write/append, startup and exit persistence. |
| Jobs | Background execution, `jobs`, job number reuse, and reaping. |
| Variables | `declare`, validation, `$VAR`, `${VAR}`, and unset expansion behavior. |
| Modern UX | Startup config, abbreviations, autosuggestion hooks, Ctrl-F accept, Ctrl-R fuzzy recall, syntax highlighting in smart prompt mode, and smart prompt modules. |
| Introspection | `about`, `doctor`, `inspect`, `which`, `path`, slash shortcuts, JSON output for history/jobs/prompt/env/doctor, and config validation/reload. |
| Convenience commands | `mkcd`, `up`, `repeat`, `timeit`, `source`, `env`, and `vars` make ZiggyZag more useful as a daily shell lab. |
| Pipelines | Native simple pipelines for straightforward stdout chains, with fallback for complex shell syntax. |
| Tests | Zig unit tests, Windows smoke script, POSIX smoke script, and GitHub Actions CI. |
| Repo polish | Logo, diagrams, public docs, contribution notes, and a project-named binary. |

## User Experience Roadmap

```mermaid
flowchart TD
    now["Current: compact modern shell lab"] --> prompt["Deeper prompt modules"]
    now --> suggest["Cursor-aware autosuggestion UI"]
    now --> completion["Completion option schemas"]
    now --> sqlite["Real SQLite history backend"]
    now --> native["Streaming native pipelines"]
    now --> tests["Cross-platform test harness"]
    completion --> descriptions["Dynamic completion descriptions"]
    tests --> releases["Release confidence"]
```

## Engineering Roadmap

| Priority | Feature | Why it matters | Size |
| --- | --- | --- | --- |
| 1 | Cursor-aware line editor | Makes autosuggestions, highlighting, and Ctrl-R work with mid-line edits. | L |
| 2 | Full SQLite backend | Turns the current metadata log into indexed queryable history. | M |
| 3 | Streaming pipelines | Replaces the current buffered native pipeline MVP with true pipe handles. | L |
| 4 | Completion option schemas | Adds flags, file filters, and dynamic completions. | M |
| 5 | Cross-platform smoke tests | Keeps open-source contributions safe on Windows, Linux, and macOS. | M |
| 6 | Better diagnostics | Clear parser errors make the shell easier to learn from. | S |
| 7 | Release builds | Tagged binaries make the repo easier to try. | M |

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

For the longer research list and source links, see [ROADMAP.md](ROADMAP.md).

## Open Questions

- Should ZiggyZag stay a learning shell or grow toward daily-driver use?
- Should shell variables and exported environment variables be split into separate stores?
- Should native pipelines stay buffered for readability or move to streaming pipes next?
- Should the config format stay shell-like or grow a JSON/TOML profile format?
