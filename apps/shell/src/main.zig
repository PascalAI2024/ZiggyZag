const builtin = @import("builtin");
const std = @import("std");
const theme = @import("theme");
const history_backend = @import("history_backend.zig");

const Allocator = std.mem.Allocator;

const max_config_file_bytes = 256 * 1024;
const max_source_file_bytes = 512 * 1024;
const max_history_file_bytes = 8 * 1024 * 1024;
const max_pipeline_capture_bytes = 8 * 1024 * 1024;
const max_pipeline_stage_input_bytes = 64 * 1024;
const max_prompt_git_output_bytes = 256 * 1024;
/// Maximum number of candidates a programmable completer may contribute per
/// invocation.  Protects against runaway or malicious completers flooding the
/// completion list and terminal display.
const max_completer_output_lines = 256;
const default_prompt_cache_ms = 1000;
const default_prompt_git_timeout_ms = 150;
/// Maximum bytes of OSC parameter payload accepted by `handleOscSequence`.
/// The desktop's Theme Protocol v2 emit fits in well under 64 bytes; anything
/// larger is treated as adversarial and dropped (the parser drains to ST/BEL
/// before resuming normal input).
const max_osc_param_bytes = 256;

const CompletionEntry = struct {
    text: []u8,
    is_directory: bool,
};

/// Syntax-highlight classification for a single byte of the command line.
/// `writeHighlightedLine` maps each kind to an ANSI color; the pure classifier
/// `classifyHighlight` produces these so the coloring logic is testable without
/// a terminal.
const HighlightKind = enum {
    /// The command head, resolved to a builtin.
    command_builtin,
    /// The command head, resolved to an executable on PATH.
    command_valid,
    /// The command head, not found as a builtin or on PATH.
    command_invalid,
    /// A byte inside a single- or double-quoted string (quotes included).
    string,
    /// A shell operator: `|`, `<`, `>`, `&`, `;`.
    operator,
    /// A `$` variable sigil outside quotes.
    variable,
    /// Anything else (arguments, whitespace).
    plain,
};

const CommandHeadKind = enum { builtin, valid, invalid };

const CompletionSpec = struct {
    command: []u8,
    completer: []u8,
};

const CompletionCandidateSpec = struct {
    command: []u8,
    candidate: []u8,
    description: []u8,
    /// For subcommand trees: a space-separated list of argument indices that
    /// should have completion candidates from THIS command. E.g. "0" means
    /// the first argument (the subcommand) has completions. "1" means second
    /// argument. Empty or "0" = complete first arg after the command itself.
    /// Format: "0" or "0 1" (multiple positional slots).
    options: []u8,
};

const AliasSpec = struct {
    name: []u8,
    value: []u8,
};

const AbbreviationSpec = struct {
    name: []u8,
    value: []u8,
};

const BackgroundJob = struct {
    number: usize,
    child: std.process.Child,
    command: []u8,
    done: bool = false,
};

const HistoryMeta = struct {
    command: []u8,
    cwd: []u8,
    status: u8,
    duration_ms: i64,
    timestamp: i64,
};

const ProjectKind = enum {
    zig,
    node,
    rust,
    python,
    go,
    make,
    git,
};

const ProjectInfo = struct {
    root: []u8,
    kind: ProjectKind,

    fn deinit(self: ProjectInfo, allocator: Allocator) void {
        allocator.free(self.root);
    }
};

const PromptMode = enum {
    classic,
    smart,
    compact,
    dev,
    dashboard,
};

const prompt_modes = [_]PromptMode{ .classic, .smart, .compact, .dev, .dashboard };

const GitPromptStatus = struct {
    present: bool = false,
    branch: [96]u8 = undefined,
    branch_len: usize = 0,
    staged: usize = 0,
    changed: usize = 0,
    untracked: usize = 0,
    conflicts: usize = 0,
    ahead: usize = 0,
    behind: usize = 0,

    fn branchSlice(self: *const GitPromptStatus) []const u8 {
        return self.branch[0..self.branch_len];
    }

    fn hasChanges(self: *const GitPromptStatus) bool {
        return self.staged > 0 or self.changed > 0 or self.untracked > 0 or self.conflicts > 0;
    }
};

const PromptSnapshot = struct {
    cwd: [512]u8 = undefined,
    cwd_len: usize = 0,
    project_kind: ?ProjectKind = null,
    git: GitPromptStatus = .{},
    generated_at_ms: i64 = 0,

    fn cwdSlice(self: *const PromptSnapshot) []const u8 {
        return self.cwd[0..self.cwd_len];
    }
};

