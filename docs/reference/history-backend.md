# Durable History Backend

How ZiggyZag's shell history moves from an append-only TSV file to a SQLite database with an Atuin-shaped schema. This is a Wave 4 deliverable per [`waves.md`](../vision/waves.md). The current implementation in `apps/shell/src/main.zig` writes the path named by `ZIGGYZAG_HISTORY_DB` as tab-separated values through `appendTsvField` (line 4883) and reads it back through `unescapeTsvFieldAlloc` (line 4898). That format scales to maybe ten thousand commands before linear scans on `history --query` start showing up in the prompt latency budget. SQLite handles a few million rows on consumer hardware without any work from us.

The shape is borrowed from Atuin [1] minus the cloud-sync component. Atuin runs a hosted sync server and signs records with a per-user key derived from a passphrase; ZiggyZag does not. That deletes a category of complexity (key rotation, conflict resolution, encrypted blobs over HTTPS) and a category of risk (a remote endpoint that could leak commands).

## 1. Schema

```sql
CREATE TABLE history (
    id          INTEGER PRIMARY KEY,
    timestamp   INTEGER NOT NULL,           -- unix nanoseconds, monotonic per session
    duration_ms INTEGER,                    -- wall-clock command duration; null while running
    exit_status INTEGER,                    -- POSIX exit code; null while running
    command     TEXT NOT NULL,              -- the literal command line as typed
    cwd         TEXT,                       -- canonicalised cwd at submit time
    hostname    TEXT,                       -- result of GetComputerNameW / gethostname
    session     TEXT                        -- per-shell-process UUID (existing field)
);

CREATE INDEX idx_history_timestamp   ON history(timestamp);
CREATE INDEX idx_history_cwd         ON history(cwd);
CREATE INDEX idx_history_exit_status ON history(exit_status) WHERE exit_status IS NOT NULL;
```

`id` is monotonic so `LIMIT N ORDER BY id DESC` always returns the most recent inserts without a sort step. `timestamp` is also indexed because the most common query — "what did I run today" — uses a time window without anchoring at the tail of the table. `cwd` is indexed because directory-scoped recall (`history --cwd-prefix`) is the second-most-frequent query in everyday use. `exit_status` is indexed with a `WHERE NOT NULL` partial-index clause so a "show me my failures" scan never touches in-flight rows.

`duration_ms` is nullable so the row can be inserted at command start and updated at command end; this lets a long-running build still appear in history if the shell is killed before exit. `hostname` and `session` round out the Atuin column set and let us reconstruct what happened on which machine if the SQLite file is ever copied between hosts (a manual `cp`, not a sync). `command` carries the raw bytes, not a sanitised form — privacy controls (section 5) gate writes, not reads.

## 2. Migration from TSV

On startup, the shell checks the file named by `ZIGGYZAG_HISTORY_DB`:

1. If the path ends in `.tsv` and the corresponding `.sqlite` does not exist, the TSV is treated as an import source. A new `.sqlite` is created next to it, every row is parsed by the existing `unescapeTsvFieldAlloc`, and inserted within a single transaction. Failure aborts the transaction and the shell falls back to TSV mode for this session.
2. If the path ends in `.sqlite`, that is the canonical store and no migration happens.
3. If the path ends in neither, the shell appends `.sqlite` and runs the create branch.

Import is **idempotent**: each TSV row hashes `(timestamp, command, cwd)` into a `UNIQUE` constraint check before insertion, so running the migration twice does not double-write. The TSV is not deleted; the user may rename or remove it themselves.

`HISTFILE`, when set, becomes an export target on shutdown. We dump the last 10 000 rows back to TSV before exit so anyone who reads `HISTFILE` from a script still sees fresh data. This is best-effort and not on the prompt path.

If the SQLite open fails (locked, read-only filesystem, mismatched user libsqlite ABI), the shell **writes through to TSV** as it does today and surfaces a single line on stderr under `--verbose`. The shell never blocks on an unavailable database.

## 3. Embedding

We vendor the SQLite **amalgamation** under `vendor/sqlite/` — one `sqlite3.c` and one `sqlite3.h`, no submodule, no fetched build. Build wires it into the existing `build.zig` as a static C object linked into the shell. Cost: roughly one megabyte of object code, zero new external dependencies.

```zig
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub fn open(path: [:0]const u8) !*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null) != c.SQLITE_OK) {
        return error.SqliteOpenFailed;
    }
    return db.?;
}
```

