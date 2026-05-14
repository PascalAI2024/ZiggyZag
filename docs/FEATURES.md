# Features And Roadmap

This file tracks what ZiggyZag already does and what would make it more useful as an everyday shell experiment.

## Completed Capabilities

| Capability | Details |
| --- | --- |
| Interactive REPL | Prompt loop, command input, terminal mode, manual echo handling. |
| Builtins | `echo`, `exit`, `type`, `pwd`, `cd`, `history`, `declare`, `jobs`, `complete`, `help`, `alias`, `unalias`, `export`, `unset`. |
| Command lookup | PATH search and executable detection. |
| Quoting | Single quotes, double quotes, and backslash handling. |
| Redirection | stdout/stderr redirect and append. |
| Completion | Builtin completion, executable completion, path completion, and programmable completion. |
| History | Listing, limits, Up/Down navigation, command recall, read/write/append, startup and exit persistence. |
| Jobs | Background execution, `jobs`, job number reuse, and reaping. |
| Variables | `declare`, validation, `$VAR`, `${VAR}`, and unset expansion behavior. |
| Repo polish | Logo, diagrams, public docs, contribution notes, and a project-named binary. |

## User Experience Roadmap

```mermaid
flowchart TD
    now["Current: compact learning shell"] --> prompt["Prompt themes and status segments"]
    now --> suggest["History-based autosuggestions"]
    now --> abbreviations["Visible abbreviations"]
    now --> config["Startup config file"]
    now --> completion["Richer completions"]
    now --> tests["Local test harness"]
    suggest --> fuzzy["Fuzzy Ctrl-R history search"]
    completion --> descriptions["Completion descriptions"]
    config --> aliases["Persistent aliases"]
    tests --> releases["Release confidence"]
```

## Engineering Roadmap

| Priority | Feature | Why it matters | Size |
| --- | --- | --- | --- |
| 1 | Autosuggestions | Makes the shell feel modern and fast. | M |
| 2 | Rich completion pager | Adds discoverable flags, paths, and command descriptions. | M |
| 3 | Abbreviations | Expands shortcuts before execution so history stays readable. | S |
| 4 | Config file | Makes aliases, prompt settings, and startup commands persistent. | M |
| 5 | Native pipelines | Removes system-shell delegation and teaches process pipes directly. | L |
| 6 | Structured tests | Keeps open-source contributions safe. | M |
| 7 | Prompt customization | Lets users make ZiggyZag feel personal. | S |
| 8 | Better diagnostics | Clear parser errors make the shell easier to learn from. | S |
| 9 | Release builds | Tagged binaries make the repo easier to try. | M |

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
    Local test harness: [0.55, 0.65]
```

For the longer research list and source links, see [ROADMAP.md](ROADMAP.md).

## Open Questions

- Should ZiggyZag stay a learning shell or grow toward daily-driver use?
- Should shell variables and exported environment variables be split into separate stores?
- Should pipelines be parsed and executed natively before adding more UX features?
- Should the config format be shell-like, TOML, or a tiny ZiggyZag-specific format?