const PipelineStageResult = struct {
    stdout: []u8,
    stderr: []u8,
    status: u8,

    fn deinit(self: PipelineStageResult, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

const PipelineInputFile = struct {
    path: []u8,
    file: std.Io.File,
};

const Shell = struct {
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    history: std.ArrayList([]u8),
    history_meta: std.ArrayList(HistoryMeta),
    history_append_index: usize,
    history_enabled: bool,
    completion_specs: std.ArrayList(CompletionSpec),
    completion_candidates: std.ArrayList(CompletionCandidateSpec),
    aliases: std.ArrayList(AliasSpec),
    abbreviations: std.ArrayList(AbbreviationSpec),
    background_jobs: std.ArrayList(BackgroundJob),
    dir_history: std.ArrayList([]u8),
    dir_index: usize,
    /// Previous working directory before the last `cd`. Used for `cd -`.
    prev_cwd: ?[]u8,
    manual_echo: bool,
    /// Set after a CR submit so the next readLine call can swallow a leading LF,
    /// turning a CRLF sequence into a single line submission.
    pending_cr_swallow: bool,
    last_completion_prefix: ?[]u8,
    /// When true, the shell is in Ctrl+R history-search mode.
    history_search_active: bool,
    /// The live query while searching history.
    history_search_query: ?[]u8,
    /// Index of the currently selected history match while searching.
    history_search_index: usize,
    prompt_mode: PromptMode,
    prompt_snapshot: PromptSnapshot,
    prompt_snapshot_valid: bool,
    last_status: u8,
    last_duration_ms: i64,
    /// Whether the interactive prompt colorizes the line as you type (valid
    /// command heads green/cyan, unknown ones red, quoted strings and operators
    /// distinct). On by default; toggle with `highlight on|off` or the
    /// `ZIGGYZAG_HIGHLIGHT` env var. Independent of `prompt_mode` so the default
    /// classic prompt still gets highlighting.
    highlight_enabled: bool,
    /// Active terminal theme. Read on startup from the ZIGGYZAG_THEME env var,
    /// which the desktop host sets when spawning the shell child. Falls back
    /// to the `ziggy` theme when unset or unknown. See docs/THEME_PROTOCOL.md.
    current_theme: theme.Theme,

    fn init(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map) Shell {
        const initial_theme = if (env.get("ZIGGYZAG_THEME")) |name|
            theme.byName(name)
        else
            theme.ziggy;
        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .history = .empty,
            .history_meta = .empty,
            .history_append_index = 0,
            .history_enabled = true,
            .completion_specs = .empty,
            .completion_candidates = .empty,
            .aliases = .empty,
            .abbreviations = .empty,
            .background_jobs = .empty,
            .dir_history = .empty,
            .dir_index = 0,
            .prev_cwd = null,
            .manual_echo = false,
            .pending_cr_swallow = false,
            .last_completion_prefix = null,
            .history_search_active = false,
            .history_search_query = null,
            .history_search_index = 0,
            .prompt_mode = .classic,
            .prompt_snapshot = .{},
            .prompt_snapshot_valid = false,
            .last_status = 0,
            .last_duration_ms = 0,
            .highlight_enabled = true,
            .current_theme = initial_theme,
        };
    }

    fn loadDefaultAbbreviations(self: *Shell) !void {
        // Sensible defaults that ship with the shell — user config can override these
        const defaults = [_]struct { name: []const u8, value: []const u8 }{
            .{ .name = "gco", .value = "git checkout" },
            .{ .name = "ga", .value = "git add" },
            .{ .name = "gc", .value = "git commit" },
            .{ .name = "gs", .value = "git status" },
            .{ .name = "gp", .value = "git push" },
            .{ .name = "gl", .value = "git pull" },
            .{ .name = "gd", .value = "git diff" },
            .{ .name = "glo", .value = "git log --oneline" },
            .{ .name = "mkcd", .value = "mkcd" },
        };
        for (defaults) |abbr| {
            try self.putAbbreviation(abbr.name, abbr.value);
        }
    }

    fn loadDefaultCompletions(self: *Shell) !void {
        // Hardcoded completions for common commands — discoverable from the start
        const completions = [_]struct { cmd: []const u8, items: []const u8, desc: []const u8 }{
            .{ .cmd = "git", .items = "add commit push pull status diff log checkout branch clone fetch merge rebase stash init remote", .desc = "git subcommand" },
            .{ .cmd = "zig", .items = "build test run fmt check init publish clean", .desc = "zig subcommand" },
            .{ .cmd = "npm", .items = "install run test start build dev ci init list audit", .desc = "npm subcommand" },
            .{ .cmd = "cargo", .items = "build test run fmt clippy check publish init add update", .desc = "cargo subcommand" },
            .{ .cmd = "go", .items = "run build test get install fmt vet mod init", .desc = "go subcommand" },
            .{ .cmd = "docker", .items = "run build ps pull push images logs exec stop start", .desc = "docker subcommand" },
        };
        for (completions) |c| {
            var parts = std.mem.splitScalar(u8, c.items, ' ');
            while (parts.next()) |item| {
                if (item.len > 0) try self.putCompletionCandidate(c.cmd, item, c.desc);
            }
        }
    }

    fn deinit(self: *Shell) void {
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.deinit(self.allocator);
        for (self.history_meta.items) |entry| {
            self.allocator.free(entry.command);
            self.allocator.free(entry.cwd);
        }
        self.history_meta.deinit(self.allocator);
        for (self.completion_specs.items) |spec| {
            self.allocator.free(spec.command);
            self.allocator.free(spec.completer);
        }
        self.completion_specs.deinit(self.allocator);
        for (self.completion_candidates.items) |candidate| {
            self.allocator.free(candidate.command);
            self.allocator.free(candidate.candidate);
            self.allocator.free(candidate.description);
        }
        self.completion_candidates.deinit(self.allocator);
        for (self.aliases.items) |alias| {
            self.allocator.free(alias.name);
            self.allocator.free(alias.value);
        }
        self.aliases.deinit(self.allocator);
        for (self.abbreviations.items) |abbr| {
            self.allocator.free(abbr.name);
            self.allocator.free(abbr.value);
        }
        self.abbreviations.deinit(self.allocator);
        for (self.background_jobs.items) |*job| {
            job.child.kill(self.io);
            self.allocator.free(job.command);
        }
        self.background_jobs.deinit(self.allocator);
        for (self.dir_history.items) |entry| self.allocator.free(entry);
        self.dir_history.deinit(self.allocator);
        if (self.prev_cwd) |cwd| self.allocator.free(cwd);
        if (self.history_search_query) |q| self.allocator.free(q);
        self.clearCompletionState();
    }

    fn run(self: *Shell) !void {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin = std.Io.File.stdin().readerStreaming(self.io, &stdin_buffer);
        var stdout = std.Io.File.stdout().writerStreaming(self.io, &.{});

        self.loadStartupConfig() catch |err| switch (err) {
            error.ConfigFileTooLarge => {
                var stderr = std.Io.File.stderr().writerStreaming(self.io, &.{});
                try stderr.interface.print("config: file too large (limit {d} bytes); skipping startup config\n", .{max_config_file_bytes});
            },
            else => |e| return e,
        };
        try self.loadDefaultAbbreviations();
        try self.loadDefaultCompletions();
        try self.rememberCurrentDirectory(false);

        const terminal_mode = try TerminalMode.enable();
        defer if (terminal_mode) |mode| mode.restore();
        self.manual_echo = terminal_mode != null;
        defer self.manual_echo = false;

        const histfile = self.env.get("HISTFILE");
        // Durable metadata history is on by default (S6): resolve a path even
        // when ZIGGYZAG_HISTORY_DB is unset, falling back to
        // `$HOME/.ziggyzag_history.tsv`. When this resolves, command history —
        // including timing, exit status, and cwd — survives restarts without
        // any configuration. Owned slice freed at scope exit.
        const history_meta_path = if (self.history_enabled) try self.historyDbPathAlloc() else null;
        defer if (history_meta_path) |path| self.allocator.free(path);

        if (self.history_enabled) if (histfile) |path| {
            self.readHistoryFile(path) catch |err| switch (err) {
                error.FileNotFound => {},
                error.HistoryFileTooLarge => {
                    var stderr = std.Io.File.stderr().writerStreaming(self.io, &.{});
                    try stderr.interface.print("history: {s}: file too large (limit {d} bytes)\n", .{ path, max_history_file_bytes });
                },
                else => |e| return e,
            };
            self.history_append_index = self.history.items.len;
        };
        // Restore command metadata from the previous session so `history`,
        // `--stats`, `--slow`, `--cwd`, and `--failed` see history across
        // restarts. Each command now appends a row durably as it finishes (see
        // appendHistoryMetaDurable), so there is no exit-time rewrite — that
        // would clobber rows written by a concurrently running shell.
        if (self.history_enabled) if (history_meta_path) |path| {
            self.readHistoryMetaFile(path) catch |err| switch (err) {
                error.FileNotFound => {},
                error.HistoryFileTooLarge => {
                    var stderr = std.Io.File.stderr().writerStreaming(self.io, &.{});
                    try stderr.interface.print("history-meta: {s}: file too large (limit {d} bytes)\n", .{ path, max_history_file_bytes });
                },
                else => |e| return e,
            };
            // When no plain HISTFILE is configured, the metadata file is the
            // only source of prior-session commands. Seed the interactive
            // `history` list (used by `history`, Up-arrow recall, and
            // autosuggestions) from it so prior sessions are visible by default.
            if (histfile == null) self.seedHistoryFromMeta();
        };
        defer if (histfile) |path| {
            if (self.history_enabled) self.writeHistoryFile(path, false, 0) catch {};
        };

        try self.writeIntegrationSessionReady(&stdout.interface);

        while (true) {
            try self.reapAndPrintDoneJobs();
            try self.writePrompt(&stdout.interface);

            const owned_line = try self.readLine(&stdin.interface, &stdout.interface) orelse break;
            defer self.allocator.free(owned_line);
            if (owned_line.len == 0) continue;

            const expanded_abbreviation_line = try self.expandAbbreviationLine(owned_line);
            defer if (expanded_abbreviation_line) |owned| self.allocator.free(owned);
            const submitted_line = expanded_abbreviation_line orelse owned_line;

            if (self.history_enabled) {
                try self.history.append(self.allocator, try self.allocator.dupe(u8, submitted_line));
            }
            const command_id = if (self.history_enabled) self.history.items.len else self.history.items.len + 1;
            const started_at = std.Io.Clock.real.now(self.io).toMilliseconds();
            try self.writeIntegrationCommandStarted(&stdout.interface, command_id, submitted_line, started_at);
            const keep_running = try self.execute(submitted_line);
            self.last_duration_ms = std.Io.Clock.real.now(self.io).toMilliseconds() - started_at;
            if (self.history_enabled) {
                const meta = try self.recordHistoryMeta(submitted_line, started_at, self.last_duration_ms, self.last_status);
                // Persist immediately so a crash loses at most the command in
                // flight. Skip commands that likely carry secrets — they stay
                // in this session's in-memory history but never touch disk.
                if (!shouldRedactHistory(submitted_line)) {
                    self.appendHistoryMetaDurable(meta) catch {};
                }
            }
            try self.writeIntegrationCommandFinished(&stdout.interface, command_id, self.last_status, self.last_duration_ms);
            if (!keep_running) break;
        }
    }

    fn readLine(self: *Shell, reader: *std.Io.Reader, stdout: *std.Io.Writer) !?[]u8 {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(self.allocator);
        var cursor: usize = 0;
        var history_index = self.history.items.len;
        var draft_line: ?[]u8 = null;
        defer if (draft_line) |draft| self.allocator.free(draft);

        while (true) {
            const byte = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    self.history_search_active = false;
                    if (line.items.len == 0) {
                        line.deinit(self.allocator);
                        return null;
                    }
                    return try line.toOwnedSlice(self.allocator);
                },
                else => |e| return e,
            };

            // If the previous readLine call submitted on '\r', swallow one
            // leading '\n' so that a CRLF pair counts as a single submit.
            // Clear the flag on any byte so it cannot affect a later call.
            if (self.pending_cr_swallow) {
                self.pending_cr_swallow = false;
                if (byte == '\n') continue;
            }

            // Ctrl+R history search mode: all keys go to the search handler
            if (self.history_search_active) {
                if (byte == 0x1b) {
                    try self.handleHistorySearchEscape(reader, stdout, &line, &cursor);
                } else {
                    _ = try self.handleHistorySearchKey(byte, stdout, &line, &cursor);
                }
                continue;
            }

            switch (byte) {
                '\n', '\r' => {
                    self.clearCompletionState();
                    if (self.manual_echo) {
                        try self.redrawPromptLine(stdout, line.items, line.items.len);
                        try stdout.writeByte('\n');
                    }
                    if (byte == '\r') self.pending_cr_swallow = true;
                    return try line.toOwnedSlice(self.allocator);
                },
                '\t' => try self.completeCommand(&line, &cursor, stdout),
                0x01 => {
                    self.clearCompletionState();
                    cursor = 0;
                    if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor);
                },
                0x02 => {
                    self.clearCompletionState();
                    if (cursor > 0) cursor -= 1;
                    if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor);
                },
                0x04 => {
                    self.clearCompletionState();
                    if (line.items.len == 0) {
                        line.deinit(self.allocator);
                        return null;
                    }
                    if (cursor < line.items.len) {
                        try line.replaceRange(self.allocator, cursor, 1, &.{});
                    }
                    if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor);
                },
                0x05 => {
                    self.clearCompletionState();
                    cursor = line.items.len;
                    if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor);
                },
                0x06 => try self.acceptAutosuggestion(stdout, &line, &cursor),
                0x0b => {
                    self.clearCompletionState();
                    if (cursor < line.items.len) {
                        try line.replaceRange(self.allocator, cursor, line.items.len - cursor, &.{});
                    }
                    if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor);
                },
                0x0c => {
                    if (self.manual_echo) try stdout.writeAll("\x1b[H\x1b[2J");
                    try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor);
                },
                0x12 => try self.startHistorySearch(stdout, &line, &cursor),
                0x15 => {
                    self.clearCompletionState();
                    if (cursor > 0) {
                        try line.replaceRange(self.allocator, 0, cursor, &.{});
                        cursor = 0;
                    }
                    if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor);
                },
                0x17 => {
                    self.clearCompletionState();
                    const start = previousWordStart(line.items, cursor);
                    if (start < cursor) {
                        try line.replaceRange(self.allocator, start, cursor - start, &.{});
                        cursor = start;
                    }
                    if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor);
                },
                0x1b => try self.handleEscapeSequence(reader, stdout, &line, &cursor, &history_index, &draft_line),
                0x08, 0x7f => {
                    self.clearCompletionState();
                    if (cursor > 0) {
                        try line.replaceRange(self.allocator, cursor - 1, 1, &.{});
                        cursor -= 1;
                        if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor);
                    }
                },
                else => {
                    self.clearCompletionState();
                    try line.insert(self.allocator, cursor, byte);
                    cursor += 1;
                    if (byte == ' ') try self.expandAbbreviationInEditor(&line, &cursor);
                    if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor);
                },
            }
        }
    }

    fn handleEscapeSequence(
        self: *Shell,
        reader: *std.Io.Reader,
        stdout: *std.Io.Writer,
        line: *std.ArrayList(u8),
        cursor: *usize,
        history_index: *usize,
        draft_line: *?[]u8,
    ) !void {
        const introducer = reader.takeByte() catch return;
        // OSC sequences (ESC ]) carry the Theme Protocol v2 live-update payload
        // emitted by the desktop host on Ctrl+Shift+T. We consume them silently
        // here so they never reach the line buffer or get echoed. See
        // docs/reference/theme-protocol.md for the wire format.
        if (introducer == ']') return self.handleOscSequence(reader);
        if (introducer != '[' and introducer != 'O') return;

        const key = reader.takeByte() catch return;
        switch (key) {
            'A' => try self.navigateHistory(.previous, stdout, line, cursor, history_index, draft_line),
            'B' => try self.navigateHistory(.next, stdout, line, cursor, history_index, draft_line),
            'C' => {
                self.clearCompletionState();
                if (cursor.* < line.items.len) {
                    cursor.* += 1;
                    if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor.*);
                } else {
                    try self.acceptAutosuggestion(stdout, line, cursor);
                }
            },
            'D' => {
                self.clearCompletionState();
                if (cursor.* > 0) cursor.* -= 1;
                if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor.*);
            },
            'F' => {
                self.clearCompletionState();
                cursor.* = line.items.len;
                if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor.*);
            },
            'H' => {
                self.clearCompletionState();
                cursor.* = 0;
                if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor.*);
            },
            '1', '3', '4', '7', '8' => {
                const suffix = reader.takeByte() catch return;
                if (suffix != '~') return;
                switch (key) {
                    '1', '7' => cursor.* = 0,
                    '4', '8' => cursor.* = line.items.len,
                    '3' => if (cursor.* < line.items.len) try line.replaceRange(self.allocator, cursor.*, 1, &.{}),
                    else => {},
                }
                self.clearCompletionState();
                if (self.manual_echo) try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor.*);
            },
            else => {},
        }
    }

    /// Consume an OSC sequence starting after the ESC ] introducer.
    /// Recognises `7777 ; ziggyzag.theme=<id>` and updates `current_theme` in place
    /// (Theme Protocol v2 — live theme updates from the desktop host without
    /// restarting the shell). Every other OSC payload is read and discarded
    /// silently. Bounded to `max_osc_param_bytes` to keep a hostile sequence from
    /// consuming arbitrary input.
    fn handleOscSequence(self: *Shell, reader: *std.Io.Reader) !void {
        var buf: [max_osc_param_bytes]u8 = undefined;
        var len: usize = 0;
        var saw_esc = false;
        while (len < buf.len) {
            const byte = reader.takeByte() catch break;
            if (byte == 0x07) break; // BEL terminator (xterm convention)
            if (saw_esc) {
                if (byte == '\\') break; // ESC \ string terminator (ECMA-48)
                // The previous ESC was spurious; recover by treating both bytes as literal.
                if (len + 1 < buf.len) {
                    buf[len] = 0x1b;
                    len += 1;
                }
                saw_esc = false;
            }
            if (byte == 0x1b) {
                saw_esc = true;
                continue;
            }
            buf[len] = byte;
            len += 1;
        }
        applyOscPayload(self, buf[0..len]);
    }

    const HistoryDirection = enum {
        previous,
        next,
    };

    fn navigateHistory(
        self: *Shell,
        direction: HistoryDirection,
        stdout: *std.Io.Writer,
        line: *std.ArrayList(u8),
        cursor: *usize,
        history_index: *usize,
        draft_line: *?[]u8,
    ) !void {
        self.clearCompletionState();
        if (self.history.items.len == 0) return;

        if (draft_line.* == null and history_index.* == self.history.items.len) {
            draft_line.* = try self.allocator.dupe(u8, line.items);
        }

        switch (direction) {
            .previous => {
                if (history_index.* > 0) history_index.* -= 1;
                try self.replaceCurrentLine(line, self.history.items[history_index.*]);
                cursor.* = line.items.len;
            },
            .next => {
                if (history_index.* + 1 < self.history.items.len) {
                    history_index.* += 1;
                    try self.replaceCurrentLine(line, self.history.items[history_index.*]);
                    cursor.* = line.items.len;
                } else {
                    history_index.* = self.history.items.len;
                    try self.replaceCurrentLine(line, draft_line.* orelse "");
                    cursor.* = line.items.len;
                }
            },
        }

        try self.redrawPromptLineWithSuggestion(stdout, line.items, cursor.*);
    }

    fn replaceCurrentLine(self: *Shell, line: *std.ArrayList(u8), contents: []const u8) !void {
        while (line.items.len > 0) {
            _ = line.pop();
        }
        try line.appendSlice(self.allocator, contents);
    }

    fn redrawPromptLine(self: *Shell, stdout: *std.Io.Writer, line: []const u8, cursor: usize) !void {
        if (!self.manual_echo) return;
        try stdout.writeAll("\r\x1b[2K");
        try self.writePrompt(stdout);
        try self.writeHighlightedLine(stdout, line);
        try self.moveCursorBack(stdout, line.len - @min(cursor, line.len));
    }

    fn redrawPromptLineWithSuggestion(self: *Shell, stdout: *std.Io.Writer, line: []const u8, cursor: usize) !void {
        if (!self.manual_echo) return;
        try stdout.writeAll("\r\x1b[2K");
        try self.writePrompt(stdout);
        try self.writeHighlightedLine(stdout, line);
        var suffix_len: usize = 0;
        if (cursor == line.len and line.len > 0) {
            suffix_len = try self.writeAutosuggestion(stdout, line);
        }
        try self.moveCursorBack(stdout, line.len - @min(cursor, line.len) + suffix_len);
    }

    fn writeAutosuggestion(self: *Shell, stdout: *std.Io.Writer, line: []const u8) !usize {
        const suggestion = self.findHistorySuggestion(line) orelse return 0;
        if (suggestion.len <= line.len) return 0;
        const suffix = suggestion[line.len..];
        try stdout.writeAll("\x1b[2m");
        try stdout.writeAll(suffix);
        try stdout.writeAll("\x1b[0m");
        return suffix.len;
    }

    fn moveCursorBack(self: *Shell, stdout: *std.Io.Writer, count: usize) !void {
        _ = self;
        if (count == 0) return;
        try stdout.print("\x1b[{d}D", .{count});
    }

    fn writePrompt(self: *Shell, stdout: *std.Io.Writer) !void {
        if (self.manual_echo) try self.writeTerminalIntegration(stdout);
        switch (self.prompt_mode) {
            .classic => try stdout.writeAll("$ "),
            .smart => {
                if (self.last_status != 0) try stdout.print("[{d}] ", .{self.last_status});
                const cwd = std.process.currentPathAlloc(self.io, self.allocator) catch {
                    try stdout.writeAll("$ ");
                    return;
                };
                defer self.allocator.free(cwd);
                const snapshot = self.promptSnapshot(cwd);
                try stdout.print("{s}", .{baseName(snapshot.cwdSlice())});
                try self.writeGitCompact(stdout, snapshot, true);
                if (snapshot.project_kind) |kind| try stdout.print(" project:{s}", .{@tagName(kind)});
                if (self.background_jobs.items.len > 0) try stdout.print(" jobs:{d}", .{self.background_jobs.items.len});
                if (self.last_duration_ms > 250) try stdout.print(" {d}ms", .{self.last_duration_ms});
                try stdout.writeAll(" $ ");
            },
            .compact => {
                const cwd = std.process.currentPathAlloc(self.io, self.allocator) catch {
                    try stdout.writeAll("$ ");
                    return;
                };
                defer self.allocator.free(cwd);
                const snapshot = self.promptSnapshot(cwd);
                try stdout.print("{s}", .{baseName(snapshot.cwdSlice())});
                try self.writeGitCompact(stdout, snapshot, false);
                if (self.last_status != 0) try stdout.print(" !{d}", .{self.last_status});
                if (self.background_jobs.items.len > 0) try stdout.print(" &{d}", .{self.background_jobs.items.len});
                try stdout.writeAll(" $ ");
            },
            .dev => {
                const cwd = std.process.currentPathAlloc(self.io, self.allocator) catch {
                    try stdout.writeAll("$ ");
                    return;
                };
                defer self.allocator.free(cwd);
                const snapshot = self.promptSnapshot(cwd);
                try self.writeDevPrompt(stdout, snapshot);
            },
            .dashboard => {
                const cwd = std.process.currentPathAlloc(self.io, self.allocator) catch {
                    try stdout.writeAll("$ ");
                    return;
                };
                defer self.allocator.free(cwd);
                const snapshot = self.promptSnapshot(cwd);
                try self.writeDashboardPrompt(stdout, snapshot);
            },
        }
    }

    fn promptSnapshot(self: *Shell, cwd: []const u8) *const PromptSnapshot {
        const now_ms = std.Io.Clock.real.now(self.io).toMilliseconds();
        const cache_ms = envI64Bounded(self.env.get("ZIGGYZAG_PROMPT_CACHE_MS"), default_prompt_cache_ms, 0, 60_000);
        if (self.prompt_snapshot_valid and std.mem.eql(u8, cwd, self.prompt_snapshot.cwdSlice()) and now_ms - self.prompt_snapshot.generated_at_ms <= cache_ms) {
            return &self.prompt_snapshot;
        }

        self.prompt_snapshot = .{};
        self.prompt_snapshot.cwd_len = copyBounded(self.prompt_snapshot.cwd[0..], cwd);
        self.prompt_snapshot.project_kind = self.detectProjectKindFrom(cwd) catch null;
        self.prompt_snapshot.git = self.gitPromptStatus(cwd) catch .{};
        self.prompt_snapshot.generated_at_ms = now_ms;
        self.prompt_snapshot_valid = true;
        return &self.prompt_snapshot;
    }

    fn writeGitCompact(self: *Shell, stdout: *std.Io.Writer, snapshot: *const PromptSnapshot, spaced: bool) !void {
        _ = self;
        if (!snapshot.git.present) return;
        if (spaced) {
            try stdout.writeAll(" (");
        } else {
            try stdout.writeAll(" git:");
        }
        try stdout.print("{s}", .{snapshot.git.branchSlice()});
        if (snapshot.git.hasChanges()) try stdout.writeAll("*");
        if (snapshot.git.ahead > 0) try stdout.print(" >{d}", .{snapshot.git.ahead});
        if (snapshot.git.behind > 0) try stdout.print(" <{d}", .{snapshot.git.behind});
        if (spaced) try stdout.writeAll(")");
    }

    fn writeDevPrompt(self: *Shell, stdout: *std.Io.Writer, snapshot: *const PromptSnapshot) !void {
        try stdout.writeAll("\x1b[36m");
        try stdout.print("{s}", .{baseName(snapshot.cwdSlice())});
        try stdout.writeAll("\x1b[0m");
        if (snapshot.project_kind) |kind| {
            try stdout.writeAll(" | \x1b[35mproject:");
            try stdout.print("{s}", .{@tagName(kind)});
            try stdout.writeAll("\x1b[0m");
        }
        try self.writeGitVisual(stdout, snapshot);
        try self.writeRuntimeVisual(stdout);
        try stdout.writeAll("\n\x1b[32mdev\x1b[0m $ ");
    }

    fn writeDashboardPrompt(self: *Shell, stdout: *std.Io.Writer, snapshot: *const PromptSnapshot) !void {
        try stdout.writeAll("\x1b[2m[ziggyzag]\x1b[0m ");
        try stdout.print("cwd:{s}", .{baseName(snapshot.cwdSlice())});
        if (snapshot.project_kind) |kind| try stdout.print(" project:{s}", .{@tagName(kind)});
        try self.writeGitVisual(stdout, snapshot);
        try self.writeRuntimeVisual(stdout);
        try stdout.writeAll("\n> ");
    }

    fn writeGitVisual(self: *Shell, stdout: *std.Io.Writer, snapshot: *const PromptSnapshot) !void {
        _ = self;
        if (!snapshot.git.present) return;
        try stdout.writeAll(" | \x1b[33mgit:");
        try stdout.print("{s}", .{snapshot.git.branchSlice()});
        try stdout.writeAll("\x1b[0m");
        if (snapshot.git.staged > 0) try stdout.print(" +{d}", .{snapshot.git.staged});
        if (snapshot.git.changed > 0) try stdout.print(" ~{d}", .{snapshot.git.changed});
        if (snapshot.git.untracked > 0) try stdout.print(" ?{d}", .{snapshot.git.untracked});
        if (snapshot.git.conflicts > 0) try stdout.print(" !{d}", .{snapshot.git.conflicts});
        if (snapshot.git.ahead > 0) try stdout.print(" >{d}", .{snapshot.git.ahead});
        if (snapshot.git.behind > 0) try stdout.print(" <{d}", .{snapshot.git.behind});
    }

    fn writeRuntimeVisual(self: *Shell, stdout: *std.Io.Writer) !void {
        if (self.last_status == 0) {
            try stdout.writeAll(" | \x1b[32mok\x1b[0m");
        } else {
            try stdout.print(" | \x1b[31mexit:{d}\x1b[0m", .{self.last_status});
        }
        if (self.last_duration_ms > 0) try stdout.print(" {d}ms", .{self.last_duration_ms});
        if (self.background_jobs.items.len > 0) try stdout.print(" | jobs:{d}", .{self.background_jobs.items.len});
    }

    fn writeTerminalIntegration(self: *Shell, stdout: *std.Io.Writer) !void {
        const cwd = std.process.currentPathAlloc(self.io, self.allocator) catch return;
        defer self.allocator.free(cwd);

        try stdout.print("\x1b]0;ZiggyZag: {s}\x07", .{baseName(cwd)});
        const host = self.env.get("HOSTNAME") orelse self.env.get("COMPUTERNAME") orelse "localhost";
        try stdout.print("\x1b]7;file://{s}", .{host});
        try self.writeFileUriPath(stdout, cwd);
        try stdout.writeByte(0x07);
        try self.writeIntegrationPromptRendered(stdout, cwd);
    }

    fn integrationEnabled(self: *Shell) bool {
        return isTruthyEnv(self.env.get("ZIGGYZAG_APP")) or isTruthyEnv(self.env.get("ZIGGYZAG_INTEGRATION"));
    }

    fn writeIntegrationSessionReady(self: *Shell, stdout: *std.Io.Writer) !void {
        if (!self.integrationEnabled()) return;

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        try payload.appendSlice(self.allocator, "{\"type\":\"session.ready\",\"protocol\":1,\"shell\":\"ziggyzag\",\"version\":\"0.1.0\",\"prompt_mode\":");
        try appendJsonString(self.allocator, &payload, @tagName(self.prompt_mode));
        try payload.append(self.allocator, '}');
        try self.writeIntegrationEvent(stdout, payload.items);
    }

    fn writeIntegrationPromptRendered(self: *Shell, stdout: *std.Io.Writer, cwd: []const u8) !void {
        if (!self.integrationEnabled()) return;

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        try payload.appendSlice(self.allocator, "{\"type\":\"prompt.rendered\",\"cwd\":");
        try appendJsonString(self.allocator, &payload, cwd);
        try payload.appendSlice(self.allocator, ",\"prompt_mode\":");
        try appendJsonString(self.allocator, &payload, @tagName(self.prompt_mode));
        try appendFmt(self.allocator, &payload, ",\"last_status\":{d},\"last_duration_ms\":{d},\"jobs\":{d}", .{
            self.last_status,
            self.last_duration_ms,
            self.background_jobs.items.len,
        });
        const snapshot = self.promptSnapshot(cwd);
        try payload.appendSlice(self.allocator, ",\"project_kind\":");
        if (snapshot.project_kind) |kind| {
            try appendJsonString(self.allocator, &payload, @tagName(kind));
        } else {
            try payload.appendSlice(self.allocator, "null");
        }
        try payload.appendSlice(self.allocator, ",\"git\":");
        if (snapshot.git.present) {
            try payload.appendSlice(self.allocator, "{\"branch\":");
            try appendJsonString(self.allocator, &payload, snapshot.git.branchSlice());
            try appendFmt(self.allocator, &payload, ",\"staged\":{d},\"changed\":{d},\"untracked\":{d},\"conflicts\":{d},\"ahead\":{d},\"behind\":{d}}}", .{
                snapshot.git.staged,
                snapshot.git.changed,
                snapshot.git.untracked,
                snapshot.git.conflicts,
                snapshot.git.ahead,
                snapshot.git.behind,
            });
        } else {
            try payload.appendSlice(self.allocator, "null");
        }
        try payload.append(self.allocator, '}');
        try self.writeIntegrationEvent(stdout, payload.items);
    }

    fn writeIntegrationCommandStarted(self: *Shell, stdout: *std.Io.Writer, command_id: usize, command: []const u8, timestamp: i64) !void {
        if (!self.integrationEnabled()) return;

        const cwd = std.process.currentPathAlloc(self.io, self.allocator) catch null;
        defer if (cwd) |path| self.allocator.free(path);

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        try appendFmt(self.allocator, &payload, "{{\"type\":\"command.started\",\"id\":{d},\"timestamp\":{d},\"cwd\":", .{
            command_id,
            timestamp,
        });
        try appendJsonString(self.allocator, &payload, cwd orelse "");
        try payload.appendSlice(self.allocator, ",\"command\":");
        try appendJsonString(self.allocator, &payload, command);
        try payload.append(self.allocator, '}');
        try self.writeIntegrationEvent(stdout, payload.items);
    }

    fn writeIntegrationCommandFinished(self: *Shell, stdout: *std.Io.Writer, command_id: usize, status: u8, duration_ms: i64) !void {
        if (!self.integrationEnabled()) return;

        const cwd = std.process.currentPathAlloc(self.io, self.allocator) catch null;
        defer if (cwd) |path| self.allocator.free(path);

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        try appendFmt(self.allocator, &payload, "{{\"type\":\"command.finished\",\"id\":{d},\"status\":{d},\"duration_ms\":{d},\"cwd\":", .{
            command_id,
            status,
            duration_ms,
        });
        try appendJsonString(self.allocator, &payload, cwd orelse "");
        try payload.append(self.allocator, '}');
        try self.writeIntegrationEvent(stdout, payload.items);
    }

    fn writeIntegrationEvent(self: *Shell, stdout: *std.Io.Writer, payload: []const u8) !void {
        _ = self;
        try stdout.writeAll("\x1b]777;ziggyzag:event:");
        try stdout.writeAll(payload);
        try stdout.writeByte(0x07);
    }

    fn writeFileUriPath(self: *Shell, stdout: *std.Io.Writer, path: []const u8) !void {
        _ = self;
        if (builtin.os.tag == .windows and path.len >= 2 and path[1] == ':') {
            try stdout.writeByte('/');
        }

        for (path) |c| {
            switch (c) {
                '\\' => try stdout.writeByte('/'),
                ' ' => try stdout.writeAll("%20"),
                else => try stdout.writeByte(c),
            }
        }
    }

    fn gitBranch(self: *Shell) !?[]u8 {
        const cwd = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd);

        var current = try self.allocator.dupe(u8, cwd);
        defer self.allocator.free(current);

        while (true) {
            const head_path = try std.fs.path.join(self.allocator, &.{ current, ".git", "HEAD" });
            defer self.allocator.free(head_path);
            const file = std.Io.Dir.openFileAbsolute(self.io, head_path, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                error.NotDir => null,
                else => |e| return e,
            };
            if (file) |head| {
                defer head.close(self.io);
                var buffer: [256]u8 = undefined;
                var reader = head.readerStreaming(self.io, &buffer);
                const contents = try reader.interface.allocRemaining(self.allocator, .limited(4096));
                defer self.allocator.free(contents);
                const trimmed = std.mem.trim(u8, contents, " \t\r\n");
                const prefix = "ref: refs/heads/";
                if (std.mem.startsWith(u8, trimmed, prefix)) {
                    return try self.allocator.dupe(u8, trimmed[prefix.len..]);
                }
                if (trimmed.len > 0) return try self.allocator.dupe(u8, "detached");
                return null;
            }

            const parent = std.fs.path.dirname(current) orelse return null;
            if (std.mem.eql(u8, parent, current)) return null;
            const next = try self.allocator.dupe(u8, parent);
            self.allocator.free(current);
            current = next;
        }
    }

    fn gitPromptStatus(self: *Shell, cwd: []const u8) !GitPromptStatus {
        if (isFalseyEnv(self.env.get("ZIGGYZAG_PROMPT_GIT_STATUS"))) {
            return try self.gitBranchOnlyStatus();
        }

        const timeout_ms = envI64Bounded(self.env.get("ZIGGYZAG_PROMPT_GIT_TIMEOUT_MS"), default_prompt_git_timeout_ms, 0, 2000);
        if (timeout_ms == 0) return try self.gitBranchOnlyStatus();

        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "git", "-C", cwd, "status", "--porcelain=v1", "--branch" },
            .environ_map = self.env,
            .stdout_limit = .limited(max_prompt_git_output_bytes),
            .stderr_limit = .limited(max_prompt_git_output_bytes),
            .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } },
        }) catch {
            return try self.gitBranchOnlyStatus();
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (termExitCode(result.term) != 0) return try self.gitBranchOnlyStatus();
        var status: GitPromptStatus = .{};
        parseGitStatusOutput(result.stdout, &status);
        return status;
    }

    fn gitBranchOnlyStatus(self: *Shell) !GitPromptStatus {
        var status: GitPromptStatus = .{};
        const branch = try self.gitBranch() orelse return status;
        defer self.allocator.free(branch);
        status.present = true;
        status.branch_len = copyBounded(status.branch[0..], branch);
        return status;
    }

    /// Resolve the highlight class of the command head: builtin, a real
    /// executable on PATH, or unknown. Pulled out of the renderer so the
    /// classification can be asserted in tests.
    fn classifyCommandHead(self: *Shell, command: []const u8) CommandHeadKind {
        if (isShellBuiltin(command)) return .builtin;
        if (self.findExecutable(command) catch null) |path| {
            self.allocator.free(path);
            return .valid;
        }
        return .invalid;
    }

    fn writeHighlightedLine(self: *Shell, stdout: *std.Io.Writer, line: []const u8) !void {
        if (!self.highlight_enabled or line.len == 0) {
            try stdout.writeAll(line);
            return;
        }

        const start = firstNonWhitespace(line);
        const end = if (start < line.len) simpleCommandWordEnd(line, start) else start;
        if (end <= start) {
            try stdout.writeAll(line);
            return;
        }

        const head_kind = self.classifyCommandHead(line[start..end]);

        // Classify every byte once, then emit runs of a single color so we don't
        // reset/reopen ANSI per character. `kinds` is stack-bounded to the
        // interactive line cap.
        var kind_buf: [4096]HighlightKind = undefined;
        if (line.len > kind_buf.len) {
            // Pathologically long line: skip highlighting rather than truncate.
            try stdout.writeAll(line);
            return;
        }
        const kinds = kind_buf[0..line.len];
        classifyHighlight(line, start, end, head_kind, kinds);

        var i: usize = 0;
        while (i < line.len) {
            const kind = kinds[i];
            var j = i + 1;
            while (j < line.len and kinds[j] == kind) : (j += 1) {}
            const code = highlightAnsiCode(kind);
            if (code.len > 0) try stdout.writeAll(code);
            try stdout.writeAll(line[i..j]);
            if (code.len > 0) try stdout.writeAll("\x1b[0m");
            i = j;
        }
    }

    fn findHistorySuggestion(self: *Shell, prefix: []const u8) ?[]const u8 {
        if (prefix.len == 0) return null;
        var index = self.history.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.history.items[index];
            if (entry.len > prefix.len and std.mem.startsWith(u8, entry, prefix)) return entry;
        }
        return null;
    }

    fn bestFuzzyHistoryMatch(self: *Shell, query: []const u8) ?[]const u8 {
        if (self.history.items.len == 0) return null;
        if (query.len == 0) return self.history.items[self.history.items.len - 1];

        var best: ?[]const u8 = null;
        var best_score: usize = std.math.maxInt(usize);
        var index = self.history.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.history.items[index];
            if (fuzzyScore(query, entry)) |score| {
                if (score < best_score) {
                    best = entry;
                    best_score = score;
                }
            }
        }
        return best;
    }

    fn acceptAutosuggestion(self: *Shell, stdout: *std.Io.Writer, line: *std.ArrayList(u8), cursor: *usize) !void {
        const suggestion = self.findHistorySuggestion(line.items) orelse {
            if (self.manual_echo) try stdout.writeByte(0x07);
            return;
        };
        try self.replaceCurrentLine(line, suggestion);
        cursor.* = line.items.len;
        if (self.manual_echo) try self.redrawPromptLine(stdout, line.items, cursor.*);
    }

    fn acceptFuzzyHistoryMatch(self: *Shell, stdout: *std.Io.Writer, line: *std.ArrayList(u8), cursor: *usize) !void {
        const match = self.bestFuzzyHistoryMatch(line.items) orelse {
            if (self.manual_echo) try stdout.writeByte(0x07);
            return;
        };
        try self.replaceCurrentLine(line, match);
        cursor.* = line.items.len;
        if (self.manual_echo) try self.redrawPromptLine(stdout, line.items, cursor.*);
    }

    /// Start incremental Ctrl+R history search mode. Saves the current line
    /// as a draft so we can restore it if the user exits without accepting.
    fn startHistorySearch(self: *Shell, stdout: *std.Io.Writer, line: *std.ArrayList(u8), cursor: *usize) !void {
        self.clearCompletionState();
        // Save current query as the initial search term
        if (self.history_search_query) |q| self.allocator.free(q);
        self.history_search_query = try self.allocator.dupe(u8, line.items);
        self.history_search_index = self.history.items.len;
        self.history_search_active = true;
        try self.redrawHistorySearch(stdout, line, cursor);
    }

    /// Handle key input while in history search mode. Returns true if the key
    /// was consumed by the search handler, false to fall through to normal mode.
    fn handleHistorySearchKey(self: *Shell, byte: u8, stdout: *std.Io.Writer, line: *std.ArrayList(u8), cursor: *usize) !bool {
        switch (byte) {
            '\n', '\r' => {
                // Accept the current match
                try self.acceptHistorySearchMatch(stdout, line, cursor);
                self.history_search_active = false;
                if (self.history_search_query) |q| {
                    self.allocator.free(q);
                    self.history_search_query = null;
                }
                return true;
            },
            0x1b => {
                // Escape — cancel search, restore original draft
                self.history_search_active = false;
                if (self.history_search_query) |q| {
                    self.allocator.free(q);
                    self.history_search_query = null;
                }
                return true;
            },
            0x04, 0x7f, 0x08 => {
                // Backspace — trim query, find new match
                if (self.history_search_query) |q| {
                    if (q.len > 0) {
                        const new_query = try std.fmt.allocPrint(self.allocator, "{s}", .{q[0 .. q.len - 1]});
                        self.allocator.free(q);
                        self.history_search_query = new_query;
                        self.history_search_index = self.history.items.len;
                        try self.stepHistorySearch(stdout, line, cursor, .previous);
                    }
                }
                return true;
            },
            'A' => {
                // Up — previous match
                try self.stepHistorySearch(stdout, line, cursor, .previous);
                return true;
            },
            'B' => {
                // Down — next match
                try self.stepHistorySearch(stdout, line, cursor, .next);
                return true;
            },
            else => {
                // Any other character — append to query
                if (self.history_search_query) |q| {
                    self.history_search_query = try std.fmt.allocPrint(self.allocator, "{s}{c}", .{ q, byte });
                } else {
                    self.history_search_query = try std.fmt.allocPrint(self.allocator, "{c}", .{byte});
                }
                self.history_search_index = self.history.items.len;
                try self.stepHistorySearch(stdout, line, cursor, .previous);
                return true;
            },
        }
    }

    fn stepHistorySearch(self: *Shell, stdout: *std.Io.Writer, line: *std.ArrayList(u8), cursor: *usize, direction: HistoryDirection) !void {
        const query = self.history_search_query orelse return;
        var search_from = self.history_search_index;

        var offset: usize = 1;
        const limit = self.history.items.len;
        while (offset <= limit) : (offset += 1) {
            if (direction == .previous) {
                if (search_from == 0) break;
                search_from -= 1;
            } else {
                if (search_from + 1 >= self.history.items.len) break;
                search_from += 1;
            }
            const entry = self.history.items[search_from];
            if (std.mem.indexOf(u8, entry, query) != null) {
                self.history_search_index = search_from;
                try self.replaceCurrentLine(line, entry);
                cursor.* = line.items.len;
                try self.redrawHistorySearch(stdout, line, cursor);
                return;
            }
        }
        // No match — beep
        if (self.manual_echo) try stdout.writeByte(0x07);
    }

    /// Handle the escape sequence prefix (0x1b) while in history search mode.
    /// Reads the `[` and arrow key, then dispatches to the search handler.
    fn handleHistorySearchEscape(self: *Shell, reader: *std.Io.Reader, stdout: *std.Io.Writer, line: *std.ArrayList(u8), cursor: *usize) !void {
        const introducer = reader.takeByte() catch return;
        if (introducer != '[') {
            // Bare escape — cancel search
            self.history_search_active = false;
            if (self.history_search_query) |q| {
                self.allocator.free(q);
                self.history_search_query = null;
            }
            return;
        }
        const key = reader.takeByte() catch return;
        _ = try self.handleHistorySearchKey(key, stdout, line, cursor);
    }

    fn acceptHistorySearchMatch(self: *Shell, stdout: *std.Io.Writer, line: *std.ArrayList(u8), cursor: *usize) !void {
        if (self.history_search_index < self.history.items.len) {
            const match = self.history.items[self.history_search_index];
            try self.replaceCurrentLine(line, match);
            cursor.* = line.items.len;
            if (self.manual_echo) try self.redrawPromptLine(stdout, line.items, cursor.*);
        }
    }

    fn redrawHistorySearch(self: *Shell, stdout: *std.Io.Writer, line: *std.ArrayList(u8), cursor: *usize) !void {
        if (!self.manual_echo) return;
        const query = self.history_search_query orelse "";
        // Find current match text for preview
        const match_text: []u8 = if (self.history_search_index < self.history.items.len)
            self.history.items[self.history_search_index]
        else
            "";

        try stdout.writeAll("\r\x1b[2K");
        try stdout.writeAll("\x1b[36m(reverse-i-search)\x1b[0m ");
        try stdout.writeAll(query);
        try stdout.writeAll(": ");
        // Show the current match, highlight the query match within it
        try self.writeHighlightedLine(stdout, match_text);
        // Restore line display
        try stdout.writeAll("\r\n");
        try self.writePrompt(stdout);
        try stdout.writeAll(line.items);
        try self.moveCursorBack(stdout, line.items.len - @min(cursor.*, line.items.len));
    }

    fn expandAbbreviationInEditor(self: *Shell, line: *std.ArrayList(u8), cursor: *usize) !void {
        if (cursor.* != line.items.len) return;
        if (line.items.len == 0 or line.items[line.items.len - 1] != ' ') return;
        const command = std.mem.trim(u8, line.items, " \t");
        if (std.mem.indexOfAny(u8, command, " \t|&<>") != null) return;
        const abbr = self.findAbbreviation(command) orelse return;
        line.clearRetainingCapacity();
        try line.appendSlice(self.allocator, abbr.value);
        try line.append(self.allocator, ' ');
        cursor.* = line.items.len;
    }

    fn completeCommand(self: *Shell, line: *std.ArrayList(u8), cursor: *usize, stdout: *std.Io.Writer) !void {
        // Complete the token under the cursor, not the end of the line. Scan
        // only the text up to the cursor so mid-line Tab works; the tail is
        // preserved by `insertCompletion`.
        const before = line.items[0..cursor.*];
        const token_start = completionTokenStart(before);
        if (token_start > 0) {
            if (try self.completeRegisteredCommand(line, cursor, stdout, token_start)) return;
            try self.completePathArgument(line, cursor, stdout, token_start);
            return;
        }

        const prefix = before;
        var matches: std.ArrayList([]u8) = .empty;
        defer {
            for (matches.items) |item| self.allocator.free(item);
            matches.deinit(self.allocator);
        }

        for (shell_builtin_names) |name| {
            try self.addCompletionMatch(&matches, prefix, name);
        }
        try self.addExecutableCompletions(&matches, prefix);

        if (matches.items.len == 0) {
            self.clearCompletionState();
            try stdout.writeByte(0x07);
            return;
        }

        if (matches.items.len > 1) {
            sortCompletionMatches(matches.items);
            const common_prefix = longestCommonPrefix(matches.items);
            if (common_prefix.len > prefix.len) {
                try self.insertCompletion(line, cursor, stdout, common_prefix[prefix.len..]);
                self.clearCompletionState();
                return;
            }

            if (self.last_completion_prefix) |last_prefix| {
                if (std.mem.eql(u8, last_prefix, prefix)) {
                    try self.printCommandCompletionPager(stdout, matches.items, line.items);
                    self.clearCompletionState();
                    return;
                }
            }

            try self.rememberCompletionPrefix(prefix);
            try stdout.writeByte(0x07);
            return;
        }

        self.clearCompletionState();
        const completion = matches.items[0];
        if (completion.len > prefix.len) {
            try self.insertCompletion(line, cursor, stdout, completion[prefix.len..]);
        }
        try self.insertSeparatorSpace(line, cursor, stdout);
    }

    fn completeRegisteredCommand(self: *Shell, line: *std.ArrayList(u8), cursor: *usize, stdout: *std.Io.Writer, token_start: usize) !bool {
        // Operate on the text up to the cursor so the completed token is the one
        // the caret is in, not whatever trails it.
        const before = line.items[0..cursor.*];
        const command = commandNameForCompletion(before) orelse return false;
        const spec = self.findCompletionSpec(command);
        if (spec == null and !self.hasDeclarativeCompletions(command)) return false;
        const prefix = before[token_start..];
        const previous_word = previousCompletionWord(before, token_start);

        var matches: std.ArrayList([]u8) = .empty;
        defer {
            for (matches.items) |item| self.allocator.free(item);
            matches.deinit(self.allocator);
        }

        try self.addDeclarativeCompletionMatches(&matches, command, prefix);
        if (spec) |registered| {
            self.addCompleterMatches(&matches, registered.completer, command, prefix, previous_word, line.items) catch {
                self.clearCompletionState();
                try stdout.writeByte(0x07);
                return true;
            };
        }

        if (matches.items.len == 0) {
            self.clearCompletionState();
            try stdout.writeByte(0x07);
            return true;
        }

        sortCompletionMatches(matches.items);
        if (matches.items.len > 1) {
            const common_prefix = longestCommonPrefix(matches.items);
            if (common_prefix.len > prefix.len) {
                try self.insertCompletion(line, cursor, stdout, common_prefix[prefix.len..]);
                self.clearCompletionState();
                return true;
            }

            if (self.last_completion_prefix) |last_prefix| {
                if (std.mem.eql(u8, last_prefix, prefix)) {
                    try self.printArgumentCompletionPager(stdout, command, matches.items, line.items);
                    self.clearCompletionState();
                    return true;
                }
            }

            try self.rememberCompletionPrefix(prefix);
            try stdout.writeByte(0x07);
            return true;
        }

        self.clearCompletionState();
        const completion = matches.items[0];
        if (completion.len > prefix.len) {
            try self.insertCompletion(line, cursor, stdout, completion[prefix.len..]);
        }
        try self.insertSeparatorSpace(line, cursor, stdout);
        return true;
    }

    /// Replace the token `[token_start..cursor]` with `replacement` and reposition
    /// the cursor at the end of the replacement, redrawing the line. Used by path
    /// completion, where quoting can rewrite the leading bytes of the token (e.g.
    /// adding an opening quote), so a plain suffix-append is not enough.
    fn replaceTokenWithCompletion(self: *Shell, line: *std.ArrayList(u8), cursor: *usize, stdout: *std.Io.Writer, token_start: usize, replacement: []const u8) !void {
        try line.replaceRange(self.allocator, token_start, cursor.* - token_start, replacement);
        cursor.* = token_start + replacement.len;
        if (self.manual_echo) try self.redrawPromptLine(stdout, line.items, cursor.*);
    }

    fn completePathArgument(self: *Shell, line: *std.ArrayList(u8), cursor: *usize, stdout: *std.Io.Writer, token_start: usize) !void {
        // The raw token may be quoted/escaped (`"my fi`, `my\ fi`); decode it to
        // the literal filesystem prefix we actually match against.
        const raw_token = line.items[0..cursor.*][token_start..];
        const decoded = try decodeCompletionToken(self.allocator, raw_token);
        defer self.allocator.free(decoded);

        var matches: std.ArrayList(CompletionEntry) = .empty;
        defer {
            for (matches.items) |item| self.allocator.free(item.text);
            matches.deinit(self.allocator);
        }

        try self.addPathCompletions(&matches, decoded);

        if (matches.items.len == 0) {
            self.clearCompletionState();
            try stdout.writeByte(0x07);
            return;
        }

        sortCompletionEntries(matches.items);
        if (matches.items.len > 1) {
            const common_prefix = longestCommonPrefixEntries(matches.items);
            if (common_prefix.len > decoded.len) {
                // Re-encode the (literal) common prefix with quoting and replace
                // the whole token so spaces survive as a single argument.
                const encoded = try encodeCompletionPath(self.allocator, common_prefix);
                defer self.allocator.free(encoded);
                try self.replaceTokenWithCompletion(line, cursor, stdout, token_start, encoded);
                self.clearCompletionState();
                return;
            }

            // Pager key is the decoded prefix so repeated Tab is detected even
            // when quoting differs.
            if (self.last_completion_prefix) |last_prefix| {
                if (std.mem.eql(u8, last_prefix, decoded)) {
                    try self.printPathCompletionPager(stdout, matches.items, line.items);
                    self.clearCompletionState();
                    return;
                }
            }

            try self.rememberCompletionPrefix(decoded);
            try stdout.writeByte(0x07);
            return;
        }

        self.clearCompletionState();
        const completion = matches.items[0];
        // Encode the literal match (quote if it contains spaces/specials), then
        // append the directory slash or argument-separating space.
        const encoded = try encodeCompletionPath(self.allocator, completion.text);
        defer self.allocator.free(encoded);

        var replacement: std.ArrayList(u8) = .empty;
        defer replacement.deinit(self.allocator);
        try replacement.appendSlice(self.allocator, encoded);
        try replacement.append(self.allocator, if (completion.is_directory) '/' else ' ');

        try self.replaceTokenWithCompletion(line, cursor, stdout, token_start, replacement.items);
    }

    fn printCommandCompletionPager(self: *Shell, stdout: *std.Io.Writer, matches: []const []u8, line: []const u8) !void {
        try stdout.writeByte('\n');
        for (matches) |item| {
            const description = builtinDescription(item) orelse "executable";
            try stdout.print("  {s}  {s}\n", .{ item, description });
        }
        try self.writePrompt(stdout);
        try stdout.writeAll(line);
    }

    fn printArgumentCompletionPager(self: *Shell, stdout: *std.Io.Writer, command: []const u8, matches: []const []u8, line: []const u8) !void {
        try stdout.writeByte('\n');
        for (matches) |item| {
            const description = self.completionCandidateDescription(command, item) orelse "completion";
            try stdout.print("  {s}  {s}\n", .{ item, description });
        }
        try self.writePrompt(stdout);
        try stdout.writeAll(line);
    }

    fn printPathCompletionPager(self: *Shell, stdout: *std.Io.Writer, matches: []const CompletionEntry, line: []const u8) !void {
        try stdout.writeByte('\n');
        for (matches) |item| {
            const marker: []const u8 = if (item.is_directory) "directory" else "path";
            const slash: []const u8 = if (item.is_directory) "/" else "";
            try stdout.print("  {s}{s}  {s}\n", .{ item.text, slash, marker });
        }
        try self.writePrompt(stdout);
        try stdout.writeAll(line);
    }

    /// Splice `text` into `line` at the cursor, preserving whatever follows the
    /// cursor, and advance the cursor past the inserted bytes. This is the
    /// single place completion mutates the buffer, so completing mid-line
    /// (cursor not at end) keeps the suffix intact instead of dropping it.
    ///
    /// When the cursor is at end-of-line this is an ordinary append. When it is
    /// in the middle, the tail is redrawn after the inserted text and the
    /// terminal cursor is walked back to the logical insertion point so the
    /// on-screen caret matches `cursor.*`.
    fn insertCompletion(self: *Shell, line: *std.ArrayList(u8), cursor: *usize, stdout: *std.Io.Writer, text: []const u8) !void {
        if (text.len == 0) return;
        const at = cursor.*;
        const at_end = at == line.items.len;
        try line.insertSlice(self.allocator, at, text);
        cursor.* = at + text.len;

        if (!self.manual_echo) return;
        if (at_end) {
            // Fast path for the common end-of-line case: just echo the bytes.
            try stdout.writeAll(text);
        } else {
            // Mid-line: the tail moved, so redraw the whole line and reposition
            // the caret at the logical cursor.
            try self.redrawPromptLine(stdout, line.items, cursor.*);
        }
    }

    /// Insert a completion separator (a space after a command/argument). If the
    /// cursor is already followed by a space, step over it instead of inserting
    /// a second one — completing a token mid-line shouldn't introduce a double
    /// space before the rest of the line.
    fn insertSeparatorSpace(self: *Shell, line: *std.ArrayList(u8), cursor: *usize, stdout: *std.Io.Writer) !void {
        if (cursor.* < line.items.len and line.items[cursor.*] == ' ') {
            cursor.* += 1;
            if (self.manual_echo) try self.redrawPromptLine(stdout, line.items, cursor.*);
            return;
        }
        try self.insertCompletion(line, cursor, stdout, " ");
    }

    fn rememberCompletionPrefix(self: *Shell, prefix: []const u8) !void {
        self.clearCompletionState();
        self.last_completion_prefix = try self.allocator.dupe(u8, prefix);
    }

    fn clearCompletionState(self: *Shell) void {
        if (self.last_completion_prefix) |prefix| {
            self.allocator.free(prefix);
            self.last_completion_prefix = null;
        }
    }

    fn addPathCompletions(self: *Shell, matches: *std.ArrayList(CompletionEntry), prefix: []const u8) !void {
        const split_index = lastPathSeparator(prefix);
        const dir_prefix = if (split_index) |index| prefix[0 .. index + 1] else "";
        const entry_prefix = if (split_index) |index| prefix[index + 1 ..] else prefix;
        const search_dir = if (dir_prefix.len == 0) "." else dir_prefix;

        var dir = if (std.fs.path.isAbsolute(search_dir))
            std.Io.Dir.openDirAbsolute(self.io, search_dir, .{ .iterate = true }) catch return
        else
            std.Io.Dir.cwd().openDir(self.io, search_dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file and entry.kind != .directory and entry.kind != .sym_link) continue;
            if (!std.mem.startsWith(u8, entry.name, entry_prefix)) continue;

            const text = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ dir_prefix, entry.name });
            try matches.append(self.allocator, .{
                .text = text,
                .is_directory = entry.kind == .directory,
            });
        }
    }

    fn addExecutableCompletions(self: *Shell, matches: *std.ArrayList([]u8), prefix: []const u8) !void {
        const path_value = self.env.get("PATH") orelse "";
        const separator: u8 = if (builtin.os.tag == .windows) ';' else ':';
        var dirs = std.mem.splitScalar(u8, path_value, separator);
        while (dirs.next()) |dir_path| {
            if (dir_path.len == 0) continue;

            var dir = if (std.fs.path.isAbsolute(dir_path))
                std.Io.Dir.openDirAbsolute(self.io, dir_path, .{ .iterate = true }) catch continue
            else
                std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(self.io);

            var iterator = dir.iterate();
            while (try iterator.next(self.io)) |entry| {
                if (entry.kind != .file and entry.kind != .sym_link) continue;
                if (!std.mem.startsWith(u8, entry.name, prefix)) continue;

                const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                defer self.allocator.free(full_path);
                if (try self.pathIsExecutable(full_path)) {
                    try self.addCompletionMatch(matches, prefix, entry.name);
                }
            }
        }
    }

    fn addCompletionMatch(self: *Shell, matches: *std.ArrayList([]u8), prefix: []const u8, name: []const u8) !void {
        if (!std.mem.startsWith(u8, name, prefix)) return;
        if (name.len == 0) return;
        for (matches.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        try matches.append(self.allocator, try self.allocator.dupe(u8, name));
    }

    fn addCompleterMatches(
        self: *Shell,
        matches: *std.ArrayList([]u8),
        completer: []const u8,
        command: []const u8,
        prefix: []const u8,
        previous_word: []const u8,
        line: []const u8,
    ) !void {
        var env_map = try self.env.clone(self.allocator);
        defer env_map.deinit();

        const comp_point = try std.fmt.allocPrint(self.allocator, "{d}", .{line.len});
        defer self.allocator.free(comp_point);
        try env_map.put("COMP_LINE", line);
        try env_map.put("COMP_POINT", comp_point);

        var argv = [_][]const u8{ completer, command, prefix, previous_word };
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &argv,
            .environ_map = &env_map,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        try collectCompleterLines(self.allocator, result.stdout, prefix, matches);
    }

    fn execute(self: *Shell, line: []const u8) anyerror!bool {
        const expanded_slash_line = try self.expandSlashCommandLine(line);
        defer if (expanded_slash_line) |owned| self.allocator.free(owned);
        const slash_line = expanded_slash_line orelse line;

        const expanded_abbreviation_line = try self.expandAbbreviationLine(slash_line);
        defer if (expanded_abbreviation_line) |owned| self.allocator.free(owned);
        const abbreviation_line = expanded_abbreviation_line orelse slash_line;

        const expanded_alias_line = try self.expandAliasLine(abbreviation_line);
        defer if (expanded_alias_line) |owned| self.allocator.free(owned);
        const active_line = expanded_alias_line orelse abbreviation_line;

        if (try self.tryInspectCommand(active_line)) return true;

        if (trailingBackgroundCommand(active_line)) |command_line| {
            try self.startBackgroundJob(command_line);
            self.last_status = 0;
            return true;
        }

        if (hasUnquotedPipe(active_line)) {
            if (!try self.tryRunNativePipeline(active_line)) {
                try self.runViaSystemShell(active_line);
            }
            return true;
        }

        var parsed = parseCommandExpanded(self.allocator, active_line, self) catch |err| switch (err) {
            error.UnterminatedSingleQuote, error.UnterminatedDoubleQuote, error.MissingRedirectTarget => {
                try self.printParseError(active_line, err);
                self.last_status = 2;
                return true;
            },
            else => |e| return e,
        };
        defer parsed.deinit();

        if (parsed.argv.items.len == 0) return true;
        const command = parsed.argv.items[0];
        self.last_status = 0;

        if (std.mem.eql(u8, command, "exit")) {
            if (self.background_jobs.items.len > 0) {
                var stderr_buffer: std.ArrayList(u8) = .empty;
                defer stderr_buffer.deinit(self.allocator);
                try appendFmt(self.allocator, &stderr_buffer, "exit: there are {d} background job(s) running. " ++
                    "Use 'jobs' to list them, 'kill %%N' to stop them, or 'disown %%N' to detach first.\n", .{self.background_jobs.items.len});
                self.last_status = 1;
                try self.emitCommandOutput(&parsed, "", stderr_buffer.items);
                return true;
            }
            return false;
        }

        if (std.mem.eql(u8, command, "cd")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            if (try self.changeDirectory(parsed.argv.items, &stderr_buffer)) try self.rememberCurrentDirectory(true);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "type")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.typeCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "echo")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.echoCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "pwd")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.printWorkingDirectory(&stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "about")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.aboutCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "history")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.historyCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "env")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.envCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "vars")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.varsCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "declare")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.declareVariable(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "complete")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.completeBuiltin(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "which")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.whichCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "path")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.pathCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "mkcd")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            if (try self.mkcdCommand(parsed.argv.items, &stderr_buffer)) try self.rememberCurrentDirectory(true);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "up")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            if (try self.upCommand(parsed.argv.items, &stderr_buffer)) try self.rememberCurrentDirectory(true);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "dirs")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.dirsCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "back")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.backCommand(parsed.argv.items, &stdout_buffer, &stderr_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "forward")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.forwardCommand(parsed.argv.items, &stdout_buffer, &stderr_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "jump")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.jumpCommand(parsed.argv.items, &stdout_buffer, &stderr_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "project")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.projectCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "run")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            const keep_running = try self.runTaskCommand(parsed.argv.items, &stdout_buffer, &stderr_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return keep_running;
        }

        if (std.mem.eql(u8, command, "jobs")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.jobsCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "wait") or
            std.mem.eql(u8, command, "kill") or
            std.mem.eql(u8, command, "disown") or
            std.mem.eql(u8, command, "fg") or
            std.mem.eql(u8, command, "bg"))
        {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.jobControlCommand(parsed.argv.items, &stdout_buffer, &stderr_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "repeat")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            const keep_running = try self.repeatCommand(active_line, parsed.argv.items, &stderr_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return keep_running;
        }

        if (std.mem.eql(u8, command, "timeit")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            const keep_running = try self.timeitCommand(active_line, &stdout_buffer, &stderr_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return keep_running;
        }

        if (std.mem.eql(u8, command, "source")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            const keep_running = try self.sourceCommand(parsed.argv.items, &stderr_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return keep_running;
        }

        if (std.mem.eql(u8, command, "help")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.helpCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "alias")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.aliasCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "abbr")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.abbrCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "unabbr")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.unabbrCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "unalias")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.unaliasCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "export")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.exportCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "unset")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.unsetCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "prompt")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.promptCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "highlight")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            try self.highlightCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, &.{});
            return true;
        }

        if (std.mem.eql(u8, command, "theme")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.themeCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "config")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.configCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (std.mem.eql(u8, command, "doctor")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.doctorCommand(parsed.argv.items, &stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
        }

        if (!isShellBuiltin(command) and (try self.findExecutable(command)) == null) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try appendFmt(self.allocator, &stderr_buffer, "{s}: command not found\n", .{command});
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            self.last_status = 127;
            return true;
        }

        try self.runViaSystemShell(active_line);
        return true;
    }

    fn expandAliasLine(self: *Shell, line: []const u8) !?[]u8 {
        const start = firstNonWhitespace(line);
        if (start >= line.len) return null;
        const end = simpleCommandWordEnd(line, start);
        if (end <= start) return null;

        const name = line[start..end];
        const alias = self.findAlias(name) orelse return null;
        if (std.mem.eql(u8, alias.value, name)) return null;

        var expanded: std.ArrayList(u8) = .empty;
        errdefer expanded.deinit(self.allocator);
        try expanded.appendSlice(self.allocator, line[0..start]);
        try expanded.appendSlice(self.allocator, alias.value);
        try expanded.appendSlice(self.allocator, line[end..]);
        return try expanded.toOwnedSlice(self.allocator);
    }

    fn expandAbbreviationLine(self: *Shell, line: []const u8) !?[]u8 {
        const start = firstNonWhitespace(line);
        if (start >= line.len) return null;
        const end = simpleCommandWordEnd(line, start);
        if (end <= start) return null;

        const name = line[start..end];
        const abbr = self.findAbbreviation(name) orelse return null;
        if (std.mem.eql(u8, abbr.value, name)) return null;

        var expanded: std.ArrayList(u8) = .empty;
        errdefer expanded.deinit(self.allocator);
        try expanded.appendSlice(self.allocator, line[0..start]);
        try expanded.appendSlice(self.allocator, abbr.value);
        try expanded.appendSlice(self.allocator, line[end..]);
        return try expanded.toOwnedSlice(self.allocator);
    }

    fn expandSlashCommandLine(self: *Shell, line: []const u8) !?[]u8 {
        const start = firstNonWhitespace(line);
        if (start >= line.len or line[start] != '/') return null;
        const end = simpleCommandWordEnd(line, start);
        const word = line[start..end];
        const replacement = slashCommandReplacement(word) orelse return null;

        var expanded: std.ArrayList(u8) = .empty;
        errdefer expanded.deinit(self.allocator);
        try expanded.appendSlice(self.allocator, line[0..start]);
        try expanded.appendSlice(self.allocator, replacement);
        try expanded.appendSlice(self.allocator, line[end..]);
        return try expanded.toOwnedSlice(self.allocator);
    }

    fn tryInspectCommand(self: *Shell, line: []const u8) !bool {
        const start = firstNonWhitespace(line);
        if (start >= line.len) return false;
        const end = simpleCommandWordEnd(line, start);
        if (!std.mem.eql(u8, line[start..end], "inspect")) return false;

        var stdout_buffer: std.ArrayList(u8) = .empty;
        defer stdout_buffer.deinit(self.allocator);
        const rest = std.mem.trim(u8, line[end..], " \t");
        try self.inspectLine(rest, &stdout_buffer);
        var stdout = std.Io.File.stdout().writerStreaming(self.io, &.{});
        try stdout.interface.writeAll(stdout_buffer.items);
        self.last_status = 0;
        return true;
    }

    fn printParseError(self: *Shell, line: []const u8, err: anyerror) !void {
        var stderr = std.Io.File.stderr().writerStreaming(self.io, &.{});
        const message = switch (err) {
            error.UnterminatedSingleQuote => "unterminated single quote",
            error.UnterminatedDoubleQuote => "unterminated double quote",
            error.MissingRedirectTarget => "missing redirect target",
            else => @errorName(err),
        };
        try stderr.interface.print("parse error: {s}: {s}\n", .{ message, line });
    }

    fn changeDirectory(self: *Shell, argv: []const []const u8, stderr_buffer: *std.ArrayList(u8)) !bool {
        // Resolve the target path before changing — capture prev cwd first
        const current_cwd = std.process.currentPathAlloc(self.io, self.allocator) catch null;
        defer if (current_cwd) |cwd| self.allocator.free(cwd);

        const target: []const u8 = if (argv.len < 2 or std.mem.eql(u8, argv[1], "~"))
            self.env.get("HOME") orelse ""
        else if (std.mem.eql(u8, argv[1], "-"))
            self.prev_cwd orelse {
                try appendFmt(self.allocator, stderr_buffer, "cd: OLDPWD not set\n", .{});
                self.last_status = 1;
                return false;
            }
        else
            argv[1];

        if (target.len == 0) return true;
        if (std.process.setCurrentPath(self.io, target)) |_| {
            // Save the previous cwd for `cd -`
            if (current_cwd) |cwd| {
                if (self.prev_cwd) |prev| self.allocator.free(prev);
                self.prev_cwd = try self.allocator.dupe(u8, cwd);
            }
            return true;
        } else |_| {
            try appendFmt(self.allocator, stderr_buffer, "cd: {s}: No such file or directory\n", .{target});
            self.last_status = 1;
            return false;
        }
    }

    fn typeCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (argv.len < 2) {
            self.last_status = 2;
            return;
        }

        var missing = false;
        for (argv[1..]) |name| {
            if (isShellBuiltin(name)) {
                try appendFmt(self.allocator, stdout_buffer, "{s} is a shell builtin\n", .{name});
            } else if (try self.findExecutable(name)) |path| {
                defer self.allocator.free(path);
                try appendFmt(self.allocator, stdout_buffer, "{s} is {s}\n", .{ name, path });
            } else {
                try appendFmt(self.allocator, stdout_buffer, "{s}: not found\n", .{name});
                missing = true;
            }
        }
        if (missing) self.last_status = 1;
    }

    fn whichCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        const json = hasArg(argv, "--json");
        var checked: usize = 0;
        var missing = false;
        for (argv[1..]) |name| {
            if (std.mem.startsWith(u8, name, "--")) continue;
            checked += 1;

            if (isShellBuiltin(name)) {
                if (json) {
                    try self.appendWhichJson(stdout_buffer, name, "builtin", name);
                } else {
                    try appendFmt(self.allocator, stdout_buffer, "{s}: shell builtin\n", .{name});
                }
                continue;
            }

            if (try self.findExecutable(name)) |path| {
                defer self.allocator.free(path);
                if (json) {
                    try self.appendWhichJson(stdout_buffer, name, "executable", path);
                } else {
                    try appendFmt(self.allocator, stdout_buffer, "{s}\n", .{path});
                }
                continue;
            }

            if (json) {
                try self.appendWhichJson(stdout_buffer, name, "missing", "");
            } else {
                try appendFmt(self.allocator, stdout_buffer, "{s}: not found\n", .{name});
            }
            missing = true;
        }
        if (checked == 0) self.last_status = 2 else if (missing) self.last_status = 1;
    }

    fn appendWhichJson(self: *Shell, stdout_buffer: *std.ArrayList(u8), name: []const u8, kind: []const u8, path: []const u8) !void {
        try stdout_buffer.appendSlice(self.allocator, "{\"name\":");
        try appendJsonString(self.allocator, stdout_buffer, name);
        try appendFmt(self.allocator, stdout_buffer, ",\"kind\":\"{s}\",\"path\":", .{kind});
        try appendJsonString(self.allocator, stdout_buffer, path);
        try stdout_buffer.appendSlice(self.allocator, "}\n");
    }

    fn pathCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        const path_value = self.env.get("PATH") orelse "";
        const separator: u8 = if (builtin.os.tag == .windows) ';' else ':';
        const json = hasArg(argv, "--json");
        var entries = std.mem.splitScalar(u8, path_value, separator);
        var index: usize = 0;
        while (entries.next()) |entry| : (index += 1) {
            if (json) {
                try appendFmt(self.allocator, stdout_buffer, "{{\"index\":{d},\"path\":", .{index});
                try appendJsonString(self.allocator, stdout_buffer, entry);
                try stdout_buffer.appendSlice(self.allocator, "}\n");
            } else {
                try appendFmt(self.allocator, stdout_buffer, "{d: >3}  {s}\n", .{ index, entry });
            }
        }
    }

    fn mkcdCommand(self: *Shell, argv: []const []const u8, stderr_buffer: *std.ArrayList(u8)) !bool {
        if (argv.len < 2) {
            try stderr_buffer.appendSlice(self.allocator, "mkcd: missing directory\n");
            self.last_status = 2;
            return false;
        }

        const target = argv[1];
        std.Io.Dir.cwd().createDirPath(self.io, target) catch |err| {
            try appendFmt(self.allocator, stderr_buffer, "mkcd: {s}: {s}\n", .{ target, @errorName(err) });
            self.last_status = 1;
            return false;
        };
        std.process.setCurrentPath(self.io, target) catch |err| {
            try appendFmt(self.allocator, stderr_buffer, "mkcd: {s}: {s}\n", .{ target, @errorName(err) });
            self.last_status = 1;
            return false;
        };
        return true;
    }

    fn upCommand(self: *Shell, argv: []const []const u8, stderr_buffer: *std.ArrayList(u8)) !bool {
        const count = if (argv.len >= 2) std.fmt.parseInt(usize, argv[1], 10) catch 1 else 1;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            std.process.setCurrentPath(self.io, "..") catch |err| {
                try appendFmt(self.allocator, stderr_buffer, "up: {s}\n", .{@errorName(err)});
                self.last_status = 1;
                return false;
            };
        }
        return true;
    }

    fn rememberCurrentDirectory(self: *Shell, truncate_forward: bool) !void {
        const raw_cwd = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(raw_cwd);

        const cwd = try self.allocator.dupe(u8, raw_cwd);
        errdefer self.allocator.free(cwd);

        if (self.dir_history.items.len > 0 and self.dir_index < self.dir_history.items.len) {
            if (std.mem.eql(u8, self.dir_history.items[self.dir_index], cwd)) {
                self.allocator.free(cwd);
                return;
            }
        }

        if (truncate_forward and self.dir_history.items.len > 0) {
            while (self.dir_history.items.len > self.dir_index + 1) {
                const removed = self.dir_history.pop().?;
                self.allocator.free(removed);
            }
        }

        try self.dir_history.append(self.allocator, cwd);
        self.dir_index = self.dir_history.items.len - 1;
    }

    fn dirsCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        const json = hasArg(argv, "--json");
        for (self.dir_history.items, 0..) |entry, index| {
            if (json) {
                try appendFmt(self.allocator, stdout_buffer, "{{\"index\":{d},\"current\":{},\"path\":", .{ index, index == self.dir_index });
                try appendJsonString(self.allocator, stdout_buffer, entry);
                try stdout_buffer.appendSlice(self.allocator, "}\n");
            } else {
                const marker: u8 = if (index == self.dir_index) '*' else ' ';
                try appendFmt(self.allocator, stdout_buffer, "{c} {d: >3}  {s}\n", .{ marker, index, entry });
            }
        }
    }

    fn backCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) !void {
        if (self.dir_history.items.len == 0 or self.dir_index == 0) {
            try stderr_buffer.appendSlice(self.allocator, "back: no earlier directory\n");
            self.last_status = 1;
            return;
        }

        const count = if (argv.len >= 2) std.fmt.parseInt(usize, argv[1], 10) catch 1 else 1;
        const target = if (count > self.dir_index) 0 else self.dir_index - count;
        try self.goToDirectoryIndex(target, stdout_buffer, stderr_buffer);
    }

    fn forwardCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) !void {
        if (self.dir_history.items.len == 0 or self.dir_index + 1 >= self.dir_history.items.len) {
            try stderr_buffer.appendSlice(self.allocator, "forward: no later directory\n");
            self.last_status = 1;
            return;
        }

        const count = if (argv.len >= 2) std.fmt.parseInt(usize, argv[1], 10) catch 1 else 1;
        const target = @min(self.dir_history.items.len - 1, self.dir_index + count);
        try self.goToDirectoryIndex(target, stdout_buffer, stderr_buffer);
    }

    fn jumpCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) !void {
        if (argv.len < 2) {
            try stderr_buffer.appendSlice(self.allocator, "jump: usage: jump QUERY\n");
            self.last_status = 2;
            return;
        }

        const query = argv[1];
        var best_index: ?usize = null;
        var best_score: usize = std.math.maxInt(usize);
        for (self.dir_history.items, 0..) |entry, index| {
            if (fuzzyScore(query, entry)) |score| {
                if (score < best_score or (score == best_score and index > (best_index orelse 0))) {
                    best_score = score;
                    best_index = index;
                }
            }
        }

        const target = best_index orelse {
            try appendFmt(self.allocator, stderr_buffer, "jump: {s}: no matching directory\n", .{query});
            self.last_status = 1;
            return;
        };
        try self.goToDirectoryIndex(target, stdout_buffer, stderr_buffer);
    }

    /// Change to the directory at `target_index` in `dir_history` and update
    /// `self.dir_index` *only on chdir success*. The previous version mutated
    /// `dir_index` first, leaving the shell pointing at the wrong slot when
    /// `setCurrentPath` failed (e.g., the directory had been removed). Callers
    /// pass the desired index so they no longer need to roll back on failure.
    fn goToDirectoryIndex(self: *Shell, target_index: usize, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) !void {
        if (target_index >= self.dir_history.items.len) return;
        const target = self.dir_history.items[target_index];
        std.process.setCurrentPath(self.io, target) catch |err| {
            try appendFmt(self.allocator, stderr_buffer, "dirs: {s}: {s}\n", .{ target, @errorName(err) });
            self.last_status = 1;
            return;
        };
        self.dir_index = target_index;
        try appendFmt(self.allocator, stdout_buffer, "{s}\n", .{target});
    }

    fn echoCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        for (argv[1..], 0..) |arg, index| {
            if (index != 0) try stdout_buffer.append(self.allocator, ' ');
            try stdout_buffer.appendSlice(self.allocator, arg);
        }
        try stdout_buffer.append(self.allocator, '\n');
    }

    fn helpCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        // Handle -h / --help flags
        if (hasArg(argv, "-h") or hasArg(argv, "--help")) {
            try stdout_buffer.appendSlice(self.allocator,
                \\Usage: help [-h] [--help] [command]
                \\
                \\Show shell help. With no arguments, lists all builtins and shortcuts.
                \\  -h, --help    Show this help message
                \\  command       Show detailed help for a specific builtin
                \\
            );
            return;
        }
        try stdout_buffer.appendSlice(self.allocator,
            \\ZiggyZag shell
            \\
            \\Builtins:
            \\  about              Show project and runtime summary
            \\  alias NAME=VALUE   Create a shortcut for a command
            \\  abbr NAME=VALUE    Expand a shortcut before execution
            \\  unabbr NAME        Remove an abbreviation
            \\  unalias NAME       Remove a shortcut
            \\  back [N]           Return to an earlier directory
            \\  cd [DIR]           Change directories
            \\  complete ...       Register programmable completions
            \\  config ...         Show, reload, and validate startup config
            \\  declare NAME=VALUE Store a shell variable
            \\  dirs [--json]      Show directory navigation history
            \\  doctor [--json]    Inspect shell health and runtime state
            \\  echo [ARGS...]     Print text
            \\  env [NAME]         Show environment variables
            \\  export NAME=VALUE  Store an environment variable
            \\  forward [N]        Move forward in directory history
            \\  history [N]        View, clear, import, export, or disable command history
            \\  inspect COMMAND    Explain how ZiggyZag would parse a command
            \\  jump QUERY         Fuzzy-jump to a visited directory
            \\  jobs               List background jobs
            \\  wait [JOB...]      Wait for background jobs
            \\  kill [-SIG] TGT    Kill a job (%N) or process id
            \\  disown [JOB...]    Remove jobs from shell tracking
            \\  fg [JOB]           Wait for a job in the foreground
            \\  bg [JOB]           Show/resume a tracked background job
            \\  mkcd DIR           Create and enter a directory
            \\  path [--json]      Show PATH entries
            \\  project [--json]   Detect project kind, root, and tasks
            \\  prompt [MODE]      Show or set prompt mode: classic, smart, compact, dev, dashboard
            \\  pwd                Print the current directory
            \\  repeat N COMMAND   Run a command multiple times
            \\  run [TASK]         Run a project-aware task
            \\  source FILE        Run commands from a file
            \\  timeit COMMAND     Run a command and report duration
            \\  type NAME          Explain how a command resolves
            \\  up [N]             Move up parent directories
            \\  unset NAME         Remove a variable
            \\  vars [--json]      Show shell variable map
            \\  which NAME         Resolve command paths
            \\  exit               Leave the shell
            \\
            \\Line editing:
            \\  Tab completion, autosuggestions, Ctrl-F accept suggestion, Ctrl-R fuzzy history,
            \\  cursor movement, Home/End, Ctrl-A/E, Ctrl-U/K/W, redirection, native simple pipes,
            \\  and background jobs.
            \\
            \\Slash commands:
            \\  /help, /doctor, /config, /reload, /inspect, /smart, /classic, /compact, /dev, /dashboard, /themes
            \\
        );
    }

    fn printWorkingDirectory(self: *Shell, stdout_buffer: *std.ArrayList(u8)) !void {
        const cwd = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd);
        try appendFmt(self.allocator, stdout_buffer, "{s}\n", .{cwd});
    }

    fn aboutCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (hasArg(argv, "--json")) {
            try stdout_buffer.appendSlice(self.allocator, "{\"name\":\"ZiggyZag\",\"version\":\"0.1.0\",\"language\":\"Zig\",\"zig_minimum\":\"0.16.0\",\"repo\":\"https://github.com/PascalAI2024/ZiggyZag\",\"builtins\":");
            try appendFmt(self.allocator, stdout_buffer, "{d}", .{shell_builtin_names.len});
            try stdout_buffer.appendSlice(self.allocator, "}\n");
            return;
        }

        try appendFmt(self.allocator, stdout_buffer,
            \\ZiggyZag 0.1.0
            \\A modern Zig shell lab for parsing, completions, history, prompts, jobs, and native pipeline experiments.
            \\Repo: https://github.com/PascalAI2024/ZiggyZag
            \\Builtins: {d}
            \\
        , .{shell_builtin_names.len});
    }

    fn envCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (hasArg(argv, "--json")) {
            var it = self.env.iterator();
            while (it.next()) |entry| {
                try stdout_buffer.appendSlice(self.allocator, "{\"name\":");
                try appendJsonString(self.allocator, stdout_buffer, entry.key_ptr.*);
                try stdout_buffer.appendSlice(self.allocator, ",\"value\":");
                try appendJsonString(self.allocator, stdout_buffer, entry.value_ptr.*);
                try stdout_buffer.appendSlice(self.allocator, "}\n");
            }
            return;
        }

        if (argv.len >= 2) {
            const name = argv[1];
            if (self.env.get(name)) |value| {
                try appendFmt(self.allocator, stdout_buffer, "{s}\n", .{value});
            } else {
                try appendFmt(self.allocator, stdout_buffer, "env: {s}: not found\n", .{name});
            }
            return;
        }

        var it = self.env.iterator();
        while (it.next()) |entry| {
            try appendFmt(self.allocator, stdout_buffer, "{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    fn varsCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (hasArg(argv, "--json")) {
            var it = self.env.iterator();
            while (it.next()) |entry| {
                try stdout_buffer.appendSlice(self.allocator, "{\"name\":");
                try appendJsonString(self.allocator, stdout_buffer, entry.key_ptr.*);
                try stdout_buffer.appendSlice(self.allocator, ",\"value\":");
                try appendJsonString(self.allocator, stdout_buffer, entry.value_ptr.*);
                try stdout_buffer.appendSlice(self.allocator, "}\n");
            }
            return;
        }

        var it = self.env.iterator();
        while (it.next()) |entry| {
            try appendFmt(self.allocator, stdout_buffer, "declare -- {s}=\"{s}\"\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    fn historyCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (argv.len >= 2 and (std.mem.eql(u8, argv[1], "clear") or std.mem.eql(u8, argv[1], "-c"))) {
            self.clearHistory();
            return;
        }

        if (argv.len >= 2 and std.mem.eql(u8, argv[1], "disable")) {
            self.history_enabled = false;
            if (hasArg(argv, "--clear")) self.clearHistory();
            try stdout_buffer.appendSlice(self.allocator, "history: disabled\n");
            return;
        }

        if (argv.len >= 2 and std.mem.eql(u8, argv[1], "enable")) {
            self.history_enabled = true;
            try stdout_buffer.appendSlice(self.allocator, "history: enabled\n");
            return;
        }

        if (argv.len >= 2 and std.mem.eql(u8, argv[1], "status")) {
            try appendFmt(self.allocator, stdout_buffer, "history: {s}\ncommands: {d}\nmetadata: {d}\n", .{
                if (self.history_enabled) "enabled" else "disabled",
                self.history.items.len,
                self.history_meta.items.len,
            });
            return;
        }

        if (argv.len >= 3 and std.mem.eql(u8, argv[1], "export")) {
            try self.exportHistoryFile(argv[2], hasArg(argv, "--json"), hasArg(argv, "--meta"));
            return;
        }

        if (argv.len >= 3 and std.mem.eql(u8, argv[1], "import")) {
            try self.importHistoryMeta(argv[2], stdout_buffer);
            return;
        }

        if (argv.len >= 3 and std.mem.eql(u8, argv[1], "-r")) {
            try self.readHistoryFile(argv[2]);
            return;
        }

        if (argv.len >= 3 and std.mem.eql(u8, argv[1], "-w")) {
            try self.writeHistoryFile(argv[2], false, 0);
            self.history_append_index = self.history.items.len;
            return;
        }

        if (argv.len >= 3 and std.mem.eql(u8, argv[1], "-a")) {
            try self.writeHistoryFile(argv[2], true, self.history_append_index);
            self.history_append_index = self.history.items.len;
            return;
        }

        if (argv.len >= 3 and std.mem.eql(u8, argv[1], "--search")) {
            try self.printHistorySearch(argv[2], stdout_buffer);
            return;
        }

        if (argv.len >= 2 and std.mem.eql(u8, argv[1], "--failed")) {
            try self.printFailedHistory(stdout_buffer);
            return;
        }

        if (argv.len >= 2 and std.mem.eql(u8, argv[1], "--slow")) {
            const threshold = if (argv.len >= 3) std.fmt.parseInt(i64, argv[2], 10) catch 250 else 250;
            try self.printSlowHistory(threshold, stdout_buffer);
            return;
        }

        if (argv.len >= 2 and std.mem.eql(u8, argv[1], "--cwd")) {
            const cwd = if (argv.len >= 3) argv[2] else "";
            try self.printHistoryForCwd(cwd, stdout_buffer);
            return;
        }

        if (argv.len >= 2 and std.mem.eql(u8, argv[1], "--stats")) {
            try self.printHistoryStats(stdout_buffer);
            return;
        }

        if (argv.len >= 2 and std.mem.eql(u8, argv[1], "--meta")) {
            if (hasArg(argv, "--json")) {
                try self.printHistoryMetaJson(stdout_buffer);
                return;
            }
            try self.printHistoryMeta(stdout_buffer);
            return;
        }

        if (argv.len >= 2 and std.mem.eql(u8, argv[1], "--json")) {
            try self.printHistoryJson(stdout_buffer);
            return;
        }

        try self.printHistory(argv, stdout_buffer);
    }

    fn clearHistory(self: *Shell) void {
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.clearRetainingCapacity();
        for (self.history_meta.items) |entry| {
            self.allocator.free(entry.command);
            self.allocator.free(entry.cwd);
        }
        self.history_meta.clearRetainingCapacity();
        self.history_append_index = 0;
    }

    fn exportHistoryFile(self: *Shell, path: []const u8, json: bool, meta: bool) !void {
        if (meta and !json) {
            try self.writeHistoryMetaFile(path);
            return;
        }
        if (!meta and !json) {
            try self.writeHistoryFile(path, false, 0);
            return;
        }

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        if (meta) {
            try self.printHistoryMetaJson(&output);
        } else {
            try self.printHistoryJson(&output);
        }
        try self.writeFilePath(path, output.items);
    }

    /// Import history rows from a TSV file (the same format HISTFILE-meta and
    /// `history export --meta` produce) into the durable history store, then
    /// refresh the in-memory metadata so the imported rows are queryable this
    /// session. Backed by `TsvBackend.import_tsv`, which appends rows; the
    /// in-memory reload de-duplicates by reloading the merged file from scratch.
    fn importHistoryMeta(self: *Shell, src_path: []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        const dest = (try self.historyDbPathAlloc()) orelse {
            try stdout_buffer.appendSlice(self.allocator, "history: no history file configured (set HOME or ZIGGYZAG_HISTORY_DB)\n");
            return;
        };
        defer self.allocator.free(dest);

        var tsv = try history_backend.TsvBackend.init(self.allocator, self.io, dest);
        defer tsv.deinit();
        const imported = try tsv.backend().import_tsv(src_path);

        // Reload the merged metadata into memory so `history --stats`/`--meta`
        // and recall reflect the import without a restart.
        for (self.history_meta.items) |entry| {
            self.allocator.free(entry.command);
            self.allocator.free(entry.cwd);
        }
        self.history_meta.clearRetainingCapacity();
        self.readHistoryMetaFile(dest) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };

        try appendFmt(self.allocator, stdout_buffer, "history: imported {d} rows from {s}\n", .{ imported, src_path });
    }

    fn printHistory(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        const limit = if (argv.len >= 2) std.fmt.parseInt(usize, argv[1], 10) catch self.history.items.len else self.history.items.len;
        const start = if (limit < self.history.items.len) self.history.items.len - limit else 0;

        for (self.history.items[start..], start..) |entry, index| {
            try appendFmt(self.allocator, stdout_buffer, "{d: >5}  {s}\n", .{ index + 1, entry });
        }
    }

    fn loadStartupConfig(self: *Shell) !void {
        if (self.env.get("ZIGGYZAG_PROMPT")) |mode| {
            if (promptModeByName(mode)) |prompt_mode| self.prompt_mode = prompt_mode;
        }
        if (isFalseyEnv(self.env.get("ZIGGYZAG_HISTORY")) or isTruthyEnv(self.env.get("ZIGGYZAG_HISTORY_PRIVATE"))) {
            self.history_enabled = false;
        }
        if (isFalseyEnv(self.env.get("ZIGGYZAG_HIGHLIGHT"))) {
            self.highlight_enabled = false;
        }

        const path = try self.configPathAlloc();
        defer self.allocator.free(path);
        self.loadConfigFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    fn configPathAlloc(self: *Shell) ![]u8 {
        if (self.env.get("ZIGGYZAG_CONFIG")) |path| return try self.allocator.dupe(u8, path);
        const home = self.env.get("HOME") orelse self.env.get("USERPROFILE") orelse ".";
        return try std.fs.path.join(self.allocator, &.{ home, ".ziggyzagrc" });
    }

    /// Resolve the durable history metadata path. Honors `ZIGGYZAG_HISTORY_DB`
    /// when set; otherwise falls back to `$HOME/.ziggyzag_history.tsv` so that
    /// command history persists across restarts *by default* (Wave 4 / S6). The
    /// returned slice is always owned by the caller. Returns null only when no
    /// home directory can be determined and no explicit override is set, in
    /// which case the shell runs without durable history rather than writing to
    /// a surprising relative path.
    fn historyDbPathAlloc(self: *Shell) !?[]u8 {
        if (self.env.get("ZIGGYZAG_HISTORY_DB")) |path| {
            if (path.len == 0) return null;
            return try self.allocator.dupe(u8, path);
        }
        const home = self.env.get("HOME") orelse self.env.get("USERPROFILE") orelse return null;
        return try std.fs.path.join(self.allocator, &.{ home, ".ziggyzag_history.tsv" });
    }

    fn loadConfigFile(self: *Shell, path: []const u8) !void {
        const file = if (std.fs.path.isAbsolute(path))
            try std.Io.Dir.openFileAbsolute(self.io, path, .{})
        else
            try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);

        var read_buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(self.io, &read_buffer);
        const contents = reader.interface.allocRemaining(self.allocator, .limited(max_config_file_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.ConfigFileTooLarge,
            else => |e| return e,
        };
        defer self.allocator.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, trimTrailingCarriageReturn(raw_line), " \t");
            if (line.len == 0 or line[0] == '#') continue;
            try self.applyConfigLine(line);
        }
    }

    fn applyConfigLine(self: *Shell, line: []const u8) !void {
        var parsed = try parseCommandExpanded(self.allocator, line, self);
        defer parsed.deinit();
        if (parsed.argv.items.len == 0) return;

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        const command = parsed.argv.items[0];
        if (std.mem.eql(u8, command, "alias")) {
            try self.aliasCommand(parsed.argv.items, &output);
        } else if (std.mem.eql(u8, command, "abbr")) {
            try self.abbrCommand(parsed.argv.items, &output);
        } else if (std.mem.eql(u8, command, "export")) {
            try self.exportCommand(parsed.argv.items, &output);
        } else if (std.mem.eql(u8, command, "complete")) {
            try self.completeBuiltin(parsed.argv.items, &output);
        } else if (std.mem.eql(u8, command, "prompt")) {
            try self.promptCommand(parsed.argv.items, &output);
        } else if (std.mem.eql(u8, command, "highlight")) {
            try self.highlightCommand(parsed.argv.items, &output);
        } else if (std.mem.eql(u8, command, "theme")) {
            try self.themeCommand(parsed.argv.items, &output);
        } else if (std.mem.eql(u8, command, "history")) {
            try self.historyCommand(parsed.argv.items, &output);
        }
    }

    fn checkConfigFile(self: *Shell, path: []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        const file = if (std.fs.path.isAbsolute(path))
            try std.Io.Dir.openFileAbsolute(self.io, path, .{})
        else
            try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);

        var read_buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(self.io, &read_buffer);
        const contents = reader.interface.allocRemaining(self.allocator, .limited(max_config_file_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.ConfigFileTooLarge,
            else => |e| return e,
        };
        defer self.allocator.free(contents);

        var ok = true;
        var line_number: usize = 1;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| : (line_number += 1) {
            const line = std.mem.trim(u8, trimTrailingCarriageReturn(raw_line), " \t");
            if (line.len == 0 or line[0] == '#') continue;
            var parsed = parseCommandExpanded(self.allocator, line, self) catch {
                try appendFmt(self.allocator, stdout_buffer, "{d}: parse error\n", .{line_number});
                ok = false;
                continue;
            };
            defer parsed.deinit();
            if (parsed.argv.items.len == 0) continue;
            const command = parsed.argv.items[0];
            if (!isConfigDirective(command)) {
                try appendFmt(self.allocator, stdout_buffer, "{d}: unsupported directive `{s}`\n", .{ line_number, command });
                ok = false;
            }
        }

        if (ok) try appendFmt(self.allocator, stdout_buffer, "ok {s}\n", .{path});
    }

    fn readHistoryFile(self: *Shell, path: []const u8) !void {
        const file = if (std.fs.path.isAbsolute(path))
            try std.Io.Dir.openFileAbsolute(self.io, path, .{})
        else
            try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);

        var read_buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(self.io, &read_buffer);
        const contents = reader.interface.allocRemaining(self.allocator, .limited(max_history_file_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.HistoryFileTooLarge,
            else => |e| return e,
        };
        defer self.allocator.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            const line = trimTrailingCarriageReturn(raw_line);
            if (line.len == 0) continue;
            try self.history.append(self.allocator, try self.allocator.dupe(u8, line));
        }
    }

    fn writeHistoryFile(self: *Shell, path: []const u8, append: bool, start_index: usize) !void {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        if (append) {
            const existing_file = if (std.fs.path.isAbsolute(path))
                std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound => null,
                    else => |e| return e,
                }
            else
                std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound => null,
                    else => |e| return e,
                };

            if (existing_file) |file| {
                defer file.close(self.io);
                var read_buffer: [4096]u8 = undefined;
                var reader = file.readerStreaming(self.io, &read_buffer);
                const existing = try reader.interface.allocRemaining(self.allocator, .limited(max_history_file_bytes));
                defer self.allocator.free(existing);
                try output.appendSlice(self.allocator, existing);
                if (existing.len > 0 and existing[existing.len - 1] != '\n') {
                    try output.append(self.allocator, '\n');
                }
            }
        }

        const start = @min(start_index, self.history.items.len);
        for (self.history.items[start..]) |entry| {
            try output.appendSlice(self.allocator, entry);
            try output.append(self.allocator, '\n');
        }

        try self.writeFilePath(path, output.items);
    }

    fn writeFilePath(self: *Shell, path: []const u8, bytes: []const u8) !void {
        if (std.fs.path.isAbsolute(path)) {
            var file = try std.Io.Dir.createFileAbsolute(self.io, path, .{});
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, bytes);
        } else {
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes });
        }
    }

    /// Append one command's metadata to the in-memory `history_meta` list and
    /// return a copy of the stored row so the caller can persist it durably
    /// (see `appendHistoryMetaDurable`). The returned slices borrow the list's
    /// owned memory and stay valid until `clearHistory`/`deinit`.
    fn recordHistoryMeta(self: *Shell, command: []const u8, timestamp: i64, duration_ms: i64, status: u8) !HistoryMeta {
        const cwd_raw = std.process.currentPathAlloc(self.io, self.allocator) catch null;
        defer if (cwd_raw) |raw| self.allocator.free(raw);
        const cwd = if (cwd_raw) |raw| try self.allocator.dupe(u8, raw) else try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(cwd);
        const owned_command = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_command);

        const entry: HistoryMeta = .{
            .command = owned_command,
            .cwd = cwd,
            .status = status,
            .duration_ms = duration_ms,
            .timestamp = timestamp,
        };
        try self.history_meta.append(self.allocator, entry);
        return entry;
    }

    /// Populate the interactive `history` command list from the metadata loaded
    /// at startup. Called only when no plain HISTFILE is set, so the durable
    /// metadata file becomes the single source of prior-session commands for
    /// `history`, Up-arrow recall, and history-based autosuggestions. Each
    /// command string is duped so `history`'s cleanup contract (free every
    /// element) holds. `history_append_index` is advanced past the seeded rows
    /// so a later `history -a` does not re-append them.
    fn seedHistoryFromMeta(self: *Shell) void {
        for (self.history_meta.items) |entry| {
            const owned = self.allocator.dupe(u8, entry.command) catch return;
            self.history.append(self.allocator, owned) catch {
                self.allocator.free(owned);
                return;
            };
        }
        self.history_append_index = self.history.items.len;
    }

    fn printHistorySearch(self: *Shell, query: []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        var printed: usize = 0;
        var index = self.history.items.len;
        while (index > 0 and printed < 20) {
            index -= 1;
            const entry = self.history.items[index];
            if (fuzzyScore(query, entry) != null) {
                try appendFmt(self.allocator, stdout_buffer, "{d: >5}  {s}\n", .{ index + 1, entry });
                printed += 1;
            }
        }
    }

    fn printFailedHistory(self: *Shell, stdout_buffer: *std.ArrayList(u8)) !void {
        for (self.history_meta.items, 0..) |entry, index| {
            if (entry.status == 0) continue;
            try appendFmt(self.allocator, stdout_buffer, "{d: >5}  status={d} cwd={s}  {s}\n", .{
                index + 1,
                entry.status,
                entry.cwd,
                entry.command,
            });
        }
    }

    fn printSlowHistory(self: *Shell, threshold_ms: i64, stdout_buffer: *std.ArrayList(u8)) !void {
        for (self.history_meta.items, 0..) |entry, index| {
            if (entry.duration_ms < threshold_ms) continue;
            try appendFmt(self.allocator, stdout_buffer, "{d: >5}  duration={d}ms status={d}  {s}\n", .{
                index + 1,
                entry.duration_ms,
                entry.status,
                entry.command,
            });
        }
    }

    fn printHistoryForCwd(self: *Shell, cwd_filter: []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        const raw_cwd = if (cwd_filter.len == 0) try std.process.currentPathAlloc(self.io, self.allocator) else null;
        defer if (raw_cwd) |cwd| self.allocator.free(cwd);
        const effective_cwd: []const u8 = if (cwd_filter.len > 0) cwd_filter else raw_cwd.?;

        for (self.history_meta.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.cwd, effective_cwd)) continue;
            try appendFmt(self.allocator, stdout_buffer, "{d: >5}  status={d} duration={d}ms  {s}\n", .{
                index + 1,
                entry.status,
                entry.duration_ms,
                entry.command,
            });
        }
    }

    fn printHistoryStats(self: *Shell, stdout_buffer: *std.ArrayList(u8)) !void {
        var failed: usize = 0;
        var slowest_ms: i64 = 0;
        var total_ms: i64 = 0;
        var slowest_command: []const u8 = "";

        for (self.history_meta.items) |entry| {
            if (entry.status != 0) failed += 1;
            total_ms += entry.duration_ms;
            if (entry.duration_ms >= slowest_ms) {
                slowest_ms = entry.duration_ms;
                slowest_command = entry.command;
            }
        }

        const average = if (self.history_meta.items.len == 0) 0 else @divTrunc(total_ms, @as(i64, @intCast(self.history_meta.items.len)));
        try appendFmt(self.allocator, stdout_buffer,
            \\history stats
            \\  commands: {d}
            \\  failed: {d}
            \\  average_duration_ms: {d}
            \\  slowest_duration_ms: {d}
            \\  slowest_command: {s}
            \\
        , .{
            self.history_meta.items.len,
            failed,
            average,
            slowest_ms,
            slowest_command,
        });
    }

    fn printHistoryMeta(self: *Shell, stdout_buffer: *std.ArrayList(u8)) !void {
        for (self.history_meta.items, 0..) |entry, index| {
            try appendFmt(self.allocator, stdout_buffer, "{d: >5}  status={d} duration={d}ms cwd={s}  {s}\n", .{
                index + 1,
                entry.status,
                entry.duration_ms,
                entry.cwd,
                entry.command,
            });
        }
    }

    fn printHistoryJson(self: *Shell, stdout_buffer: *std.ArrayList(u8)) !void {
        for (self.history.items, 0..) |entry, index| {
            try appendFmt(self.allocator, stdout_buffer, "{{\"index\":{d},\"command\":", .{index + 1});
            try appendJsonString(self.allocator, stdout_buffer, entry);
            try stdout_buffer.appendSlice(self.allocator, "}\n");
        }
    }

    fn printHistoryMetaJson(self: *Shell, stdout_buffer: *std.ArrayList(u8)) !void {
        for (self.history_meta.items, 0..) |entry, index| {
            try appendFmt(self.allocator, stdout_buffer, "{{\"index\":{d},\"timestamp\":{d},\"status\":{d},\"duration_ms\":{d},\"cwd\":", .{
                index + 1,
                entry.timestamp,
                entry.status,
                entry.duration_ms,
            });
            try appendJsonString(self.allocator, stdout_buffer, entry.cwd);
            try stdout_buffer.appendSlice(self.allocator, ",\"command\":");
            try appendJsonString(self.allocator, stdout_buffer, entry.command);
            try stdout_buffer.appendSlice(self.allocator, "}\n");
        }
    }

    fn writeHistoryMetaFile(self: *Shell, path: []const u8) !void {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        for (self.history_meta.items) |entry| {
            try appendFmt(self.allocator, &output, "{d}\t{d}\t{d}\t", .{ entry.timestamp, entry.status, entry.duration_ms });
            try appendTsvField(self.allocator, &output, entry.cwd);
            try output.append(self.allocator, '\t');
            try appendTsvField(self.allocator, &output, entry.command);
            try output.append(self.allocator, '\n');
        }

        try self.writeFilePath(path, output.items);
    }

    /// Persist a single metadata row to the durable history file immediately
    /// after the command finishes, rather than only at shell exit. This is the
    /// crash-survival guarantee for S6: a `kill -9` (or a panic) loses at most
    /// the in-flight command, and two shells writing concurrently interleave
    /// rows instead of clobbering each other's whole file.
    ///
    /// Reuses the tested `TsvBackend.append` from `history_backend.zig`, whose
    /// on-disk format is byte-identical to `writeHistoryMetaFile`. The append is
    /// read-modify-write (O(file)); acceptable given the 8 MB history cap and a
    /// once-per-command cadence. Best-effort: a write failure is swallowed by
    /// the caller so a read-only `$HOME` never breaks the prompt.
    fn appendHistoryMetaDurable(self: *Shell, meta: HistoryMeta) !void {
        const path = (try self.historyDbPathAlloc()) orelse return;
        defer self.allocator.free(path);

        var tsv = try history_backend.TsvBackend.init(self.allocator, self.io, path);
        defer tsv.deinit();
        try tsv.backend().append(.{
            .command = meta.command,
            .cwd = meta.cwd,
            .exit_status = meta.status,
            .duration_ms = meta.duration_ms,
            .timestamp = meta.timestamp,
        });
    }

    /// Load persisted command metadata from `path` on startup. The previous
    /// implementation only wrote this file at exit; it was never read, so
    /// `history_meta` started empty every session and `history --stats` /
    /// `history --slow` / `history --cwd` could not see anything from prior
    /// sessions. Format is the TSV emitted by `writeHistoryMetaFile`:
    ///   `{timestamp}\t{status}\t{duration_ms}\t{esc_cwd}\t{esc_command}\n`
    /// where the two string fields are escaped with `appendTsvField` (`\\` for
    /// backslash, `\t`/`\n`/`\r` for the corresponding control chars).
    fn readHistoryMetaFile(self: *Shell, path: []const u8) !void {
        const file = if (std.fs.path.isAbsolute(path))
            try std.Io.Dir.openFileAbsolute(self.io, path, .{})
        else
            try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);

        var read_buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(self.io, &read_buffer);
        const contents = reader.interface.allocRemaining(self.allocator, .limited(max_history_file_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.HistoryFileTooLarge,
            else => |e| return e,
        };
        defer self.allocator.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            const line = trimTrailingCarriageReturn(raw_line);
            if (line.len == 0) continue;
            // Split on the first three tabs to peel off the numeric fields; the
            // two string tails are TSV-unescaped before being stored.
            var fields = std.mem.splitScalar(u8, line, '\t');
            const ts_text = fields.next() orelse continue;
            const status_text = fields.next() orelse continue;
            const duration_text = fields.next() orelse continue;
            const cwd_text = fields.next() orelse continue;
            const command_text = fields.next() orelse continue;
            const timestamp = std.fmt.parseInt(i64, ts_text, 10) catch continue;
            const status = std.fmt.parseInt(u8, status_text, 10) catch continue;
            const duration_ms = std.fmt.parseInt(i64, duration_text, 10) catch continue;
            const cwd = try unescapeTsvFieldAlloc(self.allocator, cwd_text);
            errdefer self.allocator.free(cwd);
            const command = try unescapeTsvFieldAlloc(self.allocator, command_text);
            errdefer self.allocator.free(command);
            try self.history_meta.append(self.allocator, .{
                .command = command,
                .cwd = cwd,
                .status = status,
                .duration_ms = duration_ms,
                .timestamp = timestamp,
            });
        }
    }

    fn declareVariable(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (argv.len == 1) {
            var it = self.env.iterator();
            while (it.next()) |entry| {
                try appendFmt(self.allocator, stdout_buffer, "declare -- {s}=\"{s}\"\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            return;
        }

        if (std.mem.eql(u8, argv[1], "-p")) {
            if (argv.len == 2) {
                var it = self.env.iterator();
                while (it.next()) |entry| {
                    try appendFmt(self.allocator, stdout_buffer, "declare -- {s}=\"{s}\"\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
                return;
            }

            for (argv[2..]) |name| {
                if (self.env.get(name)) |value| {
                    try appendFmt(self.allocator, stdout_buffer, "declare -- {s}=\"{s}\"\n", .{ name, value });
                } else {
                    try appendFmt(self.allocator, stdout_buffer, "declare: {s}: not found\n", .{name});
                }
            }
            return;
        }

        for (argv[1..]) |assignment| {
            const eq = std.mem.indexOfScalar(u8, assignment, '=') orelse {
                if (self.env.get(assignment)) |value| {
                    try appendFmt(self.allocator, stdout_buffer, "declare -- {s}=\"{s}\"\n", .{ assignment, value });
                } else {
                    try appendFmt(self.allocator, stdout_buffer, "{s}: not found\n", .{assignment});
                }
                continue;
            };

            const name = assignment[0..eq];
            if (!isValidName(name)) {
                try appendFmt(self.allocator, stdout_buffer, "declare: `{s}': not a valid identifier\n", .{assignment});
                continue;
            }

            try self.env.put(name, assignment[eq + 1 ..]);
        }
    }

    fn aliasCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (hasArg(argv, "-h") or hasArg(argv, "--help")) {
            try stdout_buffer.appendSlice(self.allocator,
                \\Usage: alias [-h] [--help] [name[=value]...]
                \\
                \\Set, list, or remove command aliases.
                \\  -h, --help        Show this help message
                \\  name               Show the value of alias 'name'
                \\  name=value         Create alias: alias name=value
                \\
            );
            return;
        }
        if (argv.len == 1) {
            for (self.aliases.items) |alias| {
                try self.printAlias(alias, stdout_buffer);
            }
            return;
        }

        for (argv[1..]) |spec| {
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
                if (self.findAlias(spec)) |alias| {
                    try self.printAlias(alias.*, stdout_buffer);
                } else {
                    try appendFmt(self.allocator, stdout_buffer, "alias: {s}: not found\n", .{spec});
                }
                continue;
            };

            const name = spec[0..eq];
            if (!isValidName(name)) {
                try appendFmt(self.allocator, stdout_buffer, "alias: `{s}': not a valid identifier\n", .{spec});
                continue;
            }

            try self.putAlias(name, spec[eq + 1 ..]);
        }
    }

    fn unaliasCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        for (argv[1..]) |name| {
            if (!self.removeAlias(name)) {
                try appendFmt(self.allocator, stdout_buffer, "unalias: {s}: not found\n", .{name});
            }
        }
    }

    fn abbrCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (hasArg(argv, "-h") or hasArg(argv, "--help")) {
            try stdout_buffer.appendSlice(self.allocator,
                \\Usage: abbr [-h] [--help] [name[=value]...]
                \\
                \\Manage command abbreviations that expand before execution.
                \\  -h, --help        Show this help message
                \\  name               Show the value of abbreviation 'name'
                \\  name=value         Create abbreviation: abbr name=value
                \\  NOTE: abbreviations expand on SPACE, TAB, or ENTER
                \\
            );
            return;
        }
        if (argv.len == 1) {
            for (self.abbreviations.items) |abbr| {
                try self.printAbbreviation(abbr, stdout_buffer);
            }
            return;
        }

        for (argv[1..]) |spec| {
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
                if (self.findAbbreviation(spec)) |abbr| {
                    try self.printAbbreviation(abbr.*, stdout_buffer);
                } else {
                    try appendFmt(self.allocator, stdout_buffer, "abbr: {s}: not found\n", .{spec});
                }
                continue;
            };

            const name = spec[0..eq];
            if (!isValidName(name)) {
                try appendFmt(self.allocator, stdout_buffer, "abbr: `{s}': not a valid identifier\n", .{spec});
                continue;
            }

            try self.putAbbreviation(name, spec[eq + 1 ..]);
        }
    }

    fn unabbrCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        for (argv[1..]) |name| {
            if (!self.removeAbbreviation(name)) {
                try appendFmt(self.allocator, stdout_buffer, "unabbr: {s}: not found\n", .{name});
            }
        }
    }

    fn exportCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (argv.len == 1) {
            var it = self.env.iterator();
            while (it.next()) |entry| {
                try appendFmt(self.allocator, stdout_buffer, "declare -x {s}=\"{s}\"\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            return;
        }

        for (argv[1..]) |assignment| {
            const eq = std.mem.indexOfScalar(u8, assignment, '=');
            const name = if (eq) |index| assignment[0..index] else assignment;
            if (!isValidName(name)) {
                try appendFmt(self.allocator, stdout_buffer, "export: `{s}': not a valid identifier\n", .{assignment});
                continue;
            }

            const value = if (eq) |index| assignment[index + 1 ..] else self.env.get(name) orelse "";
            try self.env.put(name, value);
        }
    }

    fn unsetCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        for (argv[1..]) |name| {
            if (!isValidName(name)) {
                try appendFmt(self.allocator, stdout_buffer, "unset: `{s}': not a valid identifier\n", .{name});
                continue;
            }
            _ = self.env.orderedRemove(name);
        }
    }

    /// `highlight [on|off|toggle|status]` — control interactive syntax
    /// highlighting. No argument prints the current state.
    fn highlightCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (argv.len >= 2) {
            const arg = argv[1];
            if (std.mem.eql(u8, arg, "on") or std.mem.eql(u8, arg, "enable")) {
                self.highlight_enabled = true;
            } else if (std.mem.eql(u8, arg, "off") or std.mem.eql(u8, arg, "disable")) {
                self.highlight_enabled = false;
            } else if (std.mem.eql(u8, arg, "toggle")) {
                self.highlight_enabled = !self.highlight_enabled;
            } else if (!std.mem.eql(u8, arg, "status")) {
                try appendFmt(self.allocator, stdout_buffer, "highlight: {s}: expected on, off, toggle, or status\n", .{arg});
                return;
            }
        }
        try appendFmt(self.allocator, stdout_buffer, "highlight: {s}\n", .{
            if (self.highlight_enabled) "on" else "off",
        });
    }

    fn promptCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (hasArg(argv, "-h") or hasArg(argv, "--help")) {
            try stdout_buffer.appendSlice(self.allocator,
                \\Usage: prompt [-h] [--help] [--json] [MODE]
                \\
                \\Show or set the prompt mode.
                \\  -h, --help        Show this help message
                \\  --json            Show machine-readable prompt state
                \\  MODE              Set prompt mode: classic, smart, compact, dev, dashboard
                \\  themes            List available prompt themes
                \\
            );
            return;
        }

        if (hasArg(argv, "--json")) {
            try appendFmt(self.allocator, stdout_buffer, "{{\"mode\":\"{s}\",\"last_status\":{d},\"last_duration_ms\":{d},\"modes\":[", .{
                @tagName(self.prompt_mode),
                self.last_status,
                self.last_duration_ms,
            });
            for (prompt_modes, 0..) |mode, index| {
                if (index > 0) try stdout_buffer.append(self.allocator, ',');
                try appendJsonString(self.allocator, stdout_buffer, @tagName(mode));
            }
            try stdout_buffer.appendSlice(self.allocator, "]}\n");
            return;
        }

        if (argv.len == 1) {
            try appendFmt(self.allocator, stdout_buffer, "prompt {s}\n", .{@tagName(self.prompt_mode)});
            return;
        }

        if (std.mem.eql(u8, argv[1], "themes") or std.mem.eql(u8, argv[1], "modes")) {
            for (prompt_modes) |mode| {
                try appendFmt(self.allocator, stdout_buffer, "{s: <10} {s}\n", .{ @tagName(mode), promptModeDescription(mode) });
            }
            return;
        }

        if (promptModeByName(argv[1])) |mode| {
            self.prompt_mode = mode;
            self.prompt_snapshot_valid = false;
            var stderr = std.Io.File.stderr().writer(self.io, &.{});
            try stderr.interface.print("Updated theme '{s}'\n", .{@tagName(mode)});
        } else {
            try appendFmt(self.allocator, stdout_buffer, "prompt: {s}: expected classic, smart, compact, dev, dashboard, or themes\n", .{argv[1]});
        }
    }

    /// Theme builtin. Reports, lists, or switches the active terminal theme.
    /// The theme registry is shared with the desktop host via build-time
    /// import. See docs/THEME_PROTOCOL.md.
    ///
    /// Usage:
    ///   theme            print current theme id and name
    ///   theme list       list known theme ids
    ///   theme --json     emit current theme as JSON (id/name/accent/muted/bg/fg)
    ///   theme <id>       switch this session's theme (does not persist)
    fn themeCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (argv.len <= 1) {
            try appendFmt(self.allocator, stdout_buffer, "{s} ({s})\n", .{
                self.current_theme.id,
                self.current_theme.name,
            });
            return;
        }

        const sub = argv[1];

        if (std.mem.eql(u8, sub, "--json")) {
            try stdout_buffer.appendSlice(self.allocator, "{\"id\":");
            try appendJsonString(self.allocator, stdout_buffer, self.current_theme.id);
            try stdout_buffer.appendSlice(self.allocator, ",\"name\":");
            try appendJsonString(self.allocator, stdout_buffer, self.current_theme.name);
            try appendFmt(self.allocator, stdout_buffer, ",\"accent\":\"#{x:0>2}{x:0>2}{x:0>2}\"", .{
                self.current_theme.accent.r, self.current_theme.accent.g, self.current_theme.accent.b,
            });
            try appendFmt(self.allocator, stdout_buffer, ",\"muted\":\"#{x:0>2}{x:0>2}{x:0>2}\"", .{
                self.current_theme.muted.r, self.current_theme.muted.g, self.current_theme.muted.b,
            });
            try appendFmt(self.allocator, stdout_buffer, ",\"background\":\"#{x:0>2}{x:0>2}{x:0>2}\"", .{
                self.current_theme.background.r, self.current_theme.background.g, self.current_theme.background.b,
            });
            try appendFmt(self.allocator, stdout_buffer, ",\"foreground\":\"#{x:0>2}{x:0>2}{x:0>2}\"", .{
                self.current_theme.foreground.r, self.current_theme.foreground.g, self.current_theme.foreground.b,
            });
            try stdout_buffer.appendSlice(self.allocator, "}\n");
            return;
        }

        if (std.mem.eql(u8, sub, "list")) {
            for (theme.themes) |entry| {
                const marker: u8 = if (std.mem.eql(u8, entry.id, self.current_theme.id)) '*' else ' ';
                try appendFmt(self.allocator, stdout_buffer, "{c} {s: <18} {s}\n", .{
                    marker,
                    entry.id,
                    entry.name,
                });
            }
            return;
        }

        if (theme.maybeByName(sub)) |selected| {
            self.current_theme = selected;
            try appendFmt(self.allocator, stdout_buffer, "{s} ({s})\n", .{ selected.id, selected.name });
            return;
        }

        try appendFmt(self.allocator, stdout_buffer, "theme: unknown theme '{s}'. Run 'theme list' for known ids.\n", .{sub});
        self.last_status = 2;
    }

    fn configCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (hasArg(argv, "-h") or hasArg(argv, "--help")) {
            try stdout_buffer.appendSlice(self.allocator,
                \\Usage: config [-h] [--help] [subcommand] [args...]
                \\
                \\Show, reload, and validate startup config.
                \\  -h, --help        Show this help message
                \\  show              Show current config summary (default)
                \\  path              Print config file path
                \\  reload            Reload config from disk
                \\  check [PATH]      Validate a config file
                \\  sample            Print a sample config
                \\
            );
            return;
        }
        const subcommand = if (argv.len >= 2) argv[1] else "show";
        if (std.mem.eql(u8, subcommand, "path")) {
            const path = try self.configPathAlloc();
            defer self.allocator.free(path);
            try appendFmt(self.allocator, stdout_buffer, "{s}\n", .{path});
            return;
        }

        if (std.mem.eql(u8, subcommand, "reload")) {
            try self.loadStartupConfig();
            const path = try self.configPathAlloc();
            defer self.allocator.free(path);
            try appendFmt(self.allocator, stdout_buffer, "reloaded {s}\n", .{path});
            return;
        }

        if (std.mem.eql(u8, subcommand, "check")) {
            const path = if (argv.len >= 3) argv[2] else try self.configPathAlloc();
            const owned_path = argv.len < 3;
            defer if (owned_path) self.allocator.free(path);
            self.checkConfigFile(path, stdout_buffer) catch |err| switch (err) {
                error.FileNotFound => try appendFmt(self.allocator, stdout_buffer, "missing {s}\n", .{path}),
                else => |e| return e,
            };
            return;
        }

        if (std.mem.eql(u8, subcommand, "sample")) {
            try stdout_buffer.appendSlice(self.allocator,
                \\alias gs='git status --short'
                \\abbr gco='git checkout'
                \\complete -c zig -a 'build fmt test' -d 'common Zig command'
                \\prompt dev
                \\highlight on
                \\# History persists to ~/.ziggyzag_history.tsv by default;
                \\# uncomment to store it elsewhere:
                \\# export ZIGGYZAG_HISTORY_DB=~/.ziggyzag-history.tsv
                \\
            );
            return;
        }

        if (std.mem.eql(u8, subcommand, "show")) {
            const path = try self.configPathAlloc();
            defer self.allocator.free(path);
            try appendFmt(self.allocator, stdout_buffer, "path={s}\nprompt={s}\naliases={d}\nabbreviations={d}\ncompletion_helpers={d}\ncompletion_candidates={d}\n", .{
                path,
                @tagName(self.prompt_mode),
                self.aliases.items.len,
                self.abbreviations.items.len,
                self.completion_specs.items.len,
                self.completion_candidates.items.len,
            });
            return;
        }

        try appendFmt(self.allocator, stdout_buffer, "config: {s}: expected show, path, reload, check, or sample\n", .{subcommand});
    }

    fn doctorCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        const config_path = try self.configPathAlloc();
        defer self.allocator.free(config_path);
        const branch = try self.gitBranch();
        defer if (branch) |name| self.allocator.free(name);
        const histfile = self.env.get("HISTFILE") orelse "";
        // Durable history is on by default, so report the effective path (the
        // resolved `$HOME/.ziggyzag_history.tsv` fallback) rather than the raw
        // env var, which is normally unset.
        const metadata_path_owned = try self.historyDbPathAlloc();
        defer if (metadata_path_owned) |p| self.allocator.free(p);
        const metadata_path = metadata_path_owned orelse "";
        const json_mode = hasArg(argv, "--json");

        // ── Diagnostic checks ────────────────────────────────────────────────
        var issues: std.ArrayList([]const u8) = .empty;
        defer issues.deinit(self.allocator);

        // 1. Config file: warn if ~/.ziggyzagrc doesn't load cleanly
        if (config_path.len > 0) {
            if (std.fs.path.isAbsolute(config_path)) {
                if (std.Io.Dir.openFileAbsolute(self.io, config_path, .{})) |file| {
                    file.close(self.io);
                } else |_| {
                    try issues.append(self.allocator, "config file not found (no ~/.ziggyzagrc loaded)");
                }
            } else {
                if (std.Io.Dir.cwd().openFile(self.io, config_path, .{})) |file| {
                    file.close(self.io);
                } else |_| {
                    try issues.append(self.allocator, "config file not found (no ~/.ziggyzagrc loaded)");
                }
            }
        }

        // 2. History file size: flag if > 10 MB
        if (histfile.len > 0) {
            if (std.fs.path.isAbsolute(histfile)) {
                if (std.Io.Dir.openFileAbsolute(self.io, histfile, .{})) |file| {
                    const stat = file.stat(self.io) catch null;
                    file.close(self.io);
                    if (stat) |s| {
                        if (s.size > 10 * 1024 * 1024) {
                            try issues.append(self.allocator, try std.fmt.allocPrint(self.allocator, "HISTFILE is {d} MB — consider trimming with 'history trim'", .{s.size / (1024 * 1024)}));
                        }
                    }
                } else |_| {}
            } else {
                if (std.Io.Dir.cwd().openFile(self.io, histfile, .{})) |file| {
                    const stat = file.stat(self.io) catch null;
                    file.close(self.io);
                    if (stat) |s| {
                        if (s.size > 10 * 1024 * 1024) {
                            try issues.append(self.allocator, try std.fmt.allocPrint(self.allocator, "HISTFILE is {d} MB — consider trimming with 'history trim'", .{s.size / (1024 * 1024)}));
                        }
                    }
                } else |_| {}
            }
        }

        // 3. Completions: flag if no helpers loaded (shell feels bare)
        if (self.completion_specs.items.len < 3) {
            try issues.append(self.allocator, "no tab completions loaded — add completions in ~/.ziggyzagrc (e.g., 'complete git npm cargo zig')");
        }

        // 4. Abbreviations: flag if none loaded (shell feels bare)
        if (self.abbreviations.items.len < 1) {
            try issues.append(self.allocator, "no abbreviations loaded — add abbrs in ~/.ziggyzagrc (e.g., 'abbr gco \"git checkout\"')");
        }

        // 5. AgentD: warn if agentd isn't on the PATH
        const agentd_path = self.env.get("PATH") orelse "";
        var agentd_found = false;
        if (agentd_path.len > 0) {
            var paths = std.mem.splitScalar(u8, agentd_path, std.fs.path.delimiter);
            while (paths.next()) |dir| {
                if (dir.len == 0) continue;
                const candidate = std.fs.path.join(self.allocator, &.{ dir, "ziggyzag-agentd" }) catch continue;
                defer self.allocator.free(candidate);
                if (std.Io.Dir.cwd().access(self.io, candidate, .{})) |_| {
                    agentd_found = true;
                    break;
                } else |_| {}
            }
        }
        if (!agentd_found) {
            try issues.append(self.allocator, "ziggyzag-agentd not on PATH — AgentD features will be unavailable (run 'zig build' from the project root)");
        }

        if (json_mode) {
            try stdout_buffer.appendSlice(self.allocator, "{\"prompt_mode\":");
            try appendJsonString(self.allocator, stdout_buffer, @tagName(self.prompt_mode));
            try appendFmt(self.allocator, stdout_buffer, ",\"last_status\":{d},\"last_duration_ms\":{d},\"history\":{d},\"history_meta\":{d},\"aliases\":{d},\"abbreviations\":{d},\"completion_helpers\":{d},\"completion_candidates\":{d},\"jobs\":{d},\"issues\":{d}", .{
                self.last_status,
                self.last_duration_ms,
                self.history.items.len,
                self.history_meta.items.len,
                self.aliases.items.len,
                self.abbreviations.items.len,
                self.completion_specs.items.len,
                self.completion_candidates.items.len,
                self.background_jobs.items.len,
                issues.items.len,
            });
            try stdout_buffer.appendSlice(self.allocator, ",\"config_path\":");
            try appendJsonString(self.allocator, stdout_buffer, config_path);
            try stdout_buffer.appendSlice(self.allocator, ",\"histfile\":");
            try appendJsonString(self.allocator, stdout_buffer, histfile);
            try stdout_buffer.appendSlice(self.allocator, ",\"metadata_path\":");
            try appendJsonString(self.allocator, stdout_buffer, metadata_path);
            try stdout_buffer.appendSlice(self.allocator, ",\"git_branch\":");
            try appendJsonString(self.allocator, stdout_buffer, branch orelse "");
            try stdout_buffer.appendSlice(self.allocator, "}\n");
            return;
        }

        // ── Human-readable output ─────────────────────────────────────────────
        try appendFmt(self.allocator, stdout_buffer,
            \\ZiggyZag doctor
            \\  prompt: {s}
            \\  last_status: {d}
            \\  last_duration_ms: {d}
            \\  history: {d} commands, {d} metadata rows
            \\  aliases: {d}
            \\  abbreviations: {d}
            \\  completions: {d} helpers, {d} candidates
            \\  jobs: {d}
            \\  config: {s}
            \\  HISTFILE: {s}
            \\  ZIGGYZAG_HISTORY_DB: {s}
            \\  git_branch: {s}
            \\
        , .{
            @tagName(self.prompt_mode),
            self.last_status,
            self.last_duration_ms,
            self.history.items.len,
            self.history_meta.items.len,
            self.aliases.items.len,
            self.abbreviations.items.len,
            self.completion_specs.items.len,
            self.completion_candidates.items.len,
            self.background_jobs.items.len,
            config_path,
            histfile,
            metadata_path,
            branch orelse "",
        });

        if (issues.items.len == 0) {
            try appendFmt(self.allocator, stdout_buffer, "  [OK] no issues found\n", .{});
        } else {
            for (issues.items) |issue| {
                try appendFmt(self.allocator, stdout_buffer, "  [!] {s}\n", .{issue});
            }
        }
    }

    fn projectCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        const info = try self.detectProject() orelse {
            if (hasArg(argv, "--json")) {
                try stdout_buffer.appendSlice(self.allocator, "{\"kind\":\"none\",\"root\":\"\",\"tasks\":[]}\n");
            } else {
                try stdout_buffer.appendSlice(self.allocator, "project: none\n");
            }
            return;
        };
        defer info.deinit(self.allocator);

        const tasks = projectTasks(info.kind);
        if (hasArg(argv, "--json")) {
            try stdout_buffer.appendSlice(self.allocator, "{\"kind\":");
            try appendJsonString(self.allocator, stdout_buffer, @tagName(info.kind));
            try stdout_buffer.appendSlice(self.allocator, ",\"root\":");
            try appendJsonString(self.allocator, stdout_buffer, info.root);
            try stdout_buffer.appendSlice(self.allocator, ",\"tasks\":[");
            var parts = std.mem.splitScalar(u8, tasks, ' ');
            var first = true;
            while (parts.next()) |task| {
                if (task.len == 0) continue;
                if (!first) try stdout_buffer.append(self.allocator, ',');
                first = false;
                try appendJsonString(self.allocator, stdout_buffer, task);
            }
            try stdout_buffer.appendSlice(self.allocator, "]}\n");
            return;
        }

        try appendFmt(self.allocator, stdout_buffer,
            \\project: {s}
            \\root: {s}
            \\tasks: {s}
            \\
        , .{ @tagName(info.kind), info.root, tasks });
    }

    fn runTaskCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) anyerror!bool {
        const info = try self.detectProject() orelse {
            try stderr_buffer.appendSlice(self.allocator, "run: no supported project found\n");
            self.last_status = 1;
            return true;
        };
        defer info.deinit(self.allocator);

        if (argv.len < 2 or std.mem.eql(u8, argv[1], "--list")) {
            try appendFmt(self.allocator, stdout_buffer, "tasks: {s}\n", .{projectTasks(info.kind)});
            return true;
        }

        const task = argv[1];
        const command_line = try self.taskCommand(info.kind, task);
        defer self.allocator.free(command_line);

        const original = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(original);
        defer std.process.setCurrentPath(self.io, original) catch {};

        std.process.setCurrentPath(self.io, info.root) catch |err| {
            try appendFmt(self.allocator, stderr_buffer, "run: {s}: {s}\n", .{ info.root, @errorName(err) });
            self.last_status = 1;
            return true;
        };

        try appendFmt(self.allocator, stdout_buffer, "run: {s}\n", .{command_line});
        return try self.execute(command_line);
    }

    fn detectProject(self: *Shell) !?ProjectInfo {
        const cwd = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd);

        var current = try self.allocator.dupe(u8, cwd);
        defer self.allocator.free(current);

        while (true) {
            if (try self.pathExistsAt(current, "build.zig")) return .{ .root = try self.allocator.dupe(u8, current), .kind = .zig };
            if (try self.pathExistsAt(current, "package.json")) return .{ .root = try self.allocator.dupe(u8, current), .kind = .node };
            if (try self.pathExistsAt(current, "Cargo.toml")) return .{ .root = try self.allocator.dupe(u8, current), .kind = .rust };
            if (try self.pathExistsAt(current, "pyproject.toml")) return .{ .root = try self.allocator.dupe(u8, current), .kind = .python };
            if (try self.pathExistsAt(current, "go.mod")) return .{ .root = try self.allocator.dupe(u8, current), .kind = .go };
            if (try self.pathExistsAt(current, "Makefile")) return .{ .root = try self.allocator.dupe(u8, current), .kind = .make };
            if (try self.pathExistsAt(current, ".git")) return .{ .root = try self.allocator.dupe(u8, current), .kind = .git };

            const parent = std.fs.path.dirname(current) orelse return null;
            if (std.mem.eql(u8, parent, current)) return null;
            const next = try self.allocator.dupe(u8, parent);
            self.allocator.free(current);
            current = next;
        }
    }

    fn detectProjectKindFrom(self: *Shell, cwd: []const u8) !?ProjectKind {
        var current = try self.allocator.dupe(u8, cwd);
        defer self.allocator.free(current);

        while (true) {
            if (try self.pathExistsAt(current, "build.zig")) return .zig;
            if (try self.pathExistsAt(current, "package.json")) return .node;
            if (try self.pathExistsAt(current, "Cargo.toml")) return .rust;
            if (try self.pathExistsAt(current, "pyproject.toml")) return .python;
            if (try self.pathExistsAt(current, "go.mod")) return .go;
            if (try self.pathExistsAt(current, "Makefile")) return .make;
            if (try self.pathExistsAt(current, ".git")) return .git;

            const parent = std.fs.path.dirname(current) orelse return null;
            if (std.mem.eql(u8, parent, current)) return null;
            const next = try self.allocator.dupe(u8, parent);
            self.allocator.free(current);
            current = next;
        }
    }

    fn pathExistsAt(self: *Shell, root: []const u8, name: []const u8) !bool {
        const path = try std.fs.path.join(self.allocator, &.{ root, name });
        defer self.allocator.free(path);
        std.Io.Dir.accessAbsolute(self.io, path, .{}) catch return false;
        return true;
    }

    fn taskCommand(self: *Shell, kind: ProjectKind, task: []const u8) ![]u8 {
        switch (kind) {
            .zig => {
                if (std.mem.eql(u8, task, "build")) return try self.allocator.dupe(u8, "zig build");
                if (std.mem.eql(u8, task, "test")) return try self.allocator.dupe(u8, "zig build test");
                if (std.mem.eql(u8, task, "run")) return try self.allocator.dupe(u8, "zig build run");
                if (std.mem.eql(u8, task, "fmt")) return try self.allocator.dupe(u8, "zig fmt apps/shell/src/main.zig build.zig");
            },
            .node => {
                if (std.mem.eql(u8, task, "install")) return try self.allocator.dupe(u8, "npm install");
                return try std.fmt.allocPrint(self.allocator, "npm run {s}", .{task});
            },
            .rust => {
                if (std.mem.eql(u8, task, "build")) return try self.allocator.dupe(u8, "cargo build");
                if (std.mem.eql(u8, task, "test")) return try self.allocator.dupe(u8, "cargo test");
                if (std.mem.eql(u8, task, "run")) return try self.allocator.dupe(u8, "cargo run");
                if (std.mem.eql(u8, task, "fmt")) return try self.allocator.dupe(u8, "cargo fmt");
                if (std.mem.eql(u8, task, "check")) return try self.allocator.dupe(u8, "cargo check");
            },
            .python => {
                if (std.mem.eql(u8, task, "test")) return try self.allocator.dupe(u8, "python -m pytest");
                if (std.mem.eql(u8, task, "run")) return try self.allocator.dupe(u8, "python -m pip --version");
                if (std.mem.eql(u8, task, "lint")) return try self.allocator.dupe(u8, "python -m ruff check .");
            },
            .go => {
                if (std.mem.eql(u8, task, "build")) return try self.allocator.dupe(u8, "go build ./...");
                if (std.mem.eql(u8, task, "test")) return try self.allocator.dupe(u8, "go test ./...");
                if (std.mem.eql(u8, task, "run")) return try self.allocator.dupe(u8, "go run .");
                if (std.mem.eql(u8, task, "fmt")) return try self.allocator.dupe(u8, "go fmt ./...");
            },
            .make => return try std.fmt.allocPrint(self.allocator, "make {s}", .{task}),
            .git => {
                if (std.mem.eql(u8, task, "status")) return try self.allocator.dupe(u8, "git status --short");
                if (std.mem.eql(u8, task, "branch")) return try self.allocator.dupe(u8, "git branch --show-current");
            },
        }
        return try std.fmt.allocPrint(self.allocator, "echo no task named {s}", .{task});
    }

    fn repeatCommand(self: *Shell, line: []const u8, argv: []const []const u8, stderr_buffer: *std.ArrayList(u8)) anyerror!bool {
        if (argv.len < 3) {
            try stderr_buffer.appendSlice(self.allocator, "repeat: usage: repeat N COMMAND\n");
            self.last_status = 2;
            return true;
        }

        const count = std.fmt.parseInt(usize, argv[1], 10) catch {
            try appendFmt(self.allocator, stderr_buffer, "repeat: {s}: expected a number\n", .{argv[1]});
            self.last_status = 2;
            return true;
        };
        const command_line = commandRemainder(line, 2) orelse {
            try stderr_buffer.appendSlice(self.allocator, "repeat: missing command\n");
            self.last_status = 2;
            return true;
        };

        var index: usize = 0;
        while (index < count) : (index += 1) {
            if (!try self.execute(command_line)) return false;
        }
        return true;
    }

    fn timeitCommand(self: *Shell, line: []const u8, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) anyerror!bool {
        const command_line = commandRemainder(line, 1) orelse {
            try stderr_buffer.appendSlice(self.allocator, "timeit: usage: timeit COMMAND\n");
            self.last_status = 2;
            return true;
        };

        const started_at = std.Io.Clock.real.now(self.io).toMilliseconds();
        const keep_running = try self.execute(command_line);
        const duration = std.Io.Clock.real.now(self.io).toMilliseconds() - started_at;
        self.last_duration_ms = duration;
        try appendFmt(self.allocator, stdout_buffer, "timeit: {d}ms status={d}\n", .{ duration, self.last_status });
        return keep_running;
    }

    fn sourceCommand(self: *Shell, argv: []const []const u8, stderr_buffer: *std.ArrayList(u8)) anyerror!bool {
        if (argv.len < 2) {
            try stderr_buffer.appendSlice(self.allocator, "source: missing file\n");
            self.last_status = 2;
            return true;
        }

        const path = argv[1];
        const file = if (std.fs.path.isAbsolute(path))
            std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch |err| {
                try appendFmt(self.allocator, stderr_buffer, "source: {s}: {s}\n", .{ path, @errorName(err) });
                self.last_status = 1;
                return true;
            }
        else
            std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| {
                try appendFmt(self.allocator, stderr_buffer, "source: {s}: {s}\n", .{ path, @errorName(err) });
                self.last_status = 1;
                return true;
            };
        defer file.close(self.io);

        var read_buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(self.io, &read_buffer);
        const contents = reader.interface.allocRemaining(self.allocator, .limited(max_source_file_bytes)) catch |err| switch (err) {
            error.StreamTooLong => {
                try appendFmt(self.allocator, stderr_buffer, "source: {s}: file too large (limit {d} bytes)\n", .{ path, max_source_file_bytes });
                self.last_status = 1;
                return true;
            },
            else => |e| return e,
        };
        defer self.allocator.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            const command_line = std.mem.trim(u8, trimTrailingCarriageReturn(raw_line), " \t");
            if (command_line.len == 0 or command_line[0] == '#') continue;
            if (!try self.execute(command_line)) return false;
        }
        return true;
    }

    fn findAlias(self: *Shell, name: []const u8) ?*AliasSpec {
        for (self.aliases.items) |*alias| {
            if (std.mem.eql(u8, alias.name, name)) return alias;
        }
        return null;
    }

    fn putAlias(self: *Shell, name: []const u8, value: []const u8) !void {
        if (self.findAlias(name)) |alias| {
            const owned_value = try self.allocator.dupe(u8, value);
            self.allocator.free(alias.value);
            alias.value = owned_value;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.aliases.append(self.allocator, .{
            .name = owned_name,
            .value = owned_value,
        });
    }

    fn removeAlias(self: *Shell, name: []const u8) bool {
        for (self.aliases.items, 0..) |alias, index| {
            if (std.mem.eql(u8, alias.name, name)) {
                const removed = self.aliases.orderedRemove(index);
                self.allocator.free(removed.name);
                self.allocator.free(removed.value);
                return true;
            }
        }
        return false;
    }

    fn printAlias(self: *Shell, alias: AliasSpec, stdout_buffer: *std.ArrayList(u8)) !void {
        try appendFmt(self.allocator, stdout_buffer, "alias {s}=", .{alias.name});
        try appendSingleQuoted(self.allocator, stdout_buffer, alias.value);
        try stdout_buffer.append(self.allocator, '\n');
    }

    fn findAbbreviation(self: *Shell, name: []const u8) ?*AbbreviationSpec {
        for (self.abbreviations.items) |*abbr| {
            if (std.mem.eql(u8, abbr.name, name)) return abbr;
        }
        return null;
    }

    fn putAbbreviation(self: *Shell, name: []const u8, value: []const u8) !void {
        if (self.findAbbreviation(name)) |abbr| {
            const owned_value = try self.allocator.dupe(u8, value);
            self.allocator.free(abbr.value);
            abbr.value = owned_value;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.abbreviations.append(self.allocator, .{
            .name = owned_name,
            .value = owned_value,
        });
    }

    fn removeAbbreviation(self: *Shell, name: []const u8) bool {
        for (self.abbreviations.items, 0..) |abbr, index| {
            if (std.mem.eql(u8, abbr.name, name)) {
                const removed = self.abbreviations.orderedRemove(index);
                self.allocator.free(removed.name);
                self.allocator.free(removed.value);
                return true;
            }
        }
        return false;
    }

    fn printAbbreviation(self: *Shell, abbr: AbbreviationSpec, stdout_buffer: *std.ArrayList(u8)) !void {
        try appendFmt(self.allocator, stdout_buffer, "abbr {s}=", .{abbr.name});
        try appendSingleQuoted(self.allocator, stdout_buffer, abbr.value);
        try stdout_buffer.append(self.allocator, '\n');
    }

    fn startBackgroundJob(self: *Shell, command_line: []const u8) !void {
        const owned_command = try self.allocator.dupe(u8, command_line);
        errdefer self.allocator.free(owned_command);

        var child = try self.spawnBackgroundProcess(command_line);
        var stored = false;
        errdefer if (!stored) child.kill(self.io);

        const job_number = self.nextJobNumber();
        try self.insertBackgroundJob(.{
            .number = job_number,
            .child = child,
            .command = owned_command,
        });
        stored = true;

        var stdout = std.Io.File.stdout().writerStreaming(self.io, &.{});
        try stdout.interface.print("[{d}] {d}\n", .{ job_number, childIdForDisplay(&child) });
    }

    fn spawnBackgroundProcess(self: *Shell, command_line: []const u8) !std.process.Child {
        if (!hasUnquotedPipe(command_line)) {
            var parsed = try parseCommand(self.allocator, command_line);
            defer parsed.deinit();

            if (parsed.argv.items.len > 0 and !parsed.hasRedirection()) {
                if (try self.findExecutable(parsed.argv.items[0])) |executable| {
                    defer self.allocator.free(executable);

                    var argv: std.ArrayList([]const u8) = .empty;
                    defer argv.deinit(self.allocator);
                    try argv.append(self.allocator, executable);
                    for (parsed.argv.items[1..]) |arg| {
                        try argv.append(self.allocator, arg);
                    }

                    return try std.process.spawn(self.io, .{
                        .argv = argv.items,
                        .environ_map = self.env,
                    });
                }
            }
        }

        return try self.spawnSystemShell(command_line);
    }

    fn nextJobNumber(self: *Shell) usize {
        var number: usize = 1;
        for (self.background_jobs.items) |job| {
            if (job.number == number) {
                number += 1;
            } else if (job.number > number) {
                break;
            }
        }
        return number;
    }

    fn insertBackgroundJob(self: *Shell, job: BackgroundJob) !void {
        try self.background_jobs.append(self.allocator, job);

        var index = self.background_jobs.items.len - 1;
        while (index > 0 and self.background_jobs.items[index].number < self.background_jobs.items[index - 1].number) : (index -= 1) {
            std.mem.swap(BackgroundJob, &self.background_jobs.items[index], &self.background_jobs.items[index - 1]);
        }
    }

    fn jobsCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        self.refreshBackgroundJobs();
        if (hasArg(argv, "--json")) {
            try self.printJobsJson(stdout_buffer);
            self.removeDoneJobs();
            return;
        }

        try self.printJobs(stdout_buffer);
        self.removeDoneJobs();
    }

    fn jobControlCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) !void {
        const command = argv[0];
        self.refreshBackgroundJobs();

        if (std.mem.eql(u8, command, "wait")) {
            try self.waitCommand(argv, stdout_buffer, stderr_buffer);
        } else if (std.mem.eql(u8, command, "kill")) {
            try self.killCommand(argv, stdout_buffer, stderr_buffer);
        } else if (std.mem.eql(u8, command, "disown")) {
            try self.disownCommand(argv, stdout_buffer, stderr_buffer);
        } else if (std.mem.eql(u8, command, "fg")) {
            try self.fgCommand(argv, stdout_buffer, stderr_buffer);
        } else if (std.mem.eql(u8, command, "bg")) {
            try self.bgCommand(argv, stdout_buffer, stderr_buffer);
        }
    }

    fn waitCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) !void {
        _ = stdout_buffer;
        if (argv.len == 1) {
            while (self.background_jobs.items.len > 0) {
                self.last_status = try self.waitJobAtIndex(0);
            }
            return;
        }

        var status: u8 = 0;
        for (argv[1..]) |spec| {
            const index = self.findJobIndexBySpec(spec) orelse {
                try appendFmt(self.allocator, stderr_buffer, "wait: {s}: no such job\n", .{spec});
                status = 127;
                continue;
            };
            status = try self.waitJobAtIndex(index);
        }
        self.last_status = status;
    }

    fn killCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) !void {
        _ = stdout_buffer;
        if (argv.len < 2) {
            try stderr_buffer.appendSlice(self.allocator, "kill: usage: kill [-SIGNAL] %JOB|PID ...\n");
            self.last_status = 2;
            return;
        }

        var signal: []const u8 = "";
        var index: usize = 1;
        if (argv[index].len > 1 and argv[index][0] == '-') {
            signal = argv[index][1..];
            index += 1;
        }
        if (index >= argv.len) {
            try stderr_buffer.appendSlice(self.allocator, "kill: missing job or pid\n");
            self.last_status = 2;
            return;
        }

        var status: u8 = 0;
        while (index < argv.len) : (index += 1) {
            const target = argv[index];
            if (std.mem.startsWith(u8, target, "%")) {
                const job_index = self.findJobIndexBySpec(target) orelse {
                    try appendFmt(self.allocator, stderr_buffer, "kill: {s}: no such job\n", .{target});
                    status = 127;
                    continue;
                };
                var removed = self.background_jobs.orderedRemove(job_index);
                removed.child.kill(self.io);
                self.allocator.free(removed.command);
                continue;
            }

            if (!isDecimalNumber(target)) {
                try appendFmt(self.allocator, stderr_buffer, "kill: {s}: expected %%JOB or PID\n", .{target});
                status = 2;
                continue;
            }
            const term = self.killPid(target, signal) catch |err| {
                try appendFmt(self.allocator, stderr_buffer, "kill: {s}: {s}\n", .{ target, @errorName(err) });
                status = 1;
                continue;
            };
            if (termExitCode(term) != 0) status = termExitCode(term);
        }
        self.last_status = status;
    }

    fn disownCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) !void {
        _ = stdout_buffer;
        if (self.background_jobs.items.len == 0) {
            if (argv.len == 1) try stderr_buffer.appendSlice(self.allocator, "disown: no current job\n");
            self.last_status = if (argv.len == 1) 1 else 0;
            return;
        }

        if (argv.len == 1) {
            self.disownJobAtIndex(self.currentJobIndex().?);
            self.last_status = 0;
            return;
        }

        var status: u8 = 0;
        var arg_index: usize = 1;
        while (arg_index < argv.len) : (arg_index += 1) {
            const job_index = self.findJobIndexBySpec(argv[arg_index]) orelse {
                try appendFmt(self.allocator, stderr_buffer, "disown: {s}: no such job\n", .{argv[arg_index]});
                status = 127;
                continue;
            };
            self.disownJobAtIndex(job_index);
        }
        self.last_status = status;
    }

    fn fgCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) !void {
        const spec = if (argv.len >= 2) argv[1] else "%%";
        const index = self.findJobIndexBySpec(spec) orelse {
            try appendFmt(self.allocator, stderr_buffer, "fg: {s}: no such job\n", .{spec});
            self.last_status = 127;
            return;
        };
        try appendFmt(self.allocator, stdout_buffer, "{s}\n", .{self.background_jobs.items[index].command});
        self.last_status = try self.waitJobAtIndex(index);
    }

    fn bgCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) !void {
        const spec = if (argv.len >= 2) argv[1] else "%%";
        const index = self.findJobIndexBySpec(spec) orelse {
            try appendFmt(self.allocator, stderr_buffer, "bg: {s}: no such job\n", .{spec});
            self.last_status = 127;
            return;
        };
        try self.appendJobLine(stdout_buffer, &self.background_jobs.items[index]);
        self.last_status = 0;
    }

    fn waitJobAtIndex(self: *Shell, index: usize) !u8 {
        var removed = self.background_jobs.orderedRemove(index);
        defer self.allocator.free(removed.command);
        if (removed.child.id == null) return 0;
        const term = try removed.child.wait(self.io);
        return termExitCode(term);
    }

    fn disownJobAtIndex(self: *Shell, index: usize) void {
        const removed = self.background_jobs.orderedRemove(index);
        self.allocator.free(removed.command);
    }

    fn findJobIndexBySpec(self: *Shell, spec: []const u8) ?usize {
        if (std.mem.eql(u8, spec, "%%") or std.mem.eql(u8, spec, "%+")) return self.currentJobIndex();
        if (std.mem.eql(u8, spec, "%-")) return self.previousJobIndex();

        const number_text = if (std.mem.startsWith(u8, spec, "%")) spec[1..] else spec;
        const number = std.fmt.parseInt(usize, number_text, 10) catch return null;
        for (self.background_jobs.items, 0..) |job, index| {
            if (job.number == number) return index;
        }
        return null;
    }

    fn currentJobIndex(self: *Shell) ?usize {
        var result: ?usize = null;
        for (self.background_jobs.items, 0..) |job, index| {
            if (result == null or job.number > self.background_jobs.items[result.?].number) result = index;
        }
        return result;
    }

    fn previousJobIndex(self: *Shell) ?usize {
        const current = self.currentJobIndex() orelse return null;
        var result: ?usize = null;
        for (self.background_jobs.items, 0..) |job, index| {
            if (index == current) continue;
            if (result == null or job.number > self.background_jobs.items[result.?].number) result = index;
        }
        return result;
    }

    fn killPid(self: *Shell, pid: []const u8, signal: []const u8) !std.process.Child.Term {
        const result = if (builtin.os.tag == .windows) result: {
            var argv = [_][]const u8{ "taskkill", "/PID", pid, "/T", "/F" };
            break :result try std.process.run(self.allocator, self.io, .{
                .argv = &argv,
                .environ_map = self.env,
                .stdout_limit = .limited(32 * 1024),
                .stderr_limit = .limited(32 * 1024),
            });
        } else result: {
            var argv_with_signal = [_][]const u8{ "kill", "", pid };
            var argv_plain = [_][]const u8{ "kill", pid };
            const argv = if (signal.len > 0) blk: {
                argv_with_signal[1] = try std.fmt.allocPrint(self.allocator, "-{s}", .{signal});
                break :blk &argv_with_signal;
            } else &argv_plain;
            defer if (signal.len > 0) self.allocator.free(argv_with_signal[1]);
            break :result try std.process.run(self.allocator, self.io, .{
                .argv = argv,
                .environ_map = self.env,
                .stdout_limit = .limited(32 * 1024),
                .stderr_limit = .limited(32 * 1024),
            });
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        return result.term;
    }

    fn printJobs(self: *Shell, stdout_buffer: *std.ArrayList(u8)) !void {
        for (self.background_jobs.items) |*job| {
            try self.appendJobLine(stdout_buffer, job);
        }
    }

    fn printJobsJson(self: *Shell, stdout_buffer: *std.ArrayList(u8)) !void {
        for (self.background_jobs.items) |*job| {
            try appendFmt(self.allocator, stdout_buffer, "{{\"number\":{d},\"status\":\"{s}\",\"marker\":\"{c}\",\"command\":", .{
                job.number,
                if (job.done) "done" else "running",
                self.jobMarker(job.number),
            });
            try appendJsonString(self.allocator, stdout_buffer, job.command);
            try stdout_buffer.appendSlice(self.allocator, "}\n");
        }
    }

    fn reapAndPrintDoneJobs(self: *Shell) !void {
        self.refreshBackgroundJobs();

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        for (self.background_jobs.items) |*job| {
            if (job.done) try self.appendJobLine(&output, job);
        }

        if (output.items.len > 0) {
            var stdout = std.Io.File.stdout().writerStreaming(self.io, &.{});
            try stdout.interface.writeAll(output.items);
        }

        self.removeDoneJobs();
    }

    fn refreshBackgroundJobs(self: *Shell) void {
        for (self.background_jobs.items) |*job| {
            if (!job.done and childHasExited(&job.child, self.io)) job.done = true;
        }
    }

    fn removeDoneJobs(self: *Shell) void {
        var index: usize = 0;
        while (index < self.background_jobs.items.len) {
            if (self.background_jobs.items[index].done) {
                const removed = self.background_jobs.orderedRemove(index);
                self.allocator.free(removed.command);
            } else {
                index += 1;
            }
        }
    }

    fn appendJobLine(self: *Shell, buffer: *std.ArrayList(u8), job: *const BackgroundJob) !void {
        const marker = self.jobMarker(job.number);
        const status = if (job.done) "Done" else "Running";
        try appendFmt(self.allocator, buffer, "[{d}]{c}  {s}", .{ job.number, marker, status });

        var padding = if (status.len < 24) 24 - status.len else 1;
        while (padding > 0) : (padding -= 1) {
            try buffer.append(self.allocator, ' ');
        }

        try buffer.appendSlice(self.allocator, job.command);
        if (!job.done) try buffer.appendSlice(self.allocator, " &");
        try buffer.append(self.allocator, '\n');
    }

    fn jobMarker(self: *Shell, number: usize) u8 {
        var newest: ?usize = null;
        var previous: ?usize = null;

        for (self.background_jobs.items) |job| {
            if (newest == null or job.number > newest.?) {
                previous = newest;
                newest = job.number;
            } else if (previous == null or job.number > previous.?) {
                previous = job.number;
            }
        }

        if (newest != null and number == newest.?) return '+';
        if (previous != null and number == previous.?) return '-';
        return ' ';
    }

    fn inspectLine(self: *Shell, line: []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (line.len == 0) {
            try stdout_buffer.appendSlice(self.allocator, "inspect: provide a command line to inspect\n");
            return;
        }

        try appendFmt(self.allocator, stdout_buffer, "line: {s}\n", .{line});
        if (hasUnquotedPipe(line)) {
            try appendFmt(self.allocator, stdout_buffer, "pipeline: {s}\n", .{if (isComplexPipelineSyntax(line)) "system-shell fallback" else "native simple pipeline"});
            var segments: std.ArrayList([]u8) = .empty;
            defer {
                for (segments.items) |segment| self.allocator.free(segment);
                segments.deinit(self.allocator);
            }
            splitUnquotedPipes(self.allocator, line, &segments) catch |err| switch (err) {
                error.UnsupportedPipelineStage => {
                    try stdout_buffer.appendSlice(self.allocator, "reason: invalid or incomplete pipeline\n");
                    return;
                },
                else => |e| return e,
            };
            for (segments.items, 0..) |segment, index| {
                try appendFmt(self.allocator, stdout_buffer, "stage {d}: {s}\n", .{ index + 1, segment });
                try self.inspectParsedCommand(segment, stdout_buffer);
            }
            return;
        }

        try stdout_buffer.appendSlice(self.allocator, "pipeline: none\n");
        try self.inspectParsedCommand(line, stdout_buffer);
    }

    fn inspectParsedCommand(self: *Shell, line: []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        var parsed = try parseCommandExpanded(self.allocator, line, self);
        defer parsed.deinit();

        try stdout_buffer.appendSlice(self.allocator, "  argv:");
        for (parsed.argv.items) |arg| {
            try stdout_buffer.append(self.allocator, ' ');
            try appendSingleQuoted(self.allocator, stdout_buffer, arg);
        }
        try stdout_buffer.append(self.allocator, '\n');

        if (parsed.argv.items.len > 0) {
            const command = parsed.argv.items[0];
            if (isShellBuiltin(command)) {
                try stdout_buffer.appendSlice(self.allocator, "  resolves: builtin\n");
            } else if (try self.findExecutable(command)) |path| {
                defer self.allocator.free(path);
                try appendFmt(self.allocator, stdout_buffer, "  resolves: {s}\n", .{path});
            } else {
                try stdout_buffer.appendSlice(self.allocator, "  resolves: missing\n");
            }
        }

        if (parsed.stdout_redirect) |redirect| {
            try appendFmt(self.allocator, stdout_buffer, "  stdout: {s} {s}\n", .{ if (redirect.append) "append" else "write", redirect.path });
        }
        if (parsed.stderr_redirect) |redirect| {
            try appendFmt(self.allocator, stdout_buffer, "  stderr: {s} {s}\n", .{ if (redirect.append) "append" else "write", redirect.path });
        }
    }

    fn completeBuiltin(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (hasArg(argv, "-h") or hasArg(argv, "--help")) {
            try stdout_buffer.appendSlice(self.allocator,
                \\Usage: complete [-h] [--help] [-c CMD [-a CANDIDATES] [-d DESC]] [-p CMD] [-r CMD] [-C SPEC CMD]
                \\
                \\Register completions for command arguments.
                \\  -h, --help              Show this help message
                \\  -c CMD -a CANDIDATES     Add completion candidates for CMD (space-separated list)
                \\  -d DESC                 Description for the completion candidates
                \\  -p CMD                  Print completions for CMD
                \\  -r CMD                  Remove completions for CMD
                \\  -C SPEC CMD             Register a programmable completer for CMD
                \\
            );
            return;
        }
        if (argv.len >= 3 and std.mem.eql(u8, argv[1], "-c")) {
            const command = argv[2];
            var candidate: ?[]const u8 = null;
            var description: []const u8 = "";
            var index: usize = 3;
            while (index < argv.len) : (index += 1) {
                if (std.mem.eql(u8, argv[index], "-a") and index + 1 < argv.len) {
                    candidate = argv[index + 1];
                    index += 1;
                } else if (std.mem.eql(u8, argv[index], "-d") and index + 1 < argv.len) {
                    description = argv[index + 1];
                    index += 1;
                }
            }

            if (candidate) |items| {
                var parts = std.mem.splitScalar(u8, items, ' ');
                while (parts.next()) |part| {
                    if (part.len > 0) try self.putCompletionCandidate(command, part, description);
                }
            } else {
                try self.printDeclarativeCompletions(command, stdout_buffer);
            }
            return;
        }

        if (argv.len >= 3 and std.mem.eql(u8, argv[1], "-p")) {
            const command = argv[2];
            if (self.findCompletionSpec(command)) |spec| {
                try appendFmt(self.allocator, stdout_buffer, "complete -C '{s}' {s}\n", .{ spec.completer, spec.command });
            }
            if (self.hasDeclarativeCompletions(command)) {
                try self.printDeclarativeCompletions(command, stdout_buffer);
            }
            if (self.findCompletionSpec(command) == null and !self.hasDeclarativeCompletions(command)) {
                try appendFmt(self.allocator, stdout_buffer, "complete: {s}: no completion specification\n", .{command});
            }
            return;
        }

        if (argv.len >= 4 and std.mem.eql(u8, argv[1], "-C")) {
            try self.putCompletionSpec(argv[3], argv[2]);
            return;
        }

        if (argv.len >= 3 and std.mem.eql(u8, argv[1], "-r")) {
            self.removeCompletionSpec(argv[2]);
            self.removeCompletionCandidates(argv[2]);
            return;
        }
    }

    fn findCompletionSpec(self: *Shell, command: []const u8) ?*CompletionSpec {
        for (self.completion_specs.items) |*spec| {
            if (std.mem.eql(u8, spec.command, command)) return spec;
        }
        return null;
    }

    fn putCompletionSpec(self: *Shell, command: []const u8, completer: []const u8) !void {
        if (self.findCompletionSpec(command)) |spec| {
            const new_completer = try self.allocator.dupe(u8, completer);
            self.allocator.free(spec.completer);
            spec.completer = new_completer;
            return;
        }

        const owned_command = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_command);
        const owned_completer = try self.allocator.dupe(u8, completer);
        errdefer self.allocator.free(owned_completer);
        try self.completion_specs.append(self.allocator, .{
            .command = owned_command,
            .completer = owned_completer,
        });
    }

    fn removeCompletionSpec(self: *Shell, command: []const u8) void {
        for (self.completion_specs.items, 0..) |spec, index| {
            if (std.mem.eql(u8, spec.command, command)) {
                const removed = self.completion_specs.orderedRemove(index);
                self.allocator.free(removed.command);
                self.allocator.free(removed.completer);
                return;
            }
        }
    }

    fn hasDeclarativeCompletions(self: *Shell, command: []const u8) bool {
        for (self.completion_candidates.items) |candidate| {
            if (std.mem.eql(u8, candidate.command, command)) return true;
        }
        return false;
    }

    fn putCompletionCandidate(self: *Shell, command: []const u8, candidate: []const u8, description: []const u8) !void {
        return self.putCompletionCandidateWithOptions(command, candidate, description, "");
    }

    fn putCompletionCandidateWithOptions(self: *Shell, command: []const u8, candidate: []const u8, description: []const u8, options: []const u8) !void {
        for (self.completion_candidates.items) |*existing| {
            if (std.mem.eql(u8, existing.command, command) and std.mem.eql(u8, existing.candidate, candidate)) {
                const owned_description = try self.allocator.dupe(u8, description);
                self.allocator.free(existing.description);
                existing.description = owned_description;
                return;
            }
        }

        const owned_command = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_command);
        const owned_candidate = try self.allocator.dupe(u8, candidate);
        errdefer self.allocator.free(owned_candidate);
        const owned_description = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(owned_description);
        const owned_options = try self.allocator.dupe(u8, options);
        errdefer self.allocator.free(owned_options);
        try self.completion_candidates.append(self.allocator, .{
            .command = owned_command,
            .candidate = owned_candidate,
            .description = owned_description,
            .options = owned_options,
        });
    }

    /// Returns true if any candidate for `command` has `arg_index` in its options.
    fn candidateMatchesPosition(candidate: *const CompletionCandidateSpec, arg_index: usize) bool {
        if (candidate.options.len == 0) return arg_index == 0;
        // Parse "0 1 2 ..." format
        var parts = std.mem.splitScalar(u8, candidate.options, ' ');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            const index = std.fmt.parseInt(usize, part, 10) catch continue;
            if (index == arg_index) return true;
        }
        return false;
    }

    fn removeCompletionCandidates(self: *Shell, command: []const u8) void {
        var index: usize = 0;
        while (index < self.completion_candidates.items.len) {
            if (std.mem.eql(u8, self.completion_candidates.items[index].command, command)) {
                const removed = self.completion_candidates.orderedRemove(index);
                self.allocator.free(removed.command);
                self.allocator.free(removed.candidate);
                self.allocator.free(removed.description);
            } else {
                index += 1;
            }
        }
    }

    fn addDeclarativeCompletionMatches(self: *Shell, matches: *std.ArrayList([]u8), command: []const u8, prefix: []const u8) !void {
        for (self.completion_candidates.items) |candidate| {
            if (!std.mem.eql(u8, candidate.command, command)) continue;
            try self.addCompletionMatch(matches, prefix, candidate.candidate);
        }
    }

    fn completionCandidateDescription(self: *Shell, command: []const u8, name: []const u8) ?[]const u8 {
        for (self.completion_candidates.items) |candidate| {
            if (std.mem.eql(u8, candidate.command, command) and std.mem.eql(u8, candidate.candidate, name)) {
                if (candidate.description.len > 0) return candidate.description;
                return "declared completion";
            }
        }
        return null;
    }

    fn printDeclarativeCompletions(self: *Shell, command: []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        for (self.completion_candidates.items) |candidate| {
            if (!std.mem.eql(u8, candidate.command, command)) continue;
            try appendFmt(self.allocator, stdout_buffer, "complete -c {s} -a {s}", .{ candidate.command, candidate.candidate });
            if (candidate.description.len > 0) {
                try appendFmt(self.allocator, stdout_buffer, " -d ", .{});
                try appendSingleQuoted(self.allocator, stdout_buffer, candidate.description);
            }
            try stdout_buffer.append(self.allocator, '\n');
        }
    }

    fn emitCommandOutput(self: *Shell, parsed: *const ParsedCommand, stdout_bytes: []const u8, stderr_bytes: []const u8) !void {
        if (parsed.stdout_redirect) |redirect| {
            try self.writeRedirect(redirect, stdout_bytes);
        } else if (stdout_bytes.len > 0) {
            var stdout = std.Io.File.stdout().writerStreaming(self.io, &.{});
            try stdout.interface.writeAll(stdout_bytes);
        }

        if (parsed.stderr_redirect) |redirect| {
            try self.writeRedirect(redirect, stderr_bytes);
        } else if (stderr_bytes.len > 0) {
            var stderr = std.Io.File.stderr().writerStreaming(self.io, &.{});
            try stderr.interface.writeAll(stderr_bytes);
        }
    }

    fn writeRedirect(self: *Shell, redirect: Redirection, bytes: []const u8) !void {
        // fd-dup redirections (e.g. `2>&1`) have no file path; external commands
        // have their dup semantics fulfilled by the system shell.  For builtin
        // commands there is no fd-level control, so dup redirections are silently
        // ignored here and bytes are dropped.  This is an intentional best-effort
        // limitation of the builtin-output path; full dup semantics require OS
        // fd plumbing that is out of scope.
        if (redirect.dup_source != null) return;
        if (!redirect.append) {
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = redirect.path, .data = bytes });
            return;
        }

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        const existing_file = std.Io.Dir.cwd().openFile(self.io, redirect.path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        };
        if (existing_file) |file| {
            defer file.close(self.io);
            var read_buffer: [4096]u8 = undefined;
            var reader = file.readerStreaming(self.io, &read_buffer);
            const existing = try reader.interface.allocRemaining(self.allocator, .limited(max_history_file_bytes));
            defer self.allocator.free(existing);
            try output.appendSlice(self.allocator, existing);
        }

        try output.appendSlice(self.allocator, bytes);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = redirect.path, .data = output.items });
    }

    fn runViaSystemShell(self: *Shell, line: []const u8) !void {
        var child = try self.spawnSystemShell(line);
        const term = try child.wait(self.io);
        self.last_status = termExitCode(term);
    }

    fn tryRunNativePipeline(self: *Shell, line: []const u8) !bool {
        if (isComplexPipelineSyntax(line)) return false;

        var segments: std.ArrayList([]u8) = .empty;
        defer {
            for (segments.items) |segment| self.allocator.free(segment);
            segments.deinit(self.allocator);
        }
        splitUnquotedPipes(self.allocator, line, &segments) catch |err| switch (err) {
            error.UnsupportedPipelineStage => return false,
            else => |e| return e,
        };
        if (segments.items.len < 2) return false;

        // Pre-validate every stage before running ANY of them. If a later
        // stage has a redirection (or is empty) we must fall back to the
        // system shell — but discovering that mid-run, after earlier stages
        // already spawned, then re-running the whole line under /bin/sh would
        // double-execute the non-idempotent earlier stages (e.g. the `rm f`
        // in `rm f | grep x > out`). Command substitution can't reach here
        // (isComplexPipelineSyntax rejects `$(`/backticks) and variable
        // expansion is side-effect-free, so this extra parse is pure.
        for (segments.items) |segment| {
            var probe = try parseCommandExpanded(self.allocator, segment, self);
            defer probe.deinit();
            if (probe.argv.items.len == 0 or probe.hasRedirection()) return false;
        }

        var input = try self.allocator.dupe(u8, "");
        defer self.allocator.free(input);
        var stderr_output: std.ArrayList(u8) = .empty;
        defer stderr_output.deinit(self.allocator);

        var status: u8 = 0;
        for (segments.items) |segment| {
            var parsed = try parseCommandExpanded(self.allocator, segment, self);
            defer parsed.deinit();
            if (parsed.argv.items.len == 0 or parsed.hasRedirection()) {
                return false;
            }

            const result = self.runPipelineStage(&parsed, input) catch |err| switch (err) {
                error.FileNotFound => {
                    try appendFmt(self.allocator, &stderr_output, "{s}: command not found\n", .{parsed.argv.items[0]});
                    self.allocator.free(input);
                    input = try self.allocator.dupe(u8, "");
                    status = 127;
                    continue;
                },
                error.UnsupportedPipelineStage => return false,
                error.PipelineOutputTooLarge => {
                    try appendFmt(self.allocator, &stderr_output, "{s}: pipeline output exceeded {d} bytes\n", .{ parsed.argv.items[0], max_pipeline_capture_bytes });
                    self.allocator.free(input);
                    input = try self.allocator.dupe(u8, "");
                    status = 1;
                    continue;
                },
                else => |e| return e,
            };
            defer result.deinit(self.allocator);

            self.allocator.free(input);
            input = try self.allocator.dupe(u8, result.stdout);
            try stderr_output.appendSlice(self.allocator, result.stderr);
            status = result.status;
        }

        var stdout = std.Io.File.stdout().writerStreaming(self.io, &.{});
        try stdout.interface.writeAll(input);
        var stderr = std.Io.File.stderr().writerStreaming(self.io, &.{});
        try stderr.interface.writeAll(stderr_output.items);
        self.last_status = status;
        return true;
    }

    fn runPipelineStage(self: *Shell, parsed: *const ParsedCommand, input: []const u8) !PipelineStageResult {
        const command = parsed.argv.items[0];
        if (std.mem.eql(u8, command, "echo")) {
            var output: std.ArrayList(u8) = .empty;
            errdefer output.deinit(self.allocator);
            try self.echoCommand(parsed.argv.items, &output);
            return .{
                .stdout = try output.toOwnedSlice(self.allocator),
                .stderr = try self.allocator.dupe(u8, ""),
                .status = 0,
            };
        }
        if (std.mem.eql(u8, command, "pwd")) {
            var output: std.ArrayList(u8) = .empty;
            errdefer output.deinit(self.allocator);
            try self.printWorkingDirectory(&output);
            return .{
                .stdout = try output.toOwnedSlice(self.allocator),
                .stderr = try self.allocator.dupe(u8, ""),
                .status = 0,
            };
        }
        if (isShellBuiltin(command)) return error.UnsupportedPipelineStage;

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        for (parsed.argv.items) |arg| try argv.append(self.allocator, arg);

        var temp_input: ?PipelineInputFile = null;
        defer if (temp_input) |temp| {
            temp.file.close(self.io);
            std.Io.Dir.cwd().deleteFile(self.io, temp.path) catch {};
            self.allocator.free(temp.path);
        };

        if (input.len > max_pipeline_stage_input_bytes) {
            temp_input = try self.createPipelineInputFile(input);
        }

        var child = try std.process.spawn(self.io, .{
            .argv = argv.items,
            .environ_map = self.env,
            .stdin = if (temp_input) |temp| .{ .file = temp.file } else if (input.len > 0) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        defer child.kill(self.io);

        if (temp_input == null and input.len > 0) {
            var stdin_file = child.stdin.?;
            try stdin_file.writeStreamingAll(self.io, input);
            stdin_file.close(self.io);
            child.stdin = null;
        }

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(self.allocator, self.io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer multi_reader.deinit();

        const stdout_reader = multi_reader.reader(0);
        const stderr_reader = multi_reader.reader(1);

        while (multi_reader.fill(4096, .none)) |_| {
            if (stdout_reader.buffered().len > max_pipeline_capture_bytes) return error.PipelineOutputTooLarge;
            if (stderr_reader.buffered().len > max_pipeline_capture_bytes) return error.PipelineOutputTooLarge;
        } else |err| {
            switch (err) {
                error.EndOfStream => {},
                else => return err,
            }
        }

        try multi_reader.checkAnyError();

        const term = try child.wait(self.io);

        const stdout_bytes = try multi_reader.toOwnedSlice(0);
        errdefer self.allocator.free(stdout_bytes);
        const stderr_bytes = try multi_reader.toOwnedSlice(1);
        errdefer self.allocator.free(stderr_bytes);

        return .{
            .stdout = stdout_bytes,
            .stderr = stderr_bytes,
            .status = termExitCode(term),
        };
    }

    fn createPipelineInputFile(self: *Shell, input: []const u8) !PipelineInputFile {
        const root = pipelineTempRoot(self.env);
        var attempts: usize = 0;
        while (attempts < 16) : (attempts += 1) {
            var random_bytes: [12]u8 = undefined;
            self.io.random(&random_bytes);
            const hex = std.fmt.bytesToHex(random_bytes, .lower);
            const name = try std.fmt.allocPrint(self.allocator, "ziggyzag-pipe-{s}.tmp", .{hex[0..]});
            defer self.allocator.free(name);

            const path = try std.fs.path.join(self.allocator, &.{ root, name });
            errdefer self.allocator.free(path);

            var write_file = std.Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    self.allocator.free(path);
                    continue;
                },
                else => |e| return e,
            };
            var write_file_closed = false;
            defer if (!write_file_closed) write_file.close(self.io);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, path) catch {};

            try write_file.writeStreamingAll(self.io, input);
            write_file.close(self.io);
            write_file_closed = true;

            const read_file = try std.Io.Dir.cwd().openFile(self.io, path, .{ .allow_directory = false });
            return .{
                .path = path,
                .file = read_file,
            };
        }

        return error.PathAlreadyExists;
    }

    fn spawnSystemShell(self: *Shell, line: []const u8) !std.process.Child {
        if (builtin.os.tag == .windows) {
            var argv = [_][]const u8{ "cmd", "/C", line };
            return try std.process.spawn(self.io, .{
                .argv = &argv,
                .environ_map = self.env,
            });
        } else {
            var argv = [_][]const u8{ "/bin/sh", "-c", line };
            return try std.process.spawn(self.io, .{
                .argv = &argv,
                .environ_map = self.env,
            });
        }
    }

    fn findExecutable(self: *Shell, command: []const u8) !?[]u8 {
        const contains_path_separator = std.mem.indexOfScalar(u8, command, '/') != null or
            (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, command, '\\') != null);
        if (contains_path_separator) {
            if (try self.pathIsExecutable(command)) return try self.allocator.dupe(u8, command);
            if (builtin.os.tag == .windows) {
                if (try self.findWindowsPathextExecutable(null, command)) |path| return path;
            }
            return null;
        }

        const path_value = self.env.get("PATH") orelse "";
        const separator: u8 = if (builtin.os.tag == .windows) ';' else ':';
        var dirs = std.mem.splitScalar(u8, path_value, separator);
        while (dirs.next()) |dir| {
            if (dir.len == 0) continue;
            const full_path = try std.fs.path.join(self.allocator, &.{ dir, command });
            if (try self.pathIsExecutable(full_path)) return full_path;
            self.allocator.free(full_path);
            if (builtin.os.tag == .windows) {
                if (try self.findWindowsPathextExecutable(dir, command)) |path| return path;
            }
        }

        return null;
    }

    fn findWindowsPathextExecutable(self: *Shell, dir: ?[]const u8, command: []const u8) !?[]u8 {
        if (hasWindowsExecutableExtension(command)) return null;
        const pathext = self.env.get("PATHEXT") orelse ".COM;.EXE;.BAT;.CMD";
        var extensions = std.mem.splitScalar(u8, pathext, ';');
        while (extensions.next()) |raw_ext| {
            if (raw_ext.len == 0) continue;
            const ext = if (raw_ext[0] == '.') raw_ext else try std.fmt.allocPrint(self.allocator, ".{s}", .{raw_ext});
            const owned_ext = raw_ext.len == 0 or raw_ext[0] != '.';
            defer if (owned_ext) self.allocator.free(ext);

            const candidate_name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ command, ext });
            defer self.allocator.free(candidate_name);
            const full_path = if (dir) |path|
                try std.fs.path.join(self.allocator, &.{ path, candidate_name })
            else
                try self.allocator.dupe(u8, candidate_name);
            if (try self.pathIsExecutable(full_path)) return full_path;
            self.allocator.free(full_path);
        }
        return null;
    }

    fn pathIsExecutable(self: *Shell, path: []const u8) !bool {
        const file = if (std.fs.path.isAbsolute(path))
            std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return false
        else
            std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return false;
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        if (stat.kind != .file) return false;
        if (!std.Io.File.Permissions.has_executable_bit) return true;
        return stat.permissions.toMode() & 0o111 != 0;
    }
};