We considered pure-Zig alternatives (a port of `bdb`, the half-finished `zsqlite`, hand-rolling a write-ahead log). None passes the conformance bar SQLite sets — the JSON1 extension alone is non-trivial — and the amalgamation is a single C file that has been audited continuously since 2000. The cost of dragging in a C compiler we already need (ConPTY on Windows, the desktop's GDI bindings) is zero. Picking sqlite is the boring choice and the right one.

## 4. Query API

`history` keeps its current behaviour (no args → recent N) and grows five new flags:

```sh
history --where 'exit_status != 0'                 # SQL fragment, validated AST
history --since '1 week ago'                       # human time, parsed by existing chrono code
history --cwd-prefix /home/me/dev                  # exact LIKE prefix match
history --json                                     # one record per line, jq-friendly
history --query "build" --since '1d' --cwd-prefix .  # composable
```

`--where` accepts a single boolean expression in a restricted grammar: column names from the schema, integer and string literals, the operators `= != < <= > >= AND OR NOT LIKE`. The string is parsed in-process and rejected if any token escapes that vocabulary; the SQL we hand to sqlite is built from the parsed AST, not the raw input. Bobby Tables stays in his desk.

`--since` reuses the shell's existing relative-time parser (already used by `task --due`). `--cwd-prefix` rewrites to `cwd LIKE ?||'%'` with a parameter-bound prefix; no manual quoting.

JSON output uses `std.json.stringify` over a small `HistoryRecord` struct so output is round-trippable.

## 5. Privacy controls

Three controls compose:

- **`history disable`** (already exists) flips a process-local flag that suppresses writes. The DB connection stays open, but `insertCommand` early-returns. State does not persist between sessions; this is for the next minutes, not forever.
- **`history private` mode** (existing) is the persistent form: a `[history] private = true` line in `shell.conf` makes the disable flag default-on for every new session. The user has to explicitly `history enable` to resume writes.
- **Path traversal on `ZIGGYZAG_HISTORY_DB`.** The env var is treated as a user-chosen path, but the shell `realpath`s it and rejects parent traversals that escape the user's home directory unless the path also begins with `%TEMP%`, `/tmp`, or an explicit `--allow-anywhere` flag. The threat model is "another process drops a symlink into a writable directory and steals my command history"; the mitigation is to canonicalise before open and refuse paths owned by another user (POSIX `stat().st_uid`, Windows `GetSecurityInfo`).

A redacted form of the command (`****`) is **not** stored when private mode is on. The row is simply not written. A side channel through `duration_ms` would still leak that something ran; we accept that.

## 6. Performance budget

Target: **50 ms from `zig-out/bin/ziggyzag` exec to first prompt paint**, on a cold cache, with a history database of 100 000 rows.

Budget split:

- 10 ms — process spawn, glibc/UCRT load, Zig runtime init.
- 5 ms  — sqlite open (`sqlite3_open_v2` on an existing file is a few syscalls).
- 5 ms  — first prefetch query: `SELECT command FROM history ORDER BY id DESC LIMIT 100` for the autosuggest buffer.
- 10 ms — env scan, prompt render, ANSI sequence emit.
- 20 ms — slack.

The autosuggest path **must not** issue a query per keystroke; the prefetch above is the warm cache and only spills back to sqlite on history-search (`Ctrl+R`) or explicit `history` invocation. Reads happen on a worker thread when the prompt is being typed, never on the input-handling path.

Test plan:

1. `scripts/bench-history.ps1` — generates 100 000 synthetic rows, measures `time ./zig-out/bin/ziggyzag -c 'exit'` over 30 runs, reports p50/p95/p99.
2. CI gate at `p95 < 50ms` on the GitHub Actions Windows runner.
3. A soak test: insert one row per second for 24 hours, then measure first-prompt latency. Targets the WAL-checkpoint footprint.

## What this doc does not specify

- **Cloud sync.** No server, no key derivation, no encrypted blobs. Atuin's sync model is real engineering and we are not doing it.
- **Multi-machine merge.** If the user copies their `.sqlite` between two machines, we make no claims about consistency. Last write wins by `id`.
- **Sync conflict resolution.** Same reason — there is no sync.
- **Full-text indexing.** FTS5 is on the table but is a separate proposal; the current `--query` is `LIKE '%foo%'` and that is acceptable up to a few hundred thousand rows.
- **Encryption at rest.** The SQLite file inherits filesystem permissions and nothing more. SQLCipher would be a future opt-in.

## Sources

[1] Ellie Huxtable, "Atuin — Magical shell history." Repository at https://github.com/atuin-sh/atuin. Schema lives in `crates/atuin-client/migrations/20210422194131_create.sql` and subsequent migrations.
[2] SQLite Consortium, "The Amalgamation." https://www.sqlite.org/amalgamation.html. Two-file build, public domain, audited.
