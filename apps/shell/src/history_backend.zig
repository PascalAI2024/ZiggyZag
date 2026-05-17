//! Durable history backend scaffold (Wave 4).
//!
//! Spec: `docs/reference/history-backend.md`. This module defines the API surface
//! the shell will eventually use to move command history off the append-only TSV
//! file (`appendTsvField` / `unescapeTsvFieldAlloc` in `main.zig`) onto a SQLite
//! store with an Atuin-shaped schema (no cloud sync component).
//!
//! THIS FILE IS NOT YET WIRED INTO THE SHELL. The existing TSV path in
//! `main.zig` (around the `HistoryMeta` struct, `readHistoryMetaFile`, and
//! `writeHistoryMetaFile`) is the only live history code. Importing this module
//! does not change the shell's runtime behaviour. Wave 4 will:
//!   1. Vendor `sqlite3.{c,h}` under `vendor/sqlite/`.
//!   2. Replace every `error.NotImplemented` return in `SqliteBackend` with the
//!      real implementation.
//!   3. Choose a backend at startup based on the extension of the path named by
//!      `ZIGGYZAG_HISTORY_DB` (`.sqlite` → SQLite, `.tsv` or unset → TSV).
//!   4. Migrate existing TSV files via `SqliteBackend.import_tsv` on first run.
//!
//! Until then the file exists to (a) lock the schema in code so the migration
//! plan and the shell's call sites agree, and (b) give callers a stable
//! `HistoryBackend` vtable they can be written against.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

/// Cap on rows returned from a single `query` call. Mirrors the Atuin client
/// default and keeps a runaway `--limit` from pinning the prompt thread.
pub const max_query_rows: usize = 10_000;

/// Cap on rows imported from a TSV in a single `import_tsv` transaction. Larger
/// imports must be chunked by the caller; one transaction per chunk keeps the
/// WAL bounded.
pub const max_import_rows: usize = 1_000_000;

/// Cap on the on-disk export window. Matches the "last 10 000 rows" rule in
/// section 2 of the spec — anyone reading `HISTFILE` from a shell script sees a
/// recent slice, not the entire history.
pub const max_export_rows: usize = 10_000;

/// Default `QuerySpec.limit`. Picked to match the autosuggest prefetch buffer
/// in section 6 of the spec.
pub const default_query_limit: usize = 100;

