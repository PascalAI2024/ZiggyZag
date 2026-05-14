# Architecture

ZiggyZag is intentionally compact: most behavior lives in `src/main.zig`, with small structs for shell state, parsed commands, completion specs, aliases, abbreviations, history metadata, and background jobs. That makes the project easy to step through while still showing real shell concerns.

## Runtime Schematic

```mermaid
flowchart LR
    terminal["Terminal"] --> repl["Shell.run"]
    repl --> readline["readLine"]
    repl --> config["startup config"]
    readline --> history["history list + metadata"]
    readline --> completion["completion engine"]
    readline --> suggest["autosuggestion / fuzzy recall"]
    repl --> execute["execute"]
    execute --> abbr["abbreviation expansion"]
    abbr --> alias["alias expansion"]
    alias --> parser["parseCommandExpanded"]
    parser --> redirects["redirection extraction"]
    parser --> expansion["parameter expansion"]
    execute --> builtins["builtin handlers"]
    execute --> pipeline["native simple pipeline"]
    execute --> system["system shell fallback"]
    execute --> jobs["background job table"]
    builtins --> emit["emitCommandOutput"]
    pipeline --> emit
    system --> emit
    emit --> terminal
    emit --> files["redirected files"]
```

## Command Lifecycle

1. The REPL prints a prompt and reads bytes from stdin.
2. Startup config can register aliases, abbreviations, completions, exports, and prompt mode.
3. Terminal editing handles tabs, backspace, Up/Down history navigation, Ctrl-F autosuggestion accept, and Ctrl-R fuzzy recall.
4. Non-empty commands are stored in history, and execution metadata is recorded.
5. Abbreviations and aliases expand the first command word once.
6. The parser tokenizes quotes, escapes, redirection operators, and `$VAR` or `${VAR}` expansion.
7. Builtins execute directly in-process.
8. Simple pipelines run through the native Zig pipeline path; complex shell syntax falls back to the platform shell.
9. Background jobs are tracked and reaped before later prompts.
10. stdout/stderr are emitted or redirected.

## Core State

```mermaid
classDiagram
    class Shell {
      allocator
      io
      env
      history
      history_meta
      aliases
      abbreviations
      completion_specs
      completion_candidates
      background_jobs
      manual_echo
      prompt_mode
      last_status
    }
    class ParsedCommand {
      argv
      stdout_redirect
      stderr_redirect
      extractRedirections()
      hasRedirection()
    }
    class CompletionSpec {
      command
      completer
    }
    class AliasSpec {
      name
      value
    }
    class AbbreviationSpec {
      name
      value
    }
    class CompletionCandidateSpec {
      command
      candidate
      description
    }
    class HistoryMeta {
      command
      cwd
      status
      duration_ms
      timestamp
    }
    class BackgroundJob {
      number
      child
      command
      done
    }
    Shell --> ParsedCommand
    Shell --> CompletionSpec
    Shell --> CompletionCandidateSpec
    Shell --> AliasSpec
    Shell --> AbbreviationSpec
    Shell --> HistoryMeta
    Shell --> BackgroundJob
```

## Why Some Work Is Delegated

Simple pipelines now have a native Zig path. Complex syntax still uses `/bin/sh -c` on POSIX and `cmd /C` on Windows. That keeps the project small while leaving room for a deeper streaming pipeline engine later.

## Design Rules

- Keep the default prompt and core output stable for CodeCrafters compatibility.
- Prefer small helper functions over hidden framework magic.
- Keep feature behavior readable before making it clever.
- Make every added UX feature teach a shell concept.