const TerminalMode = if (builtin.os.tag == .windows) struct {
    const Self = @This();

    // ConPTY runs a console client in cooked line-input mode by default
    // (ENABLE_LINE_INPUT|ENABLE_ECHO_INPUT|ENABLE_PROCESSED_INPUT). ZiggyZag's
    // `readLine` is a raw-mode reader — it does its own line editing and
    // (when manual_echo is set) its own echo, and submits on `\n`. Without
    // switching the console to raw VT mode the cooked layer buffers input
    // until CR and the shell's stdin reader never sees a submitted line, so
    // typed commands never run under the Windows desktop host. This is the
    // Windows equivalent of the POSIX termios raw-mode path below.
    // See docs/reviews/2026-05-17-windows-debug.md.
    const BOOL = i32;
    const DWORD = u32;
    const HANDLE = std.os.windows.HANDLE;
    const INVALID_HANDLE_VALUE = std.os.windows.INVALID_HANDLE_VALUE;

    // GetStdHandle pseudo-handle ids (winbase.h: (DWORD)-10 / (DWORD)-11).
    const STD_INPUT_HANDLE: DWORD = 0xFFFF_FFF6;
    const STD_OUTPUT_HANDLE: DWORD = 0xFFFF_FFF5;

    const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
    const ENABLE_LINE_INPUT: DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: DWORD = 0x0004;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
    const COOKED_INPUT: DWORD = ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT;

    const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
    const DISABLE_NEWLINE_AUTO_RETURN: DWORD = 0x0008;

    extern "kernel32" fn GetStdHandle(id: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetConsoleMode(handle: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleMode(handle: HANDLE, mode: DWORD) callconv(.winapi) BOOL;

    stdin_handle: HANDLE,
    stdin_original_mode: DWORD,
    stdout_handle: ?HANDLE,
    stdout_original_mode: DWORD,

    fn enable() !?Self {
        const stdin = GetStdHandle(STD_INPUT_HANDLE) orelse return null;
        if (stdin == INVALID_HANDLE_VALUE) return null;

        var stdin_mode: DWORD = 0;
        // GetConsoleMode fails when the handle is a pipe/file rather than a
        // console — i.e. not a terminal. Mirror the POSIX `NotATerminal`
        // branch and degrade gracefully instead of erroring.
        if (GetConsoleMode(stdin, &stdin_mode) == 0) return null;

        const stdout = GetStdHandle(STD_OUTPUT_HANDLE);
        var stdout_mode: DWORD = 0;
        const stdout_console: ?HANDLE = if (stdout) |h|
            (if (h != INVALID_HANDLE_VALUE and GetConsoleMode(h, &stdout_mode) != 0) h else null)
        else
            null;

        const raw_stdin = (stdin_mode & ~COOKED_INPUT) | ENABLE_VIRTUAL_TERMINAL_INPUT;
        if (SetConsoleMode(stdin, raw_stdin) == 0) return error.SetConsoleModeFailed;

        // Output-side VT processing is nice-to-have (the desktop/ConPTY
        // renders the shell's VT regardless); best-effort with a fallback,
        // never fatal.
        if (stdout_console) |h| {
            const full_out = stdout_mode | ENABLE_PROCESSED_OUTPUT |
                ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN;
            if (SetConsoleMode(h, full_out) == 0) {
                _ = SetConsoleMode(h, stdout_mode | ENABLE_PROCESSED_OUTPUT |
                    ENABLE_VIRTUAL_TERMINAL_PROCESSING);
            }
        }

        return .{
            .stdin_handle = stdin,
            .stdin_original_mode = stdin_mode,
            .stdout_handle = stdout_console,
            .stdout_original_mode = stdout_mode,
        };
    }

    fn restore(self: Self) void {
        // Best-effort, mirroring the POSIX `tcsetattr ... catch {}`.
        _ = SetConsoleMode(self.stdin_handle, self.stdin_original_mode);
        if (self.stdout_handle) |h| _ = SetConsoleMode(h, self.stdout_original_mode);
    }
} else struct {
    const Self = @This();

    fd: std.posix.fd_t,
    original: std.posix.termios,

    fn enable() !?Self {
        const fd = std.posix.STDIN_FILENO;
        const original = std.posix.tcgetattr(fd) catch |err| switch (err) {
            error.NotATerminal => return null,
            else => |e| return e,
        };

        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(fd, .NOW, raw);

        return .{ .fd = fd, .original = original };
    }

    fn restore(self: Self) void {
        std.posix.tcsetattr(self.fd, .NOW, self.original) catch {};
    }
};

const Redirection = struct {
    path: []u8,
    append: bool,
    /// When set, this is an fd-dup redirection: the target fd is duplicated from
    /// the fd named by `dup_source` (e.g. `2>&1` means stderr ← stdout's dest).
    /// `path` is empty ("") and must NOT be freed when `dup_source` is non-null.
    dup_source: ?RedirectTarget = null,
};

const RedirectTarget = enum {
    stdout,
    stderr,
};

const RedirectionSpec = struct {
    target: RedirectTarget,
    append: bool,
    /// Non-null for `N>&M` / `>&M` dup forms.
    dup_source: ?RedirectTarget = null,
};

const ParsedCommand = struct {
    allocator: Allocator,
    argv: std.ArrayList([]u8),
    stdout_redirect: ?Redirection = null,
    stderr_redirect: ?Redirection = null,

    fn deinit(self: *ParsedCommand) void {
        for (self.argv.items) |arg| self.allocator.free(arg);
        self.argv.deinit(self.allocator);
        if (self.stdout_redirect) |redirect| self.allocator.free(redirect.path);
        if (self.stderr_redirect) |redirect| self.allocator.free(redirect.path);
    }

    fn hasRedirection(self: *const ParsedCommand) bool {
        return self.stdout_redirect != null or self.stderr_redirect != null;
    }

    fn extractRedirections(self: *ParsedCommand) !void {
        var argv: std.ArrayList([]u8) = .empty;

        // Validate: non-dup redirection operators must be followed by a path token.
        for (self.argv.items, 0..) |token, token_index| {
            if (parseRedirectionOperator(token)) |spec| {
                if (spec.dup_source == null and token_index + 1 >= self.argv.items.len) {
                    return error.MissingRedirectTarget;
                }
            }
        }

        var index: usize = 0;
        while (index < self.argv.items.len) {
            const token = self.argv.items[index];
            if (parseRedirectionOperator(token)) |spec| {
                self.allocator.free(token);
                if (spec.dup_source != null) {
                    // fd-dup: self-contained operator, no following path token.
                    // Path is unused (and not freed) for dup redirections.
                    const empty_path = try self.allocator.dupe(u8, "");
                    self.setRedirection(spec, empty_path);
                    index += 1;
                } else {
                    const path = self.argv.items[index + 1];
                    self.setRedirection(spec, path);
                    index += 2;
                }
                continue;
            }

            try argv.append(self.allocator, token);
            index += 1;
        }

        while (index < self.argv.items.len) : (index += 1) {
            self.allocator.free(self.argv.items[index]);
        }

        self.argv.deinit(self.allocator);
        self.argv = argv;
    }

    fn setRedirection(self: *ParsedCommand, spec: RedirectionSpec, path: []u8) void {
        const redirect: Redirection = .{ .path = path, .append = spec.append, .dup_source = spec.dup_source };
        switch (spec.target) {
            .stdout => {
                if (self.stdout_redirect) |old| self.allocator.free(old.path);
                self.stdout_redirect = redirect;
            },
            .stderr => {
                if (self.stderr_redirect) |old| self.allocator.free(old.path);
                self.stderr_redirect = redirect;
            },
        }
    }
};

fn parseCommand(allocator: Allocator, line: []const u8) !ParsedCommand {
    var parsed = try parseTokens(allocator, line, null);
    errdefer parsed.deinit();
    try parsed.extractRedirections();
    return parsed;
}

fn parseCommandExpanded(allocator: Allocator, line: []const u8, shell: *Shell) !ParsedCommand {
    var parsed = try parseTokens(allocator, line, shell);
    errdefer parsed.deinit();
    try parsed.extractRedirections();
    return parsed;
}

fn parseTokens(allocator: Allocator, line: []const u8, shell: ?*Shell) !ParsedCommand {
    var argv: std.ArrayList([]u8) = .empty;
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);

    // True once a quote has explicitly opened a word, so an empty quoted
    // string (`""`, `''`) or a quoted empty expansion (`"$UNSET"`) still emits
    // one empty argument instead of being silently dropped.
    var token_active: bool = false;

    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        switch (c) {
            ' ', '\t' => {
                try flushTokenForce(allocator, &argv, &current, &token_active);
                i += 1;
            },
            '>' => {
                try flushTokenForce(allocator, &argv, &current, &token_active);
                // Check for `>&1` / `>&2` fd-dup form (stdout ← stdout/stderr)
                if (i + 2 < line.len and line[i + 1] == '&' and (line[i + 2] == '1' or line[i + 2] == '2')) {
                    var operator = [_]u8{ '>', '&', line[i + 2] };
                    try appendToken(allocator, &argv, &operator);
                    i += 3;
                } else if (i + 1 < line.len and line[i + 1] == '>') {
                    try appendToken(allocator, &argv, ">>");
                    i += 2;
                } else {
                    try appendToken(allocator, &argv, ">");
                    i += 1;
                }
            },
            '1', '2' => {
                if (current.items.len == 0 and i + 1 < line.len and line[i + 1] == '>') {
                    // Check for `N>&M` fd-dup form before `N>>` and `N>`
                    if (i + 3 < line.len and line[i + 2] == '&' and (line[i + 3] == '1' or line[i + 3] == '2')) {
                        var operator = [_]u8{ c, '>', '&', line[i + 3] };
                        try appendToken(allocator, &argv, &operator);
                        i += 4;
                    } else if (i + 2 < line.len and line[i + 2] == '>') {
                        var operator = [_]u8{ c, '>', '>' };
                        try appendToken(allocator, &argv, &operator);
                        i += 3;
                    } else {
                        var operator = [_]u8{ c, '>' };
                        try appendToken(allocator, &argv, &operator);
                        i += 2;
                    }
                } else {
                    try current.append(allocator, c);
                    i += 1;
                }
            },
            '\'' => {
                token_active = true;
                i += 1;
                while (i < line.len and line[i] != '\'') : (i += 1) {
                    try current.append(allocator, line[i]);
                }
                if (i >= line.len) return error.UnterminatedSingleQuote;
                i += 1;
            },
            '"' => {
                token_active = true;
                i += 1;
                while (i < line.len and line[i] != '"') : (i += 1) {
                    if (line[i] == '$') {
                        if (try appendParameterExpansion(allocator, &argv, &current, line, &i, shell, false)) {
                            i -= 1;
                            continue;
                        }
                    }
                    if (line[i] == '\\' and i + 1 < line.len) {
                        const next = line[i + 1];
                        if (next == '\n') {
                            // backslash-newline: line continuation — consume both, emit nothing.
                            // The while loop posts i += 1, so set i to the newline position
                            // and let the post-increment skip past it.
                            i += 1;
                            continue;
                        }
                        if (next == '$' or next == '`' or next == '"' or next == '\\') {
                            try current.append(allocator, next);
                            i += 1;
                            continue;
                        }
                    }
                    try current.append(allocator, line[i]);
                }
                if (i >= line.len) return error.UnterminatedDoubleQuote;
                i += 1;
            },
            '$' => {
                if (!try appendParameterExpansion(allocator, &argv, &current, line, &i, shell, true)) {
                    try current.append(allocator, c);
                    i += 1;
                }
            },
            '\\' => {
                if (i + 1 < line.len) {
                    const next = line[i + 1];
                    if (next == '\n') {
                        // backslash-newline outside quotes: line continuation — consume both, emit nothing
                        i += 2;
                    } else {
                        try current.append(allocator, next);
                        i += 2;
                    }
                } else {
                    try current.append(allocator, c);
                    i += 1;
                }
            },
            else => {
                try current.append(allocator, c);
                i += 1;
            },
        }
    }

    try flushTokenForce(allocator, &argv, &current, &token_active);
    return .{ .allocator = allocator, .argv = argv };
}

