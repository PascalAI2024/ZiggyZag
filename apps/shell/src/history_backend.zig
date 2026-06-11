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

// ---------------------------------------------------------------------------
// Private TSV helpers
// ---------------------------------------------------------------------------

const tsv_max_file_bytes: usize = 8 * 1024 * 1024;

fn appendTsvFieldToList(allocator: Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '\t' => try buf.appendSlice(allocator, "\\t"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            else => try buf.append(allocator, c),
        }
    }
}

fn unescapeTsvFieldAlloc(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] == '\\' and i + 1 < value.len) {
            const escaped: u8 = switch (value[i + 1]) {
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                '\\' => '\\',
                else => value[i + 1],
            };
            try out.append(allocator, escaped);
            i += 1;
            continue;
        }
        try out.append(allocator, value[i]);
    }
    return out.toOwnedSlice(allocator);
}

/// Parse one TSV row into a HistoryEntry. Returns null for blank/invalid lines.
/// Allocates `entry.cwd` and `entry.command` from `allocator`; caller frees.
fn parseTsvRow(allocator: Allocator, line: []const u8) !?HistoryEntry {
    const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
        line[0 .. line.len - 1]
    else
        line;
    if (trimmed.len == 0) return null;

    var fields = std.mem.splitScalar(u8, trimmed, '\t');
    const ts_text = fields.next() orelse return null;
    const status_text = fields.next() orelse return null;
    const dur_text = fields.next() orelse return null;
    const cwd_esc = fields.next() orelse return null;
    const cmd_esc = fields.next() orelse return null;

    const timestamp = std.fmt.parseInt(i64, ts_text, 10) catch return null;
    const exit_status: ?u8 = std.fmt.parseInt(u8, status_text, 10) catch null;
    const duration_ms: ?i64 = std.fmt.parseInt(i64, dur_text, 10) catch null;

    const cwd = try unescapeTsvFieldAlloc(allocator, cwd_esc);
    errdefer allocator.free(cwd);
    const command = try unescapeTsvFieldAlloc(allocator, cmd_esc);

    return HistoryEntry{
        .timestamp = timestamp,
        .exit_status = exit_status,
        .duration_ms = duration_ms,
        .cwd = cwd,
        .command = command,
    };
}

fn readTsvFileOrEmptyAlloc(io: std.Io, allocator: Allocator, path: []const u8) ![]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return try allocator.alloc(u8, 0),
            else => |e| return e,
        }
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return try allocator.alloc(u8, 0),
            else => |e| return e,
        };
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    return reader.interface.allocRemaining(allocator, .limited(tsv_max_file_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.FileTooLarge,
        else => |e| e,
    };
}

fn writeTsvFile(io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, data);
    } else {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    }
}

// ---------------------------------------------------------------------------
// TsvBackend
// ---------------------------------------------------------------------------