/// Atuin-shaped DDL, lifted from section 1 of the spec. Future SQLite backend
/// hands this string straight to `sqlite3_exec`. The three indices match the
/// three queries the spec identifies as hot: tail recall, directory-scoped
/// recall, and failure filtering.
pub const schema_sql: []const u8 =
    \\CREATE TABLE IF NOT EXISTS history (
    \\    id          INTEGER PRIMARY KEY,
    \\    timestamp   INTEGER NOT NULL,
    \\    duration_ms INTEGER,
    \\    exit_status INTEGER,
    \\    command     TEXT NOT NULL,
    \\    cwd         TEXT,
    \\    hostname    TEXT,
    \\    session     TEXT
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_history_timestamp
    \\    ON history(timestamp DESC);
    \\CREATE INDEX IF NOT EXISTS idx_history_cwd
    \\    ON history(cwd);
    \\CREATE INDEX IF NOT EXISTS idx_history_exit_status
    \\    ON history(exit_status)
    \\    WHERE exit_status IS NOT NULL;
;

/// A single history record. Mirrors the on-disk row in `schema_sql` and the
/// in-memory `HistoryMeta` struct in `main.zig`, with the two Wave 4 additions
/// (hostname, session) appended. All slice fields are borrowed: callers own the
/// memory and must keep it alive across the backend call.
pub const HistoryEntry = struct {
    /// Literal command line as typed. Never sanitised — privacy gates writes,
    /// not reads (section 5 of the spec).
    command: []const u8,
    /// Canonicalised cwd at submit time. Empty when unknown.
    cwd: []const u8,
    /// POSIX exit code. `null` while the command is in flight; the row may be
    /// inserted at start and updated at finish so long-running builds survive
    /// shell kill.
    exit_status: ?u8,
    /// Wall-clock duration. `null` matches the same in-flight case as
    /// `exit_status`.
    duration_ms: ?i64,
    /// Unix nanoseconds; monotonic per session per the spec.
    timestamp: i64,
    /// Result of `GetComputerNameW` (Windows) or `gethostname` (POSIX). Defaults
    /// to the empty string when the lookup fails — the column is nullable in
    /// SQL but we keep the Zig type non-optional to match `HistoryMeta`'s
    /// conventions and represent absence as `""`.
    hostname: []const u8 = "",
    /// Per-shell-process UUID. TODO(wave4): replace the placeholder
    /// zero-filled UUID emitted at session start with a real v7 UUID once the
    /// shell grows a generator (see the parallel sessions abstraction work).
    session: []const u8 = "",
};

/// Restricted-grammar query inputs. Matches the `history --where`, `--since`,
/// `--cwd-prefix`, and `--query` flag set described in section 4 of the spec.
/// The fields here are the parsed AST, not the raw flag strings — that parse
/// happens before the backend is called so no untrusted input ever reaches
/// the SQL builder.
pub const QuerySpec = struct {
    /// Filter on `cwd LIKE ?||'%'`. `null` means no cwd filter.
    cwd_prefix: ?[]const u8 = null,
    /// Exact exit-status match. `null` means no status filter; pass `0` to ask
    /// for successful commands only.
    exit_status: ?u8 = null,
    /// Lower bound on `timestamp`, in unix milliseconds. `null` means no time
    /// floor (caller will normally pair this with `limit`).
    since_ms: ?i64 = null,
    /// Substring match on `command`. Lowered to `command LIKE '%'||?||'%'`.
    command_substring: ?[]const u8 = null,
    /// Hard row cap. Capped at `max_query_rows` regardless of caller intent.
    limit: usize = default_query_limit,
};

/// vtable-style backend interface so the shell can swap between TSV and SQLite
/// at startup without conditionals threaded through every history call site.
/// The function-pointer layout matches the pattern used by `std.Random` and
/// `std.mem.Allocator` in the standard library.
pub const HistoryBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        append: *const fn (ptr: *anyopaque, entry: HistoryEntry) anyerror!void,
        query: *const fn (
            ptr: *anyopaque,
            allocator: Allocator,
            spec: QuerySpec,
        ) anyerror![]HistoryEntry,
        import_tsv: *const fn (ptr: *anyopaque, tsv_path: []const u8) anyerror!usize,
        export_tsv: *const fn (ptr: *anyopaque, tsv_path: []const u8) anyerror!void,
    };

    pub fn deinit(self: HistoryBackend) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn append(self: HistoryBackend, entry: HistoryEntry) !void {
        return self.vtable.append(self.ptr, entry);
    }

    /// Returns an owned slice; caller frees each entry's borrowed slices and
    /// the outer slice itself using `allocator`.
    pub fn query(self: HistoryBackend, allocator: Allocator, spec: QuerySpec) ![]HistoryEntry {
        return self.vtable.query(self.ptr, allocator, spec);
    }

    /// Returns the number of rows actually inserted (deduped by the
    /// `(timestamp, command, cwd)` uniqueness check described in spec section
    /// 2). Idempotent — running twice with the same TSV yields zero new rows.
    pub fn import_tsv(self: HistoryBackend, tsv_path: []const u8) !usize {
        return self.vtable.import_tsv(self.ptr, tsv_path);
    }

    pub fn export_tsv(self: HistoryBackend, tsv_path: []const u8) !void {
        return self.vtable.export_tsv(self.ptr, tsv_path);
    }
};