fn appendParameterExpansion(
    allocator: Allocator,
    argv: *std.ArrayList([]u8),
    current: *std.ArrayList(u8),
    line: []const u8,
    index: *usize,
    shell: ?*Shell,
    split_words: bool,
) !bool {
    const dollar = index.*;
    if (dollar + 1 >= line.len) return false;

    var name_start = dollar + 1;
    var name_end = name_start;
    if (line[name_start] == '{') {
        name_start += 1;
        name_end = name_start;
        while (name_end < line.len and isNameChar(line[name_end])) : (name_end += 1) {}
        if (name_end == name_start or name_end >= line.len or line[name_end] != '}') return false;
        index.* = name_end + 1;
    } else {
        if (!isNameStart(line[name_start])) return false;
        name_end = name_start + 1;
        while (name_end < line.len and isNameChar(line[name_end])) : (name_end += 1) {}
        index.* = name_end;
    }

    const name = line[name_start..name_end];
    const value = if (shell) |sh| sh.env.get(name) orelse "" else "";
    if (split_words) {
        try appendExpansionWithWordSplitting(allocator, argv, current, value);
    } else {
        try current.appendSlice(allocator, value);
    }
    return true;
}

fn appendExpansionWithWordSplitting(
    allocator: Allocator,
    argv: *std.ArrayList([]u8),
    current: *std.ArrayList(u8),
    value: []const u8,
) !void {
    for (value) |c| {
        if (isShellWhitespace(c)) {
            try flushToken(allocator, argv, current);
        } else {
            try current.append(allocator, c);
        }
    }
}

