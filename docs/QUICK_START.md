# Quick Start

Build, run, and get comfortable with the ZiggyZag shell in a few minutes.

```sh
git clone https://github.com/PascalAI2024/ZiggyZag
cd ZiggyZag
zig build
./zig-out/bin/ziggyzag
```

That drops you into the shell. Type `help` for the builtin reference, `doctor`
for a health check, and `about` for version info.

## Command history (persists by default)

ZiggyZag remembers what you ran across restarts with **no configuration**.
Every command's metadata — the command line, working directory, exit status,
and how long it took — is appended to a durable file the moment it finishes, so
a crash or `kill -9` loses at most the command in flight.

- **Where it lives.** By default, `~/.ziggyzag_history.tsv` (resolved from
  `$HOME`, or `%USERPROFILE%` on Windows). Run `doctor` and read the
  `metadata` line to see the effective path on your machine.
- **Change the location.** Set `ZIGGYZAG_HISTORY_DB` to any path:

  ```sh
  export ZIGGYZAG_HISTORY_DB=~/.config/ziggyzag/history.tsv
  ```

  Set it to the empty string to disable durable history entirely.
- **See it.** `history` lists prior-session commands; `history --stats`,
  `history --slow [ms]`, `history --failed`, and `history --cwd [DIR]` slice the
  metadata. Up-arrow recall and inline autosuggestions draw from the same store.

### Import and export

The on-disk format is tab-separated and stable, so you can move history between
machines or seed it from another tool.

```sh
history export ~/backup.tsv          # write current history to a file
history export --meta ~/full.tsv     # include full per-command metadata
history import ~/from-laptop.tsv      # merge rows into your history (deduped)
```

`history import` appends the rows from the named file into your durable history
and reloads the in-memory view, so the imported commands are searchable
immediately — no restart needed.

### Privacy

- Commands that look like they carry a credential — anything with
  `--password`, `--token`, `--api-key`, `--secret`, `Authorization:`, an
  `AWS_SECRET_ACCESS_KEY=` assignment, and similar patterns — are **never
  written to disk**. They stay in this session's in-memory history (so recall
  and editing still work) and vanish when the shell exits.
- Turn off history for a whole session with `ZIGGYZAG_HISTORY_PRIVATE=1`, or at
  runtime with `history disable` (add `--clear` to wipe what's already loaded).

## Themes

ZiggyZag ships 20 themes shared between the prompt and the terminal palette.

```sh
theme list          # show every theme, * marks the active one
theme ziggy         # switch theme
```

Set `ZIGGYZAG_THEME` to pick a theme at startup. See
[`docs/reference/theme-protocol.md`](reference/theme-protocol.md) for how the
desktop host and shell stay in sync.

## Where to go next

- [`docs/reference/config.md`](reference/config.md) — the `~/.ziggyzagrc` format
  and every configurable knob.
- [`docs/reference/features.md`](reference/features.md) — the full builtin and
  feature list.
- [`docs/reference/history-backend.md`](reference/history-backend.md) — the
  history storage format and the SQLite migration plan.