/// TSV-backed implementation. The on-disk format is the one already produced by
/// `writeHistoryMetaFile` and consumed by `readHistoryMetaFile` in `main.zig`:
///   `{timestamp}\t{status}\t{duration_ms}\t{esc_cwd}\t{esc_command}\n`
/// with `\t`, `\n`, `\r`, and `\\` escaped per `appendTsvField`. Wave 4 will
/// implement these methods by calling those existing helpers; for now every
/// entry point returns `error.NotImplemented` so the vtable wiring can be
/// exercised by tests without touching the live history path.
pub const TsvBackend = struct {
    allocator: Allocator,
    path: []u8,

    pub fn init(allocator: Allocator, path: []const u8) !TsvBackend {
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        return .{ .allocator = allocator, .path = owned };
    }

    pub fn deinit(self: *TsvBackend) void {
        self.allocator.free(self.path);
    }

    pub fn backend(self: *TsvBackend) HistoryBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: HistoryBackend.VTable = .{
        .deinit = deinitErased,
        .append = appendErased,
        .query = queryErased,
        .import_tsv = importTsvErased,
        .export_tsv = exportTsvErased,
    };

    fn deinitErased(ptr: *anyopaque) void {
        const self: *TsvBackend = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    /// Production form: open `self.path` with `O_APPEND`, format the row with
    /// the same `appendFmt` + `appendTsvField` sequence used by
    /// `writeHistoryMetaFile` (main.zig line 2669), write it, fsync the file
    /// if `self.fsync_on_append` is on (a future config knob).
    fn appendErased(ptr: *anyopaque, entry: HistoryEntry) anyerror!void {
        _ = ptr;
        _ = entry;
        return error.NotImplemented;
    }

    /// Production form: stream the file through `unescapeTsvFieldAlloc` (main.zig
    /// line 4898), apply the `QuerySpec` filters in Zig (no indices to lean on),
    /// stop at `spec.limit`. O(n) over the whole TSV — acceptable up to ~10k
    /// rows per the budget in spec section 6.
    fn queryErased(ptr: *anyopaque, allocator: Allocator, spec: QuerySpec) anyerror![]HistoryEntry {
        _ = ptr;
        _ = allocator;
        _ = spec;
        return error.NotImplemented;
    }

    /// Production form: a TSV-to-TSV import is a `std.fs.copyFileAbsolute` from
    /// the source into `self.path`. Reports `error.AlreadyExists` if the target
    /// is non-empty (no merge story between two TSVs — that's a SQLite-only
    /// feature).
    fn importTsvErased(ptr: *anyopaque, tsv_path: []const u8) anyerror!usize {
        _ = ptr;
        _ = tsv_path;
        return error.NotImplemented;
    }

    /// Production form: a TSV-to-TSV export is a `std.fs.copyFileAbsolute` from
    /// `self.path` to `tsv_path`. No row cap is applied — the cap in spec
    /// section 2 is a SQLite-only concession to keep the export window small.
    fn exportTsvErased(ptr: *anyopaque, tsv_path: []const u8) anyerror!void {
        _ = ptr;
        _ = tsv_path;
        return error.NotImplemented;
    }
};

/// SQLite-backed implementation. The real version (Wave 4) will hold a
/// `*c.sqlite3` handle plus prepared statements for the four hot paths and
/// run `schema_sql` once at open time. For now every method returns
/// `error.NotImplemented`. Comments describe the SQL each method will run so
/// the migration to live code is just filling in the bodies.
pub const SqliteBackend = struct {
    allocator: Allocator,
    path: []u8,
    /// Will hold `?*c.sqlite3` once the amalgamation is vendored. Kept as an
    /// opaque pointer here so this file compiles without the C dependency.
    handle: ?*anyopaque,

    pub fn init(allocator: Allocator, path: []const u8) !SqliteBackend {
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        // Production form:
        //   const cpath = try allocator.dupeZ(u8, path);
        //   defer allocator.free(cpath);
        //   var db: ?*c.sqlite3 = null;
        //   if (c.sqlite3_open_v2(cpath.ptr, &db,
        //       c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null) != c.SQLITE_OK)
        //       return error.SqliteOpenFailed;
        //   errdefer _ = c.sqlite3_close(db);
        //   if (c.sqlite3_exec(db, schema_sql.ptr, null, null, null) != c.SQLITE_OK)
        //       return error.SqliteSchemaFailed;
        return .{ .allocator = allocator, .path = owned, .handle = null };
    }

    pub fn deinit(self: *SqliteBackend) void {
        // Production form: `_ = c.sqlite3_close_v2(self.handle.?);`
        self.allocator.free(self.path);
    }

    pub fn backend(self: *SqliteBackend) HistoryBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: HistoryBackend.VTable = .{
        .deinit = deinitErased,
        .append = appendErased,
        .query = queryErased,
        .import_tsv = importTsvErased,
        .export_tsv = exportTsvErased,
    };

    fn deinitErased(ptr: *anyopaque) void {
        const self: *SqliteBackend = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    /// SQL:
    ///   INSERT INTO history
    ///     (timestamp, duration_ms, exit_status, command, cwd, hostname, session)
    ///   VALUES (?,?,?,?,?,?,?)
    /// Bound as positional parameters; `id` is auto-assigned by SQLite. Uses
    /// the prepared statement cached on `self` so the hot path is one
    /// `sqlite3_bind_*` per field plus `sqlite3_step`.
    fn appendErased(ptr: *anyopaque, entry: HistoryEntry) anyerror!void {
        _ = ptr;
        _ = entry;
        return error.NotImplemented;
    }

    /// SQL is built from the parsed `QuerySpec` AST:
    ///   SELECT id, timestamp, duration_ms, exit_status, command, cwd, hostname, session
    ///   FROM history
    ///   WHERE 1=1
    ///     [AND cwd LIKE ?||'%']     -- when spec.cwd_prefix != null
    ///     [AND exit_status = ?]     -- when spec.exit_status != null
    ///     [AND timestamp >= ?]      -- when spec.since_ms != null (× 1_000_000 for ns)
    ///     [AND command LIKE '%'||?||'%'] -- when spec.command_substring != null
    ///   ORDER BY id DESC
    ///   LIMIT ?
    /// All values are parameter-bound. The string is assembled from a fixed
    /// vocabulary, never from user input directly (spec section 4).
    fn queryErased(ptr: *anyopaque, allocator: Allocator, spec: QuerySpec) anyerror![]HistoryEntry {
        _ = ptr;
        _ = allocator;
        _ = spec;
        return error.NotImplemented;
    }

    /// SQL: one transaction wrapping a parametrised INSERT for each TSV row.
    /// Idempotency is enforced by:
    ///   CREATE UNIQUE INDEX IF NOT EXISTS uniq_history_dedup
    ///     ON history(timestamp, command, cwd);
    /// followed by `INSERT OR IGNORE`. Returns the post-insert row count delta
    /// via `changes()`.
    fn importTsvErased(ptr: *anyopaque, tsv_path: []const u8) anyerror!usize {
        _ = ptr;
        _ = tsv_path;
        return error.NotImplemented;
    }

    /// SQL:
    ///   SELECT timestamp, exit_status, duration_ms, cwd, command
    ///   FROM history
    ///   ORDER BY id DESC
    ///   LIMIT max_export_rows;
    /// Each row formatted by the same `appendTsvField` helpers `main.zig`
    /// already uses for `writeHistoryMetaFile`, then atomically renamed into
    /// place so a partial write never replaces a complete `HISTFILE`.
    fn exportTsvErased(ptr: *anyopaque, tsv_path: []const u8) anyerror!void {
        _ = ptr;
        _ = tsv_path;
        return error.NotImplemented;
    }
};

test "schema_sql parses as well-formed DDL" {
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "CREATE TABLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "history") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "INTEGER PRIMARY KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "timestamp") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "duration_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "exit_status") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "command") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "cwd") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "hostname") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "session") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "CREATE INDEX") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "idx_history_timestamp") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "idx_history_cwd") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "idx_history_exit_status") != null);
}

test "HistoryEntry has all 7 expected fields" {
    const fields = @typeInfo(HistoryEntry).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 7), fields.len);

    var seen_command = false;
    var seen_cwd = false;
    var seen_exit_status = false;
    var seen_duration_ms = false;
    var seen_timestamp = false;
    var seen_hostname = false;
    var seen_session = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "command")) seen_command = true;
        if (std.mem.eql(u8, f.name, "cwd")) seen_cwd = true;
        if (std.mem.eql(u8, f.name, "exit_status")) seen_exit_status = true;
        if (std.mem.eql(u8, f.name, "duration_ms")) seen_duration_ms = true;
        if (std.mem.eql(u8, f.name, "timestamp")) seen_timestamp = true;
        if (std.mem.eql(u8, f.name, "hostname")) seen_hostname = true;
        if (std.mem.eql(u8, f.name, "session")) seen_session = true;
    }
    try std.testing.expect(seen_command);
    try std.testing.expect(seen_cwd);
    try std.testing.expect(seen_exit_status);
    try std.testing.expect(seen_duration_ms);
    try std.testing.expect(seen_timestamp);
    try std.testing.expect(seen_hostname);
    try std.testing.expect(seen_session);
}