fn appendToken(allocator: Allocator, argv: *std.ArrayList([]u8), token: []const u8) !void {
    try argv.append(allocator, try allocator.dupe(u8, token));
}

fn flushToken(allocator: Allocator, argv: *std.ArrayList([]u8), current: *std.ArrayList(u8)) !void {
    if (current.items.len == 0) return;
    try argv.append(allocator, try allocator.dupe(u8, current.items));
    current.clearRetainingCapacity();
}

// Word-boundary flush that preserves an explicitly quoted empty word. Used at
// whitespace, redirection operators, and end of input; not used for unquoted
// expansion word splitting, where empty words must still be discarded.
fn flushTokenForce(
    allocator: Allocator,
    argv: *std.ArrayList([]u8),
    current: *std.ArrayList(u8),
    token_active: *bool,
) !void {
    if (current.items.len == 0 and !token_active.*) return;
    try argv.append(allocator, try allocator.dupe(u8, current.items));
    current.clearRetainingCapacity();
    token_active.* = false;
}

fn parseRedirectionOperator(token: []const u8) ?RedirectionSpec {
    if (std.mem.eql(u8, token, ">") or std.mem.eql(u8, token, "1>")) {
        return .{ .target = .stdout, .append = false };
    }
    if (std.mem.eql(u8, token, ">>") or std.mem.eql(u8, token, "1>>")) {
        return .{ .target = .stdout, .append = true };
    }
    if (std.mem.eql(u8, token, "2>")) {
        return .{ .target = .stderr, .append = false };
    }
    if (std.mem.eql(u8, token, "2>>")) {
        return .{ .target = .stderr, .append = true };
    }
    // fd-dup forms: `2>&1` (stderr → stdout), `1>&2` (stdout → stderr),
    // `>&1` (stdout → stdout, identity), `>&2` (stdout → stderr).
    if (std.mem.eql(u8, token, "2>&1")) {
        return .{ .target = .stderr, .append = false, .dup_source = .stdout };
    }
    if (std.mem.eql(u8, token, "1>&2")) {
        return .{ .target = .stdout, .append = false, .dup_source = .stderr };
    }
    if (std.mem.eql(u8, token, ">&1")) {
        return .{ .target = .stdout, .append = false, .dup_source = .stdout };
    }
    if (std.mem.eql(u8, token, ">&2")) {
        return .{ .target = .stdout, .append = false, .dup_source = .stderr };
    }
    return null;
}