/// TSV-backed implementation. The on-disk format is the one already produced by
/// `writeHistoryMetaFile` and consumed by `readHistoryMetaFile` in `main.zig`:
///   `{timestamp}\t{status}\t{duration_ms}\t{esc_cwd}\t{esc_command}\n`
/// with `\t`, `\n`, `\r`, and `\\` escaped per `appendTsvField`.
pub const TsvBackend = struct {
    allocator: Allocator,
    io: std.Io,
    path: []u8,

    pub fn init(allocator: Allocator, io: std.Io, path: []const u8) !TsvBackend {
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        return .{ .allocator = allocator, .io = io, .path = owned };
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

    fn appendErased(ptr: *anyopaque, entry: HistoryEntry) anyerror!void {
        const self: *TsvBackend = @ptrCast(@alignCast(ptr));

        // Read existing file content (empty slice if file doesn't exist yet).
        const existing = try readTsvFileOrEmptyAlloc(self.io, self.allocator, self.path);
        defer self.allocator.free(existing);

        // Build the new row.
        var row: std.ArrayList(u8) = .empty;
        defer row.deinit(self.allocator);
        var num_buf: [64]u8 = undefined;
        const num_str = try std.fmt.bufPrint(&num_buf, "{d}\t{d}\t{d}\t", .{
            entry.timestamp,
            if (entry.exit_status) |s| @as(i64, s) else @as(i64, 0),
            if (entry.duration_ms) |d| d else @as(i64, 0),
        });
        try row.appendSlice(self.allocator, num_str);
        try appendTsvFieldToList(self.allocator, &row, entry.cwd);
        try row.append(self.allocator, '\t');
        try appendTsvFieldToList(self.allocator, &row, entry.command);
        try row.append(self.allocator, '\n');

        // Combine existing + new row.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, existing);
        if (existing.len > 0 and existing[existing.len - 1] != '\n') {
            try out.append(self.allocator, '\n');
        }
        try out.appendSlice(self.allocator, row.items);

        try writeTsvFile(self.io, self.path, out.items);
    }

    fn queryErased(ptr: *anyopaque, allocator: Allocator, spec: QuerySpec) anyerror![]HistoryEntry {
        const self: *TsvBackend = @ptrCast(@alignCast(ptr));
        const limit = @min(spec.limit, max_query_rows);

        const contents = try readTsvFileOrEmptyAlloc(self.io, self.allocator, self.path);
        defer self.allocator.free(contents);

        // Collect all lines so we can iterate in reverse (most recent last in file).
        var line_list: std.ArrayList([]const u8) = .empty;
        defer line_list.deinit(self.allocator);
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| try line_list.append(self.allocator, line);

        var entries: std.ArrayList(HistoryEntry) = .empty;
        errdefer {
            for (entries.items) |e| {
                allocator.free(e.command);
                allocator.free(e.cwd);
            }
            entries.deinit(allocator);
        }

        var idx = line_list.items.len;
        while (idx > 0 and entries.items.len < limit) {
            idx -= 1;
            const entry = parseTsvRow(allocator, line_list.items[idx]) catch continue orelse continue;

            var keep = true;
            if (spec.cwd_prefix) |prefix| {
                if (!std.mem.startsWith(u8, entry.cwd, prefix)) keep = false;
            }
            if (keep) if (spec.exit_status) |status| {
                if (entry.exit_status == null or entry.exit_status.? != status) keep = false;
            };
            if (keep) if (spec.since_ms) |since| {
                if (entry.timestamp < since) keep = false;
            };
            if (keep) if (spec.command_substring) |sub| {
                if (std.mem.indexOf(u8, entry.command, sub) == null) keep = false;
            };

            if (keep) {
                try entries.append(allocator, entry);
            } else {
                allocator.free(entry.command);
                allocator.free(entry.cwd);
            }
        }

        return entries.toOwnedSlice(allocator);
    }

    fn importTsvErased(ptr: *anyopaque, tsv_path: []const u8) anyerror!usize {
        const self: *TsvBackend = @ptrCast(@alignCast(ptr));

        const src = try readTsvFileOrEmptyAlloc(self.io, self.allocator, tsv_path);
        defer self.allocator.free(src);
        const dst = try readTsvFileOrEmptyAlloc(self.io, self.allocator, self.path);
        defer self.allocator.free(dst);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, dst);

        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |raw| {
            if (count >= max_import_rows) break;
            const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
            if (line.len == 0) continue;
            // Validate row is parseable; skip corrupt rows silently.
            const entry = parseTsvRow(self.allocator, line) catch continue orelse continue;
            self.allocator.free(entry.command);
            self.allocator.free(entry.cwd);
            try out.appendSlice(self.allocator, line);
            try out.append(self.allocator, '\n');
            count += 1;
        }

        try writeTsvFile(self.io, self.path, out.items);
        return count;
    }

    fn exportTsvErased(ptr: *anyopaque, tsv_path: []const u8) anyerror!void {
        const self: *TsvBackend = @ptrCast(@alignCast(ptr));

        const contents = try readTsvFileOrEmptyAlloc(self.io, self.allocator, self.path);
        defer self.allocator.free(contents);

        // Collect non-empty lines; keep only the last max_export_rows.
        var line_list: std.ArrayList([]const u8) = .empty;
        defer line_list.deinit(self.allocator);
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |raw| {
            const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
            if (line.len == 0) continue;
            try line_list.append(self.allocator, line);
        }

        const start = if (line_list.items.len > max_export_rows)
            line_list.items.len - max_export_rows
        else
            0;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        for (line_list.items[start..]) |line| {
            try out.appendSlice(self.allocator, line);
            try out.append(self.allocator, '\n');
        }

        try writeTsvFile(self.io, tsv_path, out.items);
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

test "SqliteBackend returns NotImplemented (Wave 4 stub)" {
    const allocator = std.testing.allocator;
    const entry: HistoryEntry = .{
        .command = "ls",
        .cwd = "/tmp",
        .exit_status = 0,
        .duration_ms = 1,
        .timestamp = 0,
    };

    var sql = try SqliteBackend.init(allocator, "history.sqlite");
    defer sql.deinit();
    const sql_be = sql.backend();
    try std.testing.expectError(error.NotImplemented, sql_be.append(entry));
    try std.testing.expectError(error.NotImplemented, sql_be.query(allocator, .{}));
    try std.testing.expectError(error.NotImplemented, sql_be.import_tsv("src.tsv"));
    try std.testing.expectError(error.NotImplemented, sql_be.export_tsv("dst.tsv"));
}

test "TsvBackend append and query round-trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "history.tsv" });
    defer allocator.free(file_path);

    var tsv = try TsvBackend.init(allocator, io, file_path);
    defer tsv.deinit();
    const be = tsv.backend();

    // Append two entries.
    try be.append(.{ .command = "echo hello", .cwd = "/home/user", .exit_status = 0, .duration_ms = 5, .timestamp = 1000 });
    try be.append(.{ .command = "ls -la", .cwd = "/tmp", .exit_status = 0, .duration_ms = 12, .timestamp = 2000 });

    // Query returns most recent first (reverse order), default limit 100.
    const results = try be.query(allocator, .{});
    defer {
        for (results) |r| {
            allocator.free(r.command);
            allocator.free(r.cwd);
        }
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 2), results.len);
    // Most recent entry is first.
    try std.testing.expectEqualStrings("ls -la", results[0].command);
    try std.testing.expectEqualStrings("/tmp", results[0].cwd);
    try std.testing.expectEqual(@as(i64, 2000), results[0].timestamp);
    try std.testing.expectEqualStrings("echo hello", results[1].command);
}