test "QuerySpec defaults are sensible" {
    const spec: QuerySpec = .{};
    try std.testing.expectEqual(@as(usize, 100), spec.limit);
    try std.testing.expectEqual(default_query_limit, spec.limit);
    try std.testing.expect(spec.cwd_prefix == null);
    try std.testing.expect(spec.exit_status == null);
    try std.testing.expect(spec.since_ms == null);
    try std.testing.expect(spec.command_substring == null);
}

test "TsvBackend and SqliteBackend currently return NotImplemented" {
    const allocator = std.testing.allocator;

    var tsv = try TsvBackend.init(allocator, "history.tsv");
    defer tsv.deinit();
    const tsv_be = tsv.backend();
    const entry: HistoryEntry = .{
        .command = "ls",
        .cwd = "/tmp",
        .exit_status = 0,
        .duration_ms = 1,
        .timestamp = 0,
    };
    try std.testing.expectError(error.NotImplemented, tsv_be.append(entry));
    try std.testing.expectError(error.NotImplemented, tsv_be.query(allocator, .{}));
    try std.testing.expectError(error.NotImplemented, tsv_be.import_tsv("src.tsv"));
    try std.testing.expectError(error.NotImplemented, tsv_be.export_tsv("dst.tsv"));

    var sql = try SqliteBackend.init(allocator, "history.sqlite");
    defer sql.deinit();
    const sql_be = sql.backend();
    try std.testing.expectError(error.NotImplemented, sql_be.append(entry));
    try std.testing.expectError(error.NotImplemented, sql_be.query(allocator, .{}));
    try std.testing.expectError(error.NotImplemented, sql_be.import_tsv("src.tsv"));
    try std.testing.expectError(error.NotImplemented, sql_be.export_tsv("dst.tsv"));
}