fn hasUnquotedPipe(line: []const u8) bool {
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote) |q| {
            if (q == '\'' and c == '\'') {
                quote = null;
            } else if (q == '"' and c == '"') {
                quote = null;
            } else if (q == '"' and c == '\\' and i + 1 < line.len) {
                i += 1;
            }
            continue;
        }

        if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '\\' and i + 1 < line.len) {
            i += 1;
        } else if (c == '|') {
            return true;
        }
    }
    return false;
}

fn trailingBackgroundCommand(line: []const u8) ?[]const u8 {
    var end = line.len;
    while (end > 0 and isShellWhitespace(line[end - 1])) : (end -= 1) {}
    if (end == 0 or line[end - 1] != '&') return null;
    if (!isUnquotedAt(line, end - 1)) return null;

    var command_end = end - 1;
    while (command_end > 0 and isShellWhitespace(line[command_end - 1])) : (command_end -= 1) {}
    if (command_end == 0) return null;
    return line[0..command_end];
}

fn isUnquotedAt(line: []const u8, target: usize) bool {
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (i == target) return quote == null;

        const c = line[i];
        if (quote) |q| {
            if (q == '\'' and c == '\'') {
                quote = null;
            } else if (q == '"' and c == '"') {
                quote = null;
            } else if (q == '"' and c == '\\' and i + 1 < line.len) {
                i += 1;
            }
            continue;
        }

        if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '\\' and i + 1 < line.len) {
            i += 1;
        }
    }
    return false;
}