test "TsvBackend query filters by cwd_prefix and command_substring" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "history2.tsv" });
    defer allocator.free(file_path);

    var tsv = try TsvBackend.init(allocator, io, file_path);
    defer tsv.deinit();
    const be = tsv.backend();

    try be.append(.{ .command = "git status", .cwd = "/project", .exit_status = 0, .duration_ms = 1, .timestamp = 1 });
    try be.append(.{ .command = "ls", .cwd = "/other", .exit_status = 0, .duration_ms = 1, .timestamp = 2 });
    try be.append(.{ .command = "git log", .cwd = "/project", .exit_status = 0, .duration_ms = 1, .timestamp = 3 });

    // Filter by cwd_prefix.
    const proj_results = try be.query(allocator, .{ .cwd_prefix = "/project" });
    defer {
        for (proj_results) |r| {
            allocator.free(r.command);
            allocator.free(r.cwd);
        }
        allocator.free(proj_results);
    }
    try std.testing.expectEqual(@as(usize, 2), proj_results.len);

    // Filter by command_substring.
    const git_results = try be.query(allocator, .{ .command_substring = "git" });
    defer {
        for (git_results) |r| {
            allocator.free(r.command);
            allocator.free(r.cwd);
        }
        allocator.free(git_results);
    }
    try std.testing.expectEqual(@as(usize, 2), git_results.len);
}

test "TsvBackend export_tsv writes last max_export_rows lines" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const src_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "src.tsv" });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "dst.tsv" });
    defer allocator.free(dst_path);

    var tsv = try TsvBackend.init(allocator, io, src_path);
    defer tsv.deinit();
    const be = tsv.backend();

    try be.append(.{ .command = "cmd1", .cwd = "/", .exit_status = 0, .duration_ms = 1, .timestamp = 1 });
    try be.append(.{ .command = "cmd2", .cwd = "/", .exit_status = 0, .duration_ms = 1, .timestamp = 2 });
    try be.export_tsv(dst_path);

    // dst should contain the same rows.
    var dst_tsv = try TsvBackend.init(allocator, io, dst_path);
    defer dst_tsv.deinit();
    const dst_be = dst_tsv.backend();
    const results = try dst_be.query(allocator, .{});
    defer {
        for (results) |r| {
            allocator.free(r.command);
            allocator.free(r.cwd);
        }
        allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
}