fn isShellWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn childHasExited(child: *std.process.Child, io: std.Io) bool {
    if (child.id == null) return true;

    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const minimal_timeout: windows.LARGE_INTEGER = -1;
        return switch (windows.ntdll.NtWaitForSingleObject(child.id.?, .FALSE, &minimal_timeout)) {
            .WAIT_0 => {
                _ = child.wait(io) catch {};
                return true;
            },
            .TIMEOUT => false,
            else => false,
        };
    }

    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const pid = child.id.?;
        var status: u32 = 0;

        while (true) {
            const result = linux.waitpid(pid, &status, linux.W.NOHANG);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0) return false;
                    child.id = null;
                    return true;
                },
                .INTR => continue,
                .CHILD => {
                    child.id = null;
                    return true;
                },
                else => return false,
            }
        }
    }

    // macOS: reap via libc waitpid(WNOHANG). Without this branch macOS fell
    // through to `return false`, so background jobs were never marked done —
    // finished children lingered as zombies and `jobs` showed them Running
    // forever. We handle ECHILD ourselves rather than calling
    // std.posix.waitpid (which panics on it) to keep the no-panic guarantee.
    // libSystem (libc) is always linked on macOS, so std.c is available.
    if (builtin.os.tag == .macos) {
        const pid = child.id.?;
        var status: c_int = 0;
        while (true) {
            const result = std.c.waitpid(pid, &status, @as(c_int, @intCast(std.posix.W.NOHANG)));
            switch (std.posix.errno(result)) {
                .SUCCESS => {
                    if (result == 0) return false;
                    child.id = null;
                    return true;
                },
                .INTR => continue,
                .CHILD => {
                    child.id = null;
                    return true;
                },
                else => return false,
            }
        }
    }

    return false;
}

fn childIdForDisplay(child: *const std.process.Child) u64 {
    const id = child.id orelse return 0;
    if (builtin.os.tag == .windows) return @intCast(@intFromPtr(id));
    return @intCast(id);
}

fn appendFmt(allocator: Allocator, buffer: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try buffer.appendSlice(allocator, text);
}

fn appendSingleQuoted(allocator: Allocator, buffer: *std.ArrayList(u8), value: []const u8) !void {
    try buffer.append(allocator, '\'');
    for (value) |c| {
        if (c == '\'') {
            try buffer.appendSlice(allocator, "'\\''");
        } else {
            try buffer.append(allocator, c);
        }
    }
    try buffer.append(allocator, '\'');
}

fn appendTsvField(allocator: Allocator, buffer: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '\t' => try buffer.appendSlice(allocator, "\\t"),
            '\n' => try buffer.appendSlice(allocator, "\\n"),
            '\r' => try buffer.appendSlice(allocator, "\\r"),
            '\\' => try buffer.appendSlice(allocator, "\\\\"),
            else => try buffer.append(allocator, c),
        }
    }
}

/// Reverse `appendTsvField`. Unknown `\\X` sequences fall back to literal `X`
/// rather than the escape — defensive when reading a possibly-edited history
/// file. Caller owns the returned slice.
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
    return try out.toOwnedSlice(allocator);
}

/// JSON-encode a string value into `buffer`, including surrounding quotes.
/// Escapes the four reserved control chars plus backspace/form-feed via their
/// short forms (`\n`, `\r`, `\t`, `\b`, `\f`); every other byte below 0x20 is
/// emitted as `\u00XX`. RFC 8259 requires all control characters be escaped;
/// the previous implementation only handled `\n`, `\r`, `\t`, which produced
/// invalid JSON for any value containing NUL, BEL, VT, etc.
fn appendJsonString(allocator: Allocator, buffer: *std.ArrayList(u8), value: []const u8) !void {
    try buffer.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try buffer.appendSlice(allocator, "\\\""),
            '\\' => try buffer.appendSlice(allocator, "\\\\"),
            '\n' => try buffer.appendSlice(allocator, "\\n"),
            '\r' => try buffer.appendSlice(allocator, "\\r"),
            '\t' => try buffer.appendSlice(allocator, "\\t"),
            0x08 => try buffer.appendSlice(allocator, "\\b"),
            0x0c => try buffer.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    var hex: [6]u8 = undefined;
                    const escaped = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c}) catch unreachable;
                    try buffer.appendSlice(allocator, escaped);
                } else {
                    try buffer.append(allocator, c);
                }
            },
        }
    }
    try buffer.append(allocator, '"');
}

fn hasArg(argv: []const []const u8, wanted: []const u8) bool {
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, wanted)) return true;
    }
    return false;
}

fn parseGitStatusOutput(output: []const u8, status: *GitPromptStatus) void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = trimTrailingCarriageReturn(raw_line);
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "## ")) {
            parseGitBranchLine(line[3..], status);
            continue;
        }
        parseGitStatusLine(line, status);
    }
}

fn parseGitBranchLine(line: []const u8, status: *GitPromptStatus) void {
    status.present = true;
    parseAheadBehind(line, status);

    const no_commits = "No commits yet on ";
    const branch = if (std.mem.startsWith(u8, line, no_commits))
        line[no_commits.len..]
    else if (std.mem.startsWith(u8, line, "HEAD"))
        "detached"
    else branch_name: {
        var end = line.len;
        if (std.mem.indexOf(u8, line, "...")) |index| end = @min(end, index);
        if (std.mem.indexOfScalar(u8, line, ' ')) |index| end = @min(end, index);
        if (std.mem.indexOfScalar(u8, line, '[')) |index| end = @min(end, index);
        break :branch_name line[0..end];
    };

    const trimmed = std.mem.trim(u8, branch, " \t\r\n");
    status.branch_len = copyBounded(status.branch[0..], if (trimmed.len > 0) trimmed else "unknown");
}

fn parseGitStatusLine(line: []const u8, status: *GitPromptStatus) void {
    if (line.len < 2) return;
    const x = line[0];
    const y = line[1];
    if (x == '?' and y == '?') {
        status.untracked += 1;
        return;
    }
    if (x == '!' and y == '!') return;
    if (isGitConflictStatus(x, y)) {
        status.conflicts += 1;
        return;
    }
    if (x != ' ' and x != '?') status.staged += 1;
    if (y != ' ' and y != '?') status.changed += 1;
}

fn isGitConflictStatus(x: u8, y: u8) bool {
    return x == 'U' or y == 'U' or
        (x == 'A' and y == 'A') or
        (x == 'D' and y == 'D');
}

fn parseAheadBehind(line: []const u8, status: *GitPromptStatus) void {
    const open = std.mem.indexOfScalar(u8, line, '[') orelse return;
    const close_offset = std.mem.indexOfScalar(u8, line[open + 1 ..], ']') orelse return;
    const inside = line[open + 1 .. open + 1 + close_offset];
    var parts = std.mem.splitScalar(u8, inside, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        const ahead = "ahead ";
        const behind = "behind ";
        if (std.mem.startsWith(u8, part, ahead)) {
            status.ahead = std.fmt.parseInt(usize, part[ahead.len..], 10) catch status.ahead;
        } else if (std.mem.startsWith(u8, part, behind)) {
            status.behind = std.fmt.parseInt(usize, part[behind.len..], 10) catch status.behind;
        }
    }
}

fn copyBounded(out: []u8, value: []const u8) usize {
    const len = @min(out.len, value.len);
    @memcpy(out[0..len], value[0..len]);
    return len;
}

/// Apply an OSC payload (the bytes between `ESC ]` and the BEL/ST terminator).
/// Recognises Theme Protocol v2 sequences of the form
///   `7777;ziggyzag.theme=<id>`
/// and updates `shell.current_theme` in place if `<id>` resolves to a known
/// theme. Any other payload is silently ignored. Extracted from
/// `handleOscSequence` so the parser is unit-testable without a live reader.
fn applyOscPayload(shell: *Shell, payload: []const u8) void {
    const sep = std.mem.indexOfScalar(u8, payload, ';') orelse return;
    const code = payload[0..sep];
    if (!std.mem.eql(u8, code, "7777")) return;
    const body = payload[sep + 1 ..];
    const eq = std.mem.indexOfScalar(u8, body, '=') orelse return;
    const key = body[0..eq];
    const value = body[eq + 1 ..];
    if (!std.mem.eql(u8, key, "ziggyzag.theme")) return;
    if (theme.maybeByName(value)) |selected| {
        shell.current_theme = selected;
        shell.prompt_snapshot_valid = false;
    }
}

fn isConfigDirective(command: []const u8) bool {
    return std.mem.eql(u8, command, "alias") or
        std.mem.eql(u8, command, "abbr") or
        std.mem.eql(u8, command, "export") or
        std.mem.eql(u8, command, "complete") or
        std.mem.eql(u8, command, "prompt") or
        std.mem.eql(u8, command, "highlight") or
        std.mem.eql(u8, command, "theme") or
        std.mem.eql(u8, command, "history");
}

fn isTruthyEnv(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.mem.eql(u8, text, "1") or
        std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "on");
}

fn isFalseyEnv(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.mem.eql(u8, text, "0") or
        std.ascii.eqlIgnoreCase(text, "false") or
        std.ascii.eqlIgnoreCase(text, "no") or
        std.ascii.eqlIgnoreCase(text, "off");
}

fn envI64Bounded(value: ?[]const u8, default_value: i64, min_value: i64, max_value: i64) i64 {
    const text = value orelse return default_value;
    const parsed = std.fmt.parseInt(i64, text, 10) catch return default_value;
    return std.math.clamp(parsed, min_value, max_value);
}

fn isDecimalNumber(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn slashCommandReplacement(command: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, command, "/help")) return "help";
    if (std.mem.eql(u8, command, "/doctor")) return "doctor";
    if (std.mem.eql(u8, command, "/status")) return "doctor";
    if (std.mem.eql(u8, command, "/config")) return "config";
    if (std.mem.eql(u8, command, "/reload")) return "config reload";
    if (std.mem.eql(u8, command, "/inspect")) return "inspect";
    if (std.mem.eql(u8, command, "/smart")) return "prompt smart";
    if (std.mem.eql(u8, command, "/classic")) return "prompt classic";
    if (std.mem.eql(u8, command, "/compact")) return "prompt compact";
    if (std.mem.eql(u8, command, "/dev")) return "prompt dev";
    if (std.mem.eql(u8, command, "/dashboard")) return "prompt dashboard";
    if (std.mem.eql(u8, command, "/themes")) return "prompt themes";
    return null;
}

fn commandRemainder(line: []const u8, words_to_skip: usize) ?[]const u8 {
    var index: usize = 0;
    var skipped: usize = 0;
    while (skipped < words_to_skip) {
        while (index < line.len and isShellWhitespace(line[index])) : (index += 1) {}
        if (index >= line.len) return null;
        while (index < line.len and !isShellWhitespace(line[index])) : (index += 1) {}
        skipped += 1;
    }
    while (index < line.len and isShellWhitespace(line[index])) : (index += 1) {}
    if (index >= line.len) return null;
    return line[index..];
}

fn previousWordStart(line: []const u8, cursor: usize) usize {
    var index = @min(cursor, line.len);
    while (index > 0 and isShellWhitespace(line[index - 1])) index -= 1;
    while (index > 0 and !isShellWhitespace(line[index - 1])) index -= 1;
    return index;
}

fn projectTasks(kind: ProjectKind) []const u8 {
    return switch (kind) {
        .zig => "build test run fmt",
        .node => "install build test lint dev start",
        .rust => "build test run fmt check",
        .python => "test run lint",
        .go => "build test run fmt",
        .make => "build test install clean",
        .git => "status branch",
    };
}

fn promptModeByName(name: []const u8) ?PromptMode {
    for (prompt_modes) |mode| {
        if (std.ascii.eqlIgnoreCase(name, @tagName(mode))) return mode;
    }
    return null;
}

fn promptModeDescription(mode: PromptMode) []const u8 {
    return switch (mode) {
        .classic => "plain `$` prompt for scripts, demos, and compatibility checks",
        .smart => "cwd, git branch, project kind, jobs, status, and slow command duration",
        .compact => "dense one-line prompt with cwd, git branch/change marker, status, and jobs",
        .dev => "two-line colored developer prompt with git counts, project type, status, and duration",
        .dashboard => "two-line status prompt for demos with cwd, project, git, jobs, and timing",
    };
}

fn builtinDescription(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "about")) return "show project summary";
    if (std.mem.eql(u8, name, "abbr")) return "manage visible command abbreviations";
    if (std.mem.eql(u8, name, "alias")) return "manage command aliases";
    if (std.mem.eql(u8, name, "back")) return "return to an earlier directory";
    if (std.mem.eql(u8, name, "bg")) return "show or resume a background job";
    if (std.mem.eql(u8, name, "cd")) return "change directory";
    if (std.mem.eql(u8, name, "complete")) return "register completions";
    if (std.mem.eql(u8, name, "config")) return "show, reload, and validate startup config";
    if (std.mem.eql(u8, name, "declare")) return "set shell variables";
    if (std.mem.eql(u8, name, "disown")) return "remove jobs from shell tracking";
    if (std.mem.eql(u8, name, "dirs")) return "show directory history";
    if (std.mem.eql(u8, name, "doctor")) return "inspect shell runtime state";
    if (std.mem.eql(u8, name, "echo")) return "print arguments";
    if (std.mem.eql(u8, name, "env")) return "show environment variables";
    if (std.mem.eql(u8, name, "exit")) return "leave the shell";
    if (std.mem.eql(u8, name, "export")) return "set environment variables";
    if (std.mem.eql(u8, name, "fg")) return "wait for a job in the foreground";
    if (std.mem.eql(u8, name, "forward")) return "move forward in directory history";
    if (std.mem.eql(u8, name, "help")) return "show shell help";
    if (std.mem.eql(u8, name, "history")) return "show and search history";
    if (std.mem.eql(u8, name, "inspect")) return "explain command parsing and execution path";
    if (std.mem.eql(u8, name, "jump")) return "fuzzy-jump to a visited directory";
    if (std.mem.eql(u8, name, "jobs")) return "list background jobs";
    if (std.mem.eql(u8, name, "kill")) return "terminate a job or pid";
    if (std.mem.eql(u8, name, "mkcd")) return "create and enter a directory";
    if (std.mem.eql(u8, name, "path")) return "show PATH entries";
    if (std.mem.eql(u8, name, "project")) return "detect project tasks";
    if (std.mem.eql(u8, name, "prompt")) return "configure prompt modules";
    if (std.mem.eql(u8, name, "highlight")) return "toggle syntax highlighting";
    if (std.mem.eql(u8, name, "pwd")) return "print current directory";
    if (std.mem.eql(u8, name, "repeat")) return "run a command multiple times";
    if (std.mem.eql(u8, name, "run")) return "run a project-aware task";
    if (std.mem.eql(u8, name, "source")) return "run commands from a file";
    if (std.mem.eql(u8, name, "theme")) return "show or switch the active terminal theme";
    if (std.mem.eql(u8, name, "timeit")) return "time a command";
    if (std.mem.eql(u8, name, "type")) return "explain command resolution";
    if (std.mem.eql(u8, name, "unalias")) return "remove an alias";
    if (std.mem.eql(u8, name, "unabbr")) return "remove an abbreviation";
    if (std.mem.eql(u8, name, "up")) return "move up parent directories";
    if (std.mem.eql(u8, name, "unset")) return "remove a variable";
    if (std.mem.eql(u8, name, "vars")) return "show shell variable map";
    if (std.mem.eql(u8, name, "wait")) return "wait for background jobs";
    if (std.mem.eql(u8, name, "which")) return "resolve command paths";
    return null;
}

fn termExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => 128,
        .stopped => 128,
        .unknown => 1,
    };
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    if (slash + 1 >= path.len) return path;
    return path[slash + 1 ..];
}

fn hasWindowsExecutableExtension(path: []const u8) bool {
    const name = baseName(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot..];
    return std.ascii.eqlIgnoreCase(ext, ".exe") or
        std.ascii.eqlIgnoreCase(ext, ".com") or
        std.ascii.eqlIgnoreCase(ext, ".bat") or
        std.ascii.eqlIgnoreCase(ext, ".cmd");
}

/// Whether a command line should be kept out of persisted history because it
/// is likely to carry a secret. Conservative on purpose: false positives only
/// cost a missing history line, false negatives leak a credential to disk. We
/// match on substrings that almost always precede secret material — auth flags
/// (`--password`, `--token`), assignments to secret-named variables, and a few
/// well-known credential-bearing commands. Case-insensitive so `--Token` and
/// `API_KEY=` both match. The in-memory `history` list is unaffected; only the
/// on-disk metadata write consults this.
fn shouldRedactHistory(line: []const u8) bool {
    const needles = [_][]const u8{
        "--password",
        "--token",
        "--api-key",
        "--apikey",
        "--secret",
        "--bearer",
        "password=",
        "passwd=",
        "token=",
        "api_key=",
        "apikey=",
        "secret=",
        "access_key=",
        "private_key=",
        "client_secret=",
        "aws_secret_access_key",
        "authorization:",
    };
    for (needles) |needle| {
        if (asciiIndexOfIgnoreCase(line, needle) != null) return true;
    }
    return false;
}

/// Case-insensitive substring search. Returns the index of the first match of
/// `needle` in `haystack`, or null. `needle` is expected to already be
/// lowercase (all call sites pass lowercase literals), so only `haystack` is
/// folded.
fn asciiIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != nc) {
                matched = false;
                break;
            }
        }
        if (matched) return i;
    }
    return null;
}

fn fuzzyScore(query: []const u8, candidate: []const u8) ?usize {
    if (query.len == 0) return 0;
    var score: usize = 0;
    var query_index: usize = 0;
    for (candidate, 0..) |c, index| {
        if (std.ascii.toLower(c) == std.ascii.toLower(query[query_index])) {
            score += index + 1;
            query_index += 1;
            if (query_index == query.len) return score;
        }
    }
    return null;
}

fn isComplexPipelineSyntax(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "&&") != null) return true;
    if (std.mem.indexOf(u8, line, "||") != null) return true;
    if (std.mem.indexOf(u8, line, "|&") != null) return true;
    if (std.mem.indexOfScalar(u8, line, ';') != null) return true;
    if (std.mem.indexOfScalar(u8, line, '`') != null) return true;
    if (std.mem.indexOf(u8, line, "$(") != null) return true;
    if (trailingBackgroundCommand(line) != null) return true;
    return false;
}

fn pipelineTempRoot(env: *const std.process.Environ.Map) []const u8 {
    if (env.get("ZIGGYZAG_PIPE_TMPDIR")) |path| return path;
    if (env.get("TMPDIR")) |path| return path;
    if (env.get("TEMP")) |path| return path;
    if (env.get("TMP")) |path| return path;
    return ".";
}

fn splitUnquotedPipes(allocator: Allocator, line: []const u8, segments: *std.ArrayList([]u8)) !void {
    var quote: ?u8 = null;
    var start: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote) |q| {
            if (q == '\'' and c == '\'') {
                quote = null;
            } else if (q == '"' and c == '"') {
                quote = null;
            } else if (q == '"' and c == '\\' and i + 1 < line.len) {
                i += 1;
            }
            continue;
        }

        if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '\\' and i + 1 < line.len) {
            i += 1;
        } else if (c == '|') {
            const segment = std.mem.trim(u8, line[start..i], " \t");
            if (segment.len == 0) return error.UnsupportedPipelineStage;
            try segments.append(allocator, try allocator.dupe(u8, segment));
            start = i + 1;
        }
    }

    if (quote != null) return error.UnsupportedPipelineStage;
    const segment = std.mem.trim(u8, line[start..], " \t");
    if (segment.len == 0) return error.UnsupportedPipelineStage;
    try segments.append(allocator, try allocator.dupe(u8, segment));
}

fn firstNonWhitespace(line: []const u8) usize {
    var index: usize = 0;
    while (index < line.len and isShellWhitespace(line[index])) : (index += 1) {}
    return index;
}

fn simpleCommandWordEnd(line: []const u8, start: usize) usize {
    var index = start;
    while (index < line.len) : (index += 1) {
        const c = line[index];
        if (isShellWhitespace(c) or c == '|' or c == '&' or c == '<' or c == '>') break;
    }
    return index;
}

/// Fill `out` (one entry per byte of `line`) with the highlight class of each
/// byte. The command head spans `[head_start, head_end)` and is tagged with
/// `head_kind`; everything else is classified by a single left-to-right pass
/// that tracks quote state so operators and `$` inside a string are treated as
/// plain string content. Pure and allocation-free for easy testing.
fn classifyHighlight(
    line: []const u8,
    head_start: usize,
    head_end: usize,
    head_kind: CommandHeadKind,
    out: []HighlightKind,
) void {
    std.debug.assert(out.len == line.len);
    var quote: u8 = 0; // 0 = none, else the active quote char
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];

        if (quote != 0) {
            out[i] = .string;
            // A backslash inside double quotes escapes the next byte; mark it
            // as string too so the run stays contiguous.
            if (quote == '"' and c == '\\' and i + 1 < line.len) {
                i += 1;
                if (i < line.len) out[i] = .string;
                continue;
            }
            if (c == quote) quote = 0;
            continue;
        }

        // Outside quotes. The command head wins over operator/variable tagging
        // so a head like `ls>` still colors the `ls` part by validity.
        if (i >= head_start and i < head_end) {
            out[i] = switch (head_kind) {
                .builtin => .command_builtin,
                .valid => .command_valid,
                .invalid => .command_invalid,
            };
            continue;
        }

        switch (c) {
            '\'', '"' => {
                quote = c;
                out[i] = .string;
            },
            '|', '<', '>', '&', ';' => out[i] = .operator,
            '$' => out[i] = .variable,
            '\\' => {
                // Escape outside quotes: the backslash and the escaped byte are
                // plain so a `\$` does not read as a variable.
                out[i] = .plain;
                if (i + 1 < line.len) {
                    i += 1;
                    out[i] = .plain;
                }
            },
            else => out[i] = .plain,
        }
    }
}

/// ANSI SGR sequence for a highlight class, or "" for `.plain` (no coloring).
fn highlightAnsiCode(kind: HighlightKind) []const u8 {
    return switch (kind) {
        .command_builtin => "\x1b[32m", // green
        .command_valid => "\x1b[36m", // cyan
        .command_invalid => "\x1b[31m", // red
        .string => "\x1b[33m", // yellow
        .operator => "\x1b[35m", // magenta
        .variable => "\x1b[34m", // blue
        .plain => "",
    };
}

fn isCompletionWhitespace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Index where the token under completion begins, scanning `line` left to
/// right while honoring shell quoting. A word break is an *unquoted,
/// unescaped* space/tab; whitespace inside `'...'` or `"..."` or after a
/// backslash stays part of the current token. This is what lets a path with
/// spaces complete as a single argument: with `cat "my fi` the token starts at
/// the opening quote, not at the space. `line` is the slice up to the cursor,
/// so the returned index is always a token start relative to the cursor.
fn completionTokenStart(line: []const u8) usize {
    var start: usize = 0;
    var i: usize = 0;
    var quote: u8 = 0; // 0 = none, else the active quote char
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            // Inside double quotes a backslash escapes the next byte; inside
            // single quotes nothing is special. The closing quote ends the
            // quoted run.
            if (quote == '"' and c == '\\' and i + 1 < line.len) {
                i += 1;
                continue;
            }
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\\' => {
                // Backslash escapes the next byte (e.g. `my\ file`); skip it so
                // an escaped space does not break the token.
                if (i + 1 < line.len) i += 1;
            },
            '\'', '"' => quote = c,
            else => if (isCompletionWhitespace(c)) {
                start = i + 1;
            },
        }
    }
    return start;
}

/// Decode a possibly-quoted/escaped token into the literal path it denotes, so
/// it can be matched against real filenames. `"my file"`, `'my file'`, and
/// `my\ file` all decode to `my file`. Caller owns the returned slice.
fn decodeCompletionToken(allocator: Allocator, token: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var quote: u8 = 0;
    while (i < token.len) : (i += 1) {
        const c = token[i];
        if (quote != 0) {
            if (quote == '"' and c == '\\' and i + 1 < token.len) {
                try out.append(allocator, token[i + 1]);
                i += 1;
                continue;
            }
            if (c == quote) {
                quote = 0;
                continue;
            }
            try out.append(allocator, c);
            continue;
        }
        switch (c) {
            '\\' => {
                if (i + 1 < token.len) {
                    try out.append(allocator, token[i + 1]);
                    i += 1;
                }
            },
            '\'', '"' => quote = c,
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Whether `path` contains a byte that would need quoting/escaping to survive
/// the parser as a single argument.
fn pathNeedsQuoting(path: []const u8) bool {
    for (path) |c| {
        switch (c) {
            ' ', '\t', '\'', '"', '\\', '$', '`', '(', ')', '|', '&', ';', '<', '>', '*', '?', '[', ']', '{', '}', '#', '~' => return true,
            else => {},
        }
    }
    return false;
}

/// Encode a literal path for insertion at the prompt, quoting only when needed.
/// Uses single quotes (the simplest shell quoting — nothing inside is special)
/// and falls back to backslash-escaping the embedded single quote via the
/// `'\''` idiom. Caller owns the returned slice.
fn encodeCompletionPath(allocator: Allocator, path: []const u8) ![]u8 {
    if (!pathNeedsQuoting(path)) return allocator.dupe(u8, path);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (path) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn commandNameForCompletion(line: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < line.len and isCompletionWhitespace(line[start])) : (start += 1) {}

    var end = start;
    while (end < line.len and !isCompletionWhitespace(line[end])) : (end += 1) {}

    if (end == start) return null;
    return line[start..end];
}

fn previousCompletionWord(line: []const u8, token_start: usize) []const u8 {
    const command = commandNameForCompletion(line) orelse return "";
    const command_end = (@intFromPtr(command.ptr) - @intFromPtr(line.ptr)) + command.len;

    var end = token_start;
    while (end > 0 and isCompletionWhitespace(line[end - 1])) : (end -= 1) {}
    if (end <= command_end) {
        if (token_start < line.len) return command;
        return "";
    }

    var start = end;
    while (start > command_end and !isCompletionWhitespace(line[start - 1])) : (start -= 1) {}
    return line[start..end];
}

fn lastPathSeparator(path: []const u8) ?usize {
    var result: ?usize = null;
    for (path, 0..) |c, index| {
        if (c == '/') result = index;
    }
    return result;
}

fn longestCommonPrefix(items: []const []u8) []const u8 {
    if (items.len == 0) return "";

    var prefix_len = items[0].len;
    for (items[1..]) |item| {
        var i: usize = 0;
        const limit = if (prefix_len < item.len) prefix_len else item.len;
        while (i < limit and items[0][i] == item[i]) : (i += 1) {}
        prefix_len = i;
    }

    return items[0][0..prefix_len];
}

fn longestCommonPrefixEntries(items: []const CompletionEntry) []const u8 {
    if (items.len == 0) return "";

    var prefix_len = items[0].text.len;
    for (items[1..]) |item| {
        var i: usize = 0;
        const limit = if (prefix_len < item.text.len) prefix_len else item.text.len;
        while (i < limit and items[0].text[i] == item.text[i]) : (i += 1) {}
        prefix_len = i;
    }

    return items[0].text[0..prefix_len];
}

fn trimTrailingCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

/// Parse the newline-delimited output of a programmable completer and add
/// non-empty candidates that start with `prefix` to `matches`, up to
/// `max_completer_output_lines` entries total.  Exported as a free function so
/// unit tests can exercise the bound logic without spawning a process.
fn collectCompleterLines(
    allocator: Allocator,
    stdout_blob: []const u8,
    prefix: []const u8,
    matches: *std.ArrayList([]u8),
) !void {
    var lines = std.mem.splitScalar(u8, stdout_blob, '\n');
    var line_count: usize = 0;
    while (lines.next()) |raw_line| {
        if (line_count >= max_completer_output_lines) break;
        const candidate = trimTrailingCarriageReturn(raw_line);
        if (candidate.len == 0) continue;
        if (!std.mem.startsWith(u8, candidate, prefix)) {
            line_count += 1;
            continue;
        }
        // Avoid duplicates (mirrors addCompletionMatch logic).
        var already_present = false;
        for (matches.items) |existing| {
            if (std.mem.eql(u8, existing, candidate)) {
                already_present = true;
                break;
            }
        }
        if (!already_present) {
            try matches.append(allocator, try allocator.dupe(u8, candidate));
        }
        line_count += 1;
    }
}

fn sortCompletionMatches(items: [][]u8) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, items[j], items[j - 1])) : (j -= 1) {
            std.mem.swap([]u8, &items[j], &items[j - 1]);
        }
    }
}

fn sortCompletionEntries(items: []CompletionEntry) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, items[j].text, items[j - 1].text)) : (j -= 1) {
            std.mem.swap(CompletionEntry, &items[j], &items[j - 1]);
        }
    }
}

const shell_builtin_names = [_][]const u8{
    "about",
    "back",
    "bg",
    "dirs",
    "disown",
    "echo",
    "env",
    "exit",
    "fg",
    "forward",
    "type",
    "pwd",
    "cd",
    "history",
    "jump",
    "declare",
    "jobs",
    "kill",
    "complete",
    "help",
    "alias",
    "abbr",
    "unabbr",
    "unalias",
    "config",
    "doctor",
    "export",
    "inspect",
    "mkcd",
    "path",
    "project",
    "prompt",
    "highlight",
    "repeat",
    "run",
    "source",
    "theme",
    "timeit",
    "up",
    "unset",
    "vars",
    "wait",
    "which",
};

fn isShellBuiltin(name: []const u8) bool {
    for (shell_builtin_names) |builtin_name| {
        if (std.mem.eql(u8, name, builtin_name)) return true;
    }
    return false;
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!isNameStart(name[0])) return false;
    for (name[1..]) |c| {
        if (!isNameChar(c)) return false;
    }
    return true;
}

test "parse quotes and redirections" {
    var parsed = try parseCommand(std.testing.allocator, "echo 'hello world' > out.txt 2>> err.txt");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.argv.items.len);
    try std.testing.expectEqualStrings("echo", parsed.argv.items[0]);
    try std.testing.expectEqualStrings("hello world", parsed.argv.items[1]);
    try std.testing.expect(parsed.stdout_redirect != null);
    try std.testing.expect(parsed.stderr_redirect != null);
    try std.testing.expectEqualStrings("out.txt", parsed.stdout_redirect.?.path);
    try std.testing.expect(parsed.stderr_redirect.?.append);
}

test "parse reports quote and redirection errors" {
    try std.testing.expectError(error.UnterminatedSingleQuote, parseCommand(std.testing.allocator, "echo 'oops"));
    try std.testing.expectError(error.UnterminatedDoubleQuote, parseCommand(std.testing.allocator, "echo \"oops"));
    try std.testing.expectError(error.MissingRedirectTarget, parseCommand(std.testing.allocator, "echo hello >"));
}

test "parse preserves explicitly quoted empty arguments" {
    const cases = [_]struct {
        line: []const u8,
        expected: []const []const u8,
    }{
        .{ .line = "echo \"\"", .expected = &.{ "echo", "" } },
        .{ .line = "echo ''", .expected = &.{ "echo", "" } },
        .{ .line = "echo a \"\" b", .expected = &.{ "echo", "a", "", "b" } },
        .{ .line = "echo \"$UNSET\"", .expected = &.{ "echo", "" } },
        // Unquoted empty expansion still yields no word (POSIX field splitting).
        .{ .line = "echo $UNSET", .expected = &.{"echo"} },
        // Empty quotes adjacent to text must not introduce a spurious word.
        .{ .line = "echo a'' b", .expected = &.{ "echo", "a", "b" } },
    };

    for (cases) |case| {
        var parsed = try parseCommand(std.testing.allocator, case.line);
        defer parsed.deinit();
        try std.testing.expectEqual(case.expected.len, parsed.argv.items.len);
        for (case.expected, 0..) |word, idx| {
            try std.testing.expectEqualStrings(word, parsed.argv.items[idx]);
        }
    }
}

test "parse keeps an empty quoted word alongside a redirection" {
    var parsed = try parseCommand(std.testing.allocator, "echo \"\" > out.txt");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.argv.items.len);
    try std.testing.expectEqualStrings("echo", parsed.argv.items[0]);
    try std.testing.expectEqualStrings("", parsed.argv.items[1]);
    try std.testing.expect(parsed.stdout_redirect != null);
    try std.testing.expectEqualStrings("out.txt", parsed.stdout_redirect.?.path);
}

test "split unquoted pipes" {
    var segments: std.ArrayList([]u8) = .empty;
    defer {
        for (segments.items) |segment| std.testing.allocator.free(segment);
        segments.deinit(std.testing.allocator);
    }

    try splitUnquotedPipes(std.testing.allocator, "echo 'a | b' | findstr a", &segments);
    try std.testing.expectEqual(@as(usize, 2), segments.items.len);
    try std.testing.expectEqualStrings("echo 'a | b'", segments.items[0]);
    try std.testing.expectEqualStrings("findstr a", segments.items[1]);
}

test "large pipeline handoff spools through temp file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer std.testing.allocator.free(temp_root);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZIGGYZAG_PIPE_TMPDIR", temp_root);

    var shell = Shell.init(std.testing.allocator, std.testing.io, &env);
    defer shell.deinit();

    const input = try std.testing.allocator.alloc(u8, max_pipeline_stage_input_bytes + 4096);
    defer std.testing.allocator.free(input);
    for (input, 0..) |*byte, index| byte.* = @intCast('a' + (index % 26));

    const temp = try shell.createPipelineInputFile(input);
    defer {
        temp.file.close(std.testing.io);
        std.Io.Dir.cwd().deleteFile(std.testing.io, temp.path) catch {};
        std.testing.allocator.free(temp.path);
    }

    const read_back = try std.testing.allocator.alloc(u8, input.len);
    defer std.testing.allocator.free(read_back);
    const read_len = try temp.file.readPositionalAll(std.testing.io, read_back, 0);

    try std.testing.expectEqual(input.len, read_len);
    try std.testing.expectEqualSlices(u8, input, read_back);
    try std.testing.expect(std.mem.startsWith(u8, temp.path, temp_root));
}

test "fuzzy score and slash command helpers" {
    try std.testing.expect(fuzzyScore("gs", "git status") != null);
    try std.testing.expect(fuzzyScore("zz", "git status") == null);
    try std.testing.expectEqualStrings("config reload", slashCommandReplacement("/reload").?);
    try std.testing.expectEqualStrings("prompt dev", slashCommandReplacement("/dev").?);
    try std.testing.expect(slashCommandReplacement("/bin/ls") == null);
    try std.testing.expectEqualStrings("echo hello", commandRemainder("repeat 2 echo hello", 2).?);
    try std.testing.expect(commandRemainder("timeit", 1) == null);
    try std.testing.expectEqual(@as(usize, 4), previousWordStart("one two", 7));
    try std.testing.expectEqualStrings("build test run fmt", projectTasks(.zig));
}

test "prompt modes and git status parsing" {
    try std.testing.expectEqual(PromptMode.dev, promptModeByName("dev").?);
    try std.testing.expectEqual(PromptMode.dashboard, promptModeByName("DASHBOARD").?);
    try std.testing.expect(promptModeByName("unknown") == null);

    var status: GitPromptStatus = .{};
    parseGitStatusOutput(
        \\## main...origin/main [ahead 2, behind 1]
        \\ M apps/shell/src/main.zig
        \\A  docs/NEW.md
        \\?? scratch.txt
        \\UU conflict.txt
        \\
    , &status);

    try std.testing.expect(status.present);
    try std.testing.expectEqualStrings("main", status.branchSlice());
    try std.testing.expectEqual(@as(usize, 1), status.staged);
    try std.testing.expectEqual(@as(usize, 1), status.changed);
    try std.testing.expectEqual(@as(usize, 1), status.untracked);
    try std.testing.expectEqual(@as(usize, 1), status.conflicts);
    try std.testing.expectEqual(@as(usize, 2), status.ahead);
    try std.testing.expectEqual(@as(usize, 1), status.behind);
}

test "config directives and names" {
    try std.testing.expect(isConfigDirective("alias"));
    try std.testing.expect(isConfigDirective("complete"));
    try std.testing.expect(isConfigDirective("history"));
    try std.testing.expect(isConfigDirective("theme"));
    try std.testing.expect(!isConfigDirective("rm"));
    try std.testing.expect(isValidName("ZIGGYZAG_1"));
    try std.testing.expect(!isValidName("1ZIGGYZAG"));
}

test "runtime helper knobs" {
    try std.testing.expectEqual(@as(i64, 150), envI64Bounded(null, 150, 0, 2000));
    try std.testing.expectEqual(@as(i64, 2000), envI64Bounded("9999", 150, 0, 2000));
    try std.testing.expectEqual(@as(i64, 0), envI64Bounded("-5", 150, 0, 2000));
    try std.testing.expectEqual(@as(i64, 150), envI64Bounded("nope", 150, 0, 2000));
    try std.testing.expect(isDecimalNumber("12345"));
    try std.testing.expect(!isDecimalNumber(""));
    try std.testing.expect(!isDecimalNumber("%1"));
}

test "history privacy commands toggle and clear state" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var shell = Shell.init(std.testing.allocator, undefined, &env);
    defer shell.deinit();

    try shell.history.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "echo secret"));

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try shell.historyCommand(&.{ "history", "disable", "--clear" }, &output);
    try std.testing.expect(!shell.history_enabled);
    try std.testing.expectEqual(@as(usize, 0), shell.history.items.len);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "disabled") != null);

    output.clearRetainingCapacity();
    try shell.historyCommand(&.{ "history", "enable" }, &output);
    try std.testing.expect(shell.history_enabled);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "enabled") != null);
}

test "shouldRedactHistory keeps secrets out of persisted history" {
    // Commands that almost certainly carry credentials are redacted (kept off
    // disk) regardless of flag casing.
    try std.testing.expect(shouldRedactHistory("mysql --password=hunter2"));
    try std.testing.expect(shouldRedactHistory("gh auth login --token abc"));
    try std.testing.expect(shouldRedactHistory("curl -H 'Authorization: Bearer xyz' url"));
    try std.testing.expect(shouldRedactHistory("export AWS_SECRET_ACCESS_KEY=zzz"));
    try std.testing.expect(shouldRedactHistory("deploy --API-KEY foo")); // case-insensitive
    // Ordinary commands are never redacted.
    try std.testing.expect(!shouldRedactHistory("git status"));
    try std.testing.expect(!shouldRedactHistory("ls -la /tmp"));
    try std.testing.expect(!shouldRedactHistory("echo hello world"));
}

test "historyDbPathAlloc defaults to home and honors override" {
    const allocator = std.testing.allocator;

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/zaphod");

    var shell = Shell.init(allocator, undefined, &env);
    defer shell.deinit();

    // Unset ZIGGYZAG_HISTORY_DB => default under $HOME (durable by default).
    const default_path = (try shell.historyDbPathAlloc()).?;
    defer allocator.free(default_path);
    try std.testing.expect(std.mem.endsWith(u8, default_path, ".ziggyzag_history.tsv"));
    try std.testing.expect(std.mem.startsWith(u8, default_path, "/home/zaphod"));

    // Explicit override wins.
    try env.put("ZIGGYZAG_HISTORY_DB", "/custom/hist.tsv");
    const override_path = (try shell.historyDbPathAlloc()).?;
    defer allocator.free(override_path);
    try std.testing.expectEqualStrings("/custom/hist.tsv", override_path);

    // Empty override disables durable history (returns null).
    try env.put("ZIGGYZAG_HISTORY_DB", "");
    try std.testing.expect((try shell.historyDbPathAlloc()) == null);
}

test "seedHistoryFromMeta populates recall list from prior-session metadata" {
    const allocator = std.testing.allocator;

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    var shell = Shell.init(allocator, undefined, &env);
    defer shell.deinit();

    // Two metadata rows as if loaded from a durable file at startup.
    try shell.history_meta.append(allocator, .{
        .command = try allocator.dupe(u8, "git status"),
        .cwd = try allocator.dupe(u8, "/proj"),
        .status = 0,
        .duration_ms = 3,
        .timestamp = 100,
    });
    try shell.history_meta.append(allocator, .{
        .command = try allocator.dupe(u8, "zig build"),
        .cwd = try allocator.dupe(u8, "/proj"),
        .status = 0,
        .duration_ms = 900,
        .timestamp = 200,
    });

    shell.seedHistoryFromMeta();

    try std.testing.expectEqual(@as(usize, 2), shell.history.items.len);
    try std.testing.expectEqualStrings("git status", shell.history.items[0]);
    try std.testing.expectEqualStrings("zig build", shell.history.items[1]);
    // Seeded rows are not re-appended by a later `history -a`.
    try std.testing.expectEqual(@as(usize, 2), shell.history_append_index);
}

test "durable history append survives a simulated restart" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "hist.tsv" });
    defer allocator.free(db_path);

    // Session 1: record + durably append a command, then drop the shell.
    {
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try env.put("ZIGGYZAG_HISTORY_DB", db_path);

        var shell = Shell.init(allocator, io, &env);
        defer shell.deinit();

        const meta = try shell.recordHistoryMeta("echo persisted", 1000, 7, 0);
        try shell.appendHistoryMetaDurable(meta);
    }

    // Session 2: a fresh shell reads the file and seeds its recall list.
    {
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try env.put("ZIGGYZAG_HISTORY_DB", db_path);

        var shell = Shell.init(allocator, io, &env);
        defer shell.deinit();

        try shell.readHistoryMetaFile(db_path);
        try std.testing.expectEqual(@as(usize, 1), shell.history_meta.items.len);
        try std.testing.expectEqualStrings("echo persisted", shell.history_meta.items[0].command);

        shell.seedHistoryFromMeta();
        try std.testing.expectEqual(@as(usize, 1), shell.history.items.len);
        try std.testing.expectEqualStrings("echo persisted", shell.history.items[0]);
    }
}

test "completionTokenStart is cursor-bounded and quote-aware" {
    // Plain word break: token starts after the last unquoted space.
    try std.testing.expectEqual(@as(usize, 4), completionTokenStart("git che"));
    // Double-quoted span keeps its internal space inside the token.
    try std.testing.expectEqual(@as(usize, 4), completionTokenStart("cat \"my fi"));
    // Single-quoted span likewise.
    try std.testing.expectEqual(@as(usize, 4), completionTokenStart("cat 'my fi"));
    // Backslash-escaped space does not break the token.
    try std.testing.expectEqual(@as(usize, 4), completionTokenStart("cat my\\ fi"));
    // First token (the command itself) starts at 0.
    try std.testing.expectEqual(@as(usize, 0), completionTokenStart("git"));
}

test "decode and encode completion tokens round-trip with quoting" {
    const allocator = std.testing.allocator;

    // Decode strips quotes/escapes to the literal path.
    const d1 = try decodeCompletionToken(allocator, "\"my file\"");
    defer allocator.free(d1);
    try std.testing.expectEqualStrings("my file", d1);

    const d2 = try decodeCompletionToken(allocator, "my\\ file");
    defer allocator.free(d2);
    try std.testing.expectEqualStrings("my file", d2);

    const d3 = try decodeCompletionToken(allocator, "'a/b c'");
    defer allocator.free(d3);
    try std.testing.expectEqualStrings("a/b c", d3);

    // Encode quotes only when needed.
    try std.testing.expect(!pathNeedsQuoting("plain.txt"));
    try std.testing.expect(pathNeedsQuoting("my file.txt"));

    const e1 = try encodeCompletionPath(allocator, "plain.txt");
    defer allocator.free(e1);
    try std.testing.expectEqualStrings("plain.txt", e1);

    const e2 = try encodeCompletionPath(allocator, "my file.txt");
    defer allocator.free(e2);
    try std.testing.expectEqualStrings("'my file.txt'", e2);

    // Embedded single quote uses the '\'' idiom.
    const e3 = try encodeCompletionPath(allocator, "a'b");
    defer allocator.free(e3);
    try std.testing.expectEqualStrings("'a'\\''b'", e3);
}

test "Tab completes the token under the cursor, not the end of line" {
    const allocator = std.testing.allocator;

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    var shell = Shell.init(allocator, undefined, &env);
    defer shell.deinit();
    // manual_echo off => no line redraw; a discarding writer absorbs any BEL.
    var sink_buf: [64]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink_buf);
    const sink = &discarding.writer;

    // Register a declarative completion so the result is deterministic.
    try shell.putCompletionCandidate("git", "checkout", "git subcommand");

    // Line: "git c| --foo" with the cursor right after "c". Completion must act
    // on the "c" token and leave " --foo" intact.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try line.appendSlice(allocator, "git c --foo");
    var cursor: usize = 5; // just after "git c"

    try shell.completeCommand(&line, &cursor, sink);

    try std.testing.expectEqualStrings("git checkout --foo", line.items);
    // Cursor sits after the inserted completion and its trailing space.
    try std.testing.expectEqual(@as(usize, "git checkout ".len), cursor);
}

test "path completion quotes a filename with spaces" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    var shell = Shell.init(allocator, io, &env);
    defer shell.deinit();
    var sink_buf: [64]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink_buf);
    const sink = &discarding.writer;

    // Create a tmp dir with a spaced filename and an absolute path to it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "my report.txt", .data = "x" });

    const rel_dir = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(rel_dir);
    const abs_dir = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_dir, allocator);
    defer allocator.free(abs_dir);

    // Type: `cat <abs_dir>/my ` and Tab — the unique match is "my report.txt".
    const typed = try std.fmt.allocPrint(allocator, "cat {s}/my", .{abs_dir});
    defer allocator.free(typed);

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try line.appendSlice(allocator, typed);
    var cursor: usize = line.items.len;

    try shell.completeCommand(&line, &cursor, sink);

    // The spaced path must be inserted quoted so it parses as one argument.
    const expected = try std.fmt.allocPrint(allocator, "cat '{s}/my report.txt' ", .{abs_dir});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, line.items);
}

test "classifyHighlight tags command head, operators, and variables" {
    const allocator = std.testing.allocator;
    const line = "git status | grep $X";
    const kinds = try allocator.alloc(HighlightKind, line.len);
    defer allocator.free(kinds);

    // Head "git" spans [0,3); say it resolved as a valid executable.
    classifyHighlight(line, 0, 3, .valid, kinds);

    // Command head is colored by validity.
    try std.testing.expectEqual(HighlightKind.command_valid, kinds[0]); // g
    try std.testing.expectEqual(HighlightKind.command_valid, kinds[2]); // t
    // "status" is a plain argument.
    try std.testing.expectEqual(HighlightKind.plain, kinds[4]); // s
    // The pipe is an operator.
    try std.testing.expectEqual(HighlightKind.operator, kinds[std.mem.indexOfScalar(u8, line, '|').?]);
    // The `$` is a variable sigil.
    try std.testing.expectEqual(HighlightKind.variable, kinds[std.mem.indexOfScalar(u8, line, '$').?]);
}

test "classifyHighlight treats quoted spans as strings, suppressing operators inside" {
    const allocator = std.testing.allocator;
    const line = "echo \"a | b $c\" tail";
    const kinds = try allocator.alloc(HighlightKind, line.len);
    defer allocator.free(kinds);

    classifyHighlight(line, 0, 4, .builtin, kinds);

    // Everything from the opening quote to the closing quote is a string,
    // including the `|` and `$` that would otherwise be operator/variable.
    const open = std.mem.indexOfScalar(u8, line, '"').?;
    const close = std.mem.lastIndexOfScalar(u8, line, '"').?;
    var i = open;
    while (i <= close) : (i += 1) {
        try std.testing.expectEqual(HighlightKind.string, kinds[i]);
    }
    // The word after the closing quote is plain again.
    try std.testing.expectEqual(HighlightKind.plain, kinds[close + 2]); // 't' of "tail"
    // A backslash outside quotes keeps `$` from reading as a variable.
    const esc_line = "x \\$y";
    const esc_kinds = try allocator.alloc(HighlightKind, esc_line.len);
    defer allocator.free(esc_kinds);
    classifyHighlight(esc_line, 0, 1, .invalid, esc_kinds);
    try std.testing.expectEqual(HighlightKind.plain, esc_kinds[std.mem.indexOfScalar(u8, esc_line, '$').?]);
}

test "highlight builtin toggles the enabled flag" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    var shell = Shell.init(allocator, undefined, &env);
    defer shell.deinit();
    try std.testing.expect(shell.highlight_enabled); // default on

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try shell.highlightCommand(&.{ "highlight", "off" }, &out);
    try std.testing.expect(!shell.highlight_enabled);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "off") != null);

    out.clearRetainingCapacity();
    try shell.highlightCommand(&.{ "highlight", "toggle" }, &out);
    try std.testing.expect(shell.highlight_enabled);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "on") != null);
}

test "writeHighlightedLine emits nothing extra when highlighting is off" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    var shell = Shell.init(allocator, undefined, &env);
    defer shell.deinit();
    shell.highlight_enabled = false;
    shell.manual_echo = true; // so writeHighlightedLine would normally color

    // Fixed writer so we can inspect exact bytes.
    var out_buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);

    try shell.writeHighlightedLine(&w, "git status");
    // With highlighting off the line is passed through verbatim — no ESC.
    try std.testing.expectEqualStrings("git status", w.buffered());
    try std.testing.expect(std.mem.indexOfScalar(u8, w.buffered(), 0x1b) == null);
}

test "backslash-newline line continuation outside quotes" {
    // A backslash immediately before a newline is a POSIX line continuation:
    // both characters are consumed and nothing is emitted.
    var parsed = try parseCommand(std.testing.allocator, "echo hel\\\nlo");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.argv.items.len);
    try std.testing.expectEqualStrings("echo", parsed.argv.items[0]);
    try std.testing.expectEqualStrings("hello", parsed.argv.items[1]);
}

test "backslash-newline line continuation inside double quotes" {
    // Inside double quotes, backslash-newline is also a continuation.
    var parsed = try parseCommand(std.testing.allocator, "echo \"hel\\\nlo\"");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.argv.items.len);
    try std.testing.expectEqualStrings("echo", parsed.argv.items[0]);
    try std.testing.expectEqualStrings("hello", parsed.argv.items[1]);
}

test "backslash before non-newline still escapes" {
    // Ensure the continuation change didn't regress normal backslash escaping.
    var parsed = try parseCommand(std.testing.allocator, "echo he\\llo");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.argv.items.len);
    try std.testing.expectEqualStrings("echo", parsed.argv.items[0]);
    // Outer unquoted \l → l (backslash escapes the 'l').
    try std.testing.expectEqualStrings("hello", parsed.argv.items[1]);
}

test "parse fd-dup redirection 2>&1" {
    // `2>&1` should set stderr_redirect with dup_source=.stdout, not write to
    // a file named "&1".
    var parsed = try parseCommand(std.testing.allocator, "cmd 2>&1");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.argv.items.len);
    try std.testing.expectEqualStrings("cmd", parsed.argv.items[0]);
    try std.testing.expect(parsed.stderr_redirect != null);
    try std.testing.expectEqual(RedirectTarget.stdout, parsed.stderr_redirect.?.dup_source.?);
    try std.testing.expect(parsed.stdout_redirect == null);
}

test "parse fd-dup redirection 1>&2" {
    var parsed = try parseCommand(std.testing.allocator, "cmd 1>&2");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.argv.items.len);
    try std.testing.expect(parsed.stdout_redirect != null);
    try std.testing.expectEqual(RedirectTarget.stderr, parsed.stdout_redirect.?.dup_source.?);
    try std.testing.expect(parsed.stderr_redirect == null);
}

test "parse fd-dup alongside regular redirect" {
    // `cmd > out.txt 2>&1` — stdout to file, stderr duplicated from stdout's destination.
    var parsed = try parseCommand(std.testing.allocator, "cmd > out.txt 2>&1");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.argv.items.len);
    try std.testing.expect(parsed.stdout_redirect != null);
    try std.testing.expectEqualStrings("out.txt", parsed.stdout_redirect.?.path);
    try std.testing.expect(parsed.stdout_redirect.?.dup_source == null);
    try std.testing.expect(parsed.stderr_redirect != null);
    try std.testing.expectEqual(RedirectTarget.stdout, parsed.stderr_redirect.?.dup_source.?);
}

test "parse fd-dup >&2 (stdout to stderr)" {
    var parsed = try parseCommand(std.testing.allocator, "cmd >&2");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.argv.items.len);
    try std.testing.expect(parsed.stdout_redirect != null);
    try std.testing.expectEqual(RedirectTarget.stderr, parsed.stdout_redirect.?.dup_source.?);
}

test "completer output line count is bounded" {
    // Build a synthetic stdout blob with more lines than max_completer_output_lines.
    // Every line starts with "pfx" so all are accepted by the prefix filter.
    const over = max_completer_output_lines + 50;
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(std.testing.allocator);
    for (0..over) |idx| {
        try blob.appendSlice(std.testing.allocator, "pfx");
        const digits = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{idx});
        defer std.testing.allocator.free(digits);
        try blob.appendSlice(std.testing.allocator, digits);
        try blob.append(std.testing.allocator, '\n');
    }

    var matches: std.ArrayList([]u8) = .empty;
    defer {
        for (matches.items) |item| std.testing.allocator.free(item);
        matches.deinit(std.testing.allocator);
    }

    // Exercise the production helper directly — this is the same path taken by
    // addCompleterMatches, so deleting or raising the bound in production would
    // fail this test.
    try collectCompleterLines(std.testing.allocator, blob.items, "pfx", &matches);

    try std.testing.expect(matches.items.len <= max_completer_output_lines);
    try std.testing.expectEqual(@as(usize, max_completer_output_lines), matches.items.len);
}

test {
    // Force compilation + test discovery for the durable history backend.
    // Now imported by runtime code (`history import`/`export`); this keeps its
    // unit tests in the shell test run.
    _ = history_backend;
}

test "OSC 7777 applies a known theme id and clears the prompt snapshot" {
    // Theme Protocol v2: the desktop host emits `7777;ziggyzag.theme=<id>` and
    // the shell consumes it from its input stream without echoing. This test
    // exercises the payload parser directly; the wire-level consumption is
    // covered by the `handleOscSequence` byte-loop tests below.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var shell = Shell.init(std.testing.allocator, undefined, &env);
    defer shell.deinit();
    try std.testing.expectEqualStrings("ziggy", shell.current_theme.id);
    shell.prompt_snapshot_valid = true;

    applyOscPayload(&shell, "7777;ziggyzag.theme=tokyo-night");
    try std.testing.expectEqualStrings("tokyo-night", shell.current_theme.id);
    try std.testing.expect(!shell.prompt_snapshot_valid);
}

test "OSC 7777 with unknown theme leaves state untouched" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var shell = Shell.init(std.testing.allocator, undefined, &env);
    defer shell.deinit();
    shell.prompt_snapshot_valid = true;

    applyOscPayload(&shell, "7777;ziggyzag.theme=does-not-exist");
    try std.testing.expectEqualStrings("ziggy", shell.current_theme.id);
    try std.testing.expect(shell.prompt_snapshot_valid);
}

test "OSC payload with non-7777 code is ignored" {
    // Other OSC codes (window title, hyperlink, clipboard) should drain
    // silently without ever touching the theme state.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var shell = Shell.init(std.testing.allocator, undefined, &env);
    defer shell.deinit();
    shell.prompt_snapshot_valid = true;

    applyOscPayload(&shell, "0;window title");
    applyOscPayload(&shell, "8;;https://example.com");
    applyOscPayload(&shell, "777;cwd=/tmp");
    try std.testing.expectEqualStrings("ziggy", shell.current_theme.id);
    try std.testing.expect(shell.prompt_snapshot_valid);
}

test "OSC payload with malformed body is ignored" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var shell = Shell.init(std.testing.allocator, undefined, &env);
    defer shell.deinit();

    applyOscPayload(&shell, "7777"); // no separator
    applyOscPayload(&shell, "7777;"); // empty body
    applyOscPayload(&shell, "7777;no-equals"); // no key=value
    applyOscPayload(&shell, "7777;wrong.key=ziggy"); // unknown key
    try std.testing.expectEqualStrings("ziggy", shell.current_theme.id);
}

test "theme init reads ZIGGYZAG_THEME env var" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZIGGYZAG_THEME", "tokyo-night");

    var shell = Shell.init(std.testing.allocator, undefined, &env);
    defer shell.deinit();

    try std.testing.expectEqualStrings("tokyo-night", shell.current_theme.id);
    try std.testing.expectEqualStrings("Tokyo Night", shell.current_theme.name);
}

test "theme init falls back to ziggy when env unset or unknown" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var unset_shell = Shell.init(std.testing.allocator, undefined, &env);
    defer unset_shell.deinit();
    try std.testing.expectEqualStrings("ziggy", unset_shell.current_theme.id);

    try env.put("ZIGGYZAG_THEME", "no-such-theme");
    var unknown_shell = Shell.init(std.testing.allocator, undefined, &env);
    defer unknown_shell.deinit();
    try std.testing.expectEqualStrings("ziggy", unknown_shell.current_theme.id);
}

test "theme builtin reports current theme" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZIGGYZAG_THEME", "dracula");

    var shell = Shell.init(std.testing.allocator, undefined, &env);
    defer shell.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try shell.themeCommand(&.{"theme"}, &output);
    try std.testing.expectEqualStrings("dracula (Dracula)\n", output.items);
}

test "theme builtin switches active theme and emits --json" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var shell = Shell.init(std.testing.allocator, undefined, &env);
    defer shell.deinit();
    try std.testing.expectEqualStrings("ziggy", shell.current_theme.id);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try shell.themeCommand(&.{ "theme", "nord" }, &output);
    try std.testing.expectEqualStrings("nord", shell.current_theme.id);

    output.clearRetainingCapacity();
    try shell.themeCommand(&.{ "theme", "--json" }, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"id\":\"nord\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"accent\":\"#88c0d0\"") != null);
}

test "theme builtin rejects unknown theme with status 2" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var shell = Shell.init(std.testing.allocator, undefined, &env);
    defer shell.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try shell.themeCommand(&.{ "theme", "not-a-theme" }, &output);

    try std.testing.expectEqual(@as(u8, 2), shell.last_status);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "unknown theme") != null);
    try std.testing.expectEqualStrings("ziggy", shell.current_theme.id);
}

test "TSV field escape and unescape round-trip" {
    // Regression for a bug where history metadata was written at exit but
    // never read at startup. The fix added unescapeTsvFieldAlloc; this test
    // pins the round-trip so future format changes can't silently break it.
    const cases = [_][]const u8{
        "simple",
        "with\ttab",
        "with\nnewline",
        "with\rreturn",
        "with\\backslash",
        "mixed \\t\t\\n\n end",
        "",
        "/path/with spaces/and-symbols!@#$%^&*()",
    };
    for (cases) |input| {
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(std.testing.allocator);
        try appendTsvField(std.testing.allocator, &encoded, input);
        // Encoded form must contain neither a raw tab nor a raw newline.
        try std.testing.expect(std.mem.indexOfScalar(u8, encoded.items, '\t') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, encoded.items, '\n') == null);

        const decoded = try unescapeTsvFieldAlloc(std.testing.allocator, encoded.items);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualStrings(input, decoded);
    }
}

test "JSON encoder escapes all sub-0x20 control bytes" {
    // Regression for a bug where appendJsonString only escaped \n, \r, \t and
    // emitted raw NUL/BEL/VT bytes, producing invalid JSON.
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    try appendJsonString(std.testing.allocator, &buffer, "\x00\x01\x07\x0b\x1f");
    try std.testing.expectEqualStrings("\"\\u0000\\u0001\\u0007\\u000b\\u001f\"", buffer.items);

    buffer.clearRetainingCapacity();
    try appendJsonString(std.testing.allocator, &buffer, "tab\there\nlinebreak\rback\x08space");
    try std.testing.expectEqualStrings("\"tab\\there\\nlinebreak\\rback\\bspace\"", buffer.items);

    buffer.clearRetainingCapacity();
    try appendJsonString(std.testing.allocator, &buffer, "quote\"and\\slash");
    try std.testing.expectEqualStrings("\"quote\\\"and\\\\slash\"", buffer.items);
}

test "theme builtin list marks the current selection" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZIGGYZAG_THEME", "gruvbox-dark");

    var shell = Shell.init(std.testing.allocator, undefined, &env);
    defer shell.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try shell.themeCommand(&.{ "theme", "list" }, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "* gruvbox-dark") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "  ziggy") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Tokyo Night") != null);
}

pub fn main(init_data: std.process.Init) !void {
    var shell = Shell.init(init_data.gpa, init_data.io, init_data.environ_map);
    defer shell.deinit();
    try shell.run();
}
