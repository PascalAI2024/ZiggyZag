const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;

const CompletionEntry = struct {
    text: []u8,
    is_directory: bool,
};

const CompletionSpec = struct {
    command: []u8,
    completer: []u8,
};

const CompletionCandidateSpec = struct {
    command: []u8,
    candidate: []u8,
    description: []u8,
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

const Shell = struct {
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    history: std.ArrayList([]u8),
    history_meta: std.ArrayList(HistoryMeta),
    history_append_index: usize,
    completion_specs: std.ArrayList(CompletionSpec),
    completion_candidates: std.ArrayList(CompletionCandidateSpec),
    aliases: std.ArrayList(AliasSpec),
    abbreviations: std.ArrayList(AbbreviationSpec),
    background_jobs: std.ArrayList(BackgroundJob),
    dir_history: std.ArrayList([]u8),
    dir_index: usize,
    manual_echo: bool,
    last_completion_prefix: ?[]u8,
    prompt_mode: PromptMode,
    prompt_snapshot: PromptSnapshot,
    prompt_snapshot_valid: bool,
    last_status: u8,
    last_duration_ms: i64,

    fn init(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map) Shell {
        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .history = .empty,
            .history_meta = .empty,
            .history_append_index = 0,
            .completion_specs = .empty,
            .completion_candidates = .empty,
            .aliases = .empty,
            .abbreviations = .empty,
            .background_jobs = .empty,
            .dir_history = .empty,
            .dir_index = 0,
            .manual_echo = false,
            .last_completion_prefix = null,
            .prompt_mode = .classic,
            .prompt_snapshot = .{},
            .prompt_snapshot_valid = false,
            .last_status = 0,
            .last_duration_ms = 0,
        };
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
        self.clearCompletionState();
    }

    fn run(self: *Shell) !void {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin = std.Io.File.stdin().readerStreaming(self.io, &stdin_buffer);
        var stdout = std.Io.File.stdout().writer(self.io, &.{});

        try self.loadStartupConfig();
        try self.rememberCurrentDirectory(false);

        const terminal_mode = try TerminalMode.enable();
        defer if (terminal_mode) |mode| mode.restore();
        self.manual_echo = terminal_mode != null;
        defer self.manual_echo = false;

        const histfile = self.env.get("HISTFILE");
        const history_meta_file = self.env.get("ZIGGYZAG_HISTORY_DB");
        if (histfile) |path| {
            self.readHistoryFile(path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            self.history_append_index = self.history.items.len;
        }
        defer if (histfile) |path| self.writeHistoryFile(path, false, 0) catch {};
        defer if (history_meta_file) |path| self.writeHistoryMetaFile(path) catch {};

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

            try self.history.append(self.allocator, try self.allocator.dupe(u8, submitted_line));
            const command_id = self.history.items.len;
            const started_at = std.Io.Clock.real.now(self.io).toMilliseconds();
            try self.writeIntegrationCommandStarted(&stdout.interface, command_id, submitted_line, started_at);
            const keep_running = try self.execute(submitted_line);
            self.last_duration_ms = std.Io.Clock.real.now(self.io).toMilliseconds() - started_at;
            self.prompt_snapshot_valid = false;
            try self.recordHistoryMeta(submitted_line, started_at, self.last_duration_ms, self.last_status);
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
                    if (line.items.len == 0) {
                        line.deinit(self.allocator);
                        return null;
                    }
                    return try line.toOwnedSlice(self.allocator);
                },
                else => |e| return e,
            };

            switch (byte) {
                '\n' => {
                    self.clearCompletionState();
                    if (self.manual_echo) {
                        try self.redrawPromptLine(stdout, line.items, line.items.len);
                        try stdout.writeByte('\n');
                    }
                    return try line.toOwnedSlice(self.allocator);
                },
                '\r' => {},
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
                0x12 => try self.acceptFuzzyHistoryMatch(stdout, &line, &cursor),
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
        if (self.prompt_snapshot_valid and std.mem.eql(u8, cwd, self.prompt_snapshot.cwdSlice())) {
            return &self.prompt_snapshot;
        }

        self.prompt_snapshot = .{};
        self.prompt_snapshot.cwd_len = copyBounded(self.prompt_snapshot.cwd[0..], cwd);
        self.prompt_snapshot.project_kind = self.detectProjectKindFrom(cwd) catch null;
        self.prompt_snapshot.git = self.gitPromptStatus(cwd) catch .{};
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

        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "git", "-C", cwd, "status", "--porcelain=v1", "--branch" },
            .environ_map = self.env,
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

    fn writeHighlightedLine(self: *Shell, stdout: *std.Io.Writer, line: []const u8) !void {
        if (self.prompt_mode == .classic or line.len == 0) {
            try stdout.writeAll(line);
            return;
        }

        const start = firstNonWhitespace(line);
        const end = if (start < line.len) simpleCommandWordEnd(line, start) else start;
        if (end <= start) {
            try stdout.writeAll(line);
            return;
        }

        try stdout.writeAll(line[0..start]);
        const command = line[start..end];
        if (isShellBuiltin(command)) {
            try stdout.writeAll("\x1b[32m");
        } else if (try self.findExecutable(command)) |path| {
            self.allocator.free(path);
            try stdout.writeAll("\x1b[36m");
        } else {
            try stdout.writeAll("\x1b[31m");
        }
        try stdout.writeAll(command);
        try stdout.writeAll("\x1b[0m");

        var index = end;
        while (index < line.len) : (index += 1) {
            const c = line[index];
            if (c == '|' or c == '>' or c == '<') {
                try stdout.writeAll("\x1b[35m");
                try stdout.writeByte(c);
                try stdout.writeAll("\x1b[0m");
            } else if (c == '$') {
                try stdout.writeAll("\x1b[33m");
                try stdout.writeByte(c);
                try stdout.writeAll("\x1b[0m");
            } else {
                try stdout.writeByte(c);
            }
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
        if (cursor.* != line.items.len) {
            self.clearCompletionState();
            if (self.manual_echo) try stdout.writeByte(0x07);
            return;
        }

        const token_start = completionTokenStart(line.items);
        if (token_start > 0) {
            if (try self.completeRegisteredCommand(line, cursor, stdout, token_start)) return;
            try self.completePathArgument(line, cursor, stdout, token_start);
            return;
        }

        const prefix = line.items;
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
                const suffix = common_prefix[prefix.len..];
                try line.appendSlice(self.allocator, suffix);
                cursor.* = line.items.len;
                try stdout.writeAll(suffix);
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
            const suffix = completion[prefix.len..];
            try line.appendSlice(self.allocator, suffix);
            cursor.* = line.items.len;
            try stdout.writeAll(suffix);
        }

        try line.append(self.allocator, ' ');
        cursor.* = line.items.len;
        try stdout.writeByte(' ');
    }

    fn completeRegisteredCommand(self: *Shell, line: *std.ArrayList(u8), cursor: *usize, stdout: *std.Io.Writer, token_start: usize) !bool {
        const command = commandNameForCompletion(line.items) orelse return false;
        const spec = self.findCompletionSpec(command);
        if (spec == null and !self.hasDeclarativeCompletions(command)) return false;
        const prefix = line.items[token_start..];
        const previous_word = previousCompletionWord(line.items, token_start);

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
                const suffix = common_prefix[prefix.len..];
                try line.appendSlice(self.allocator, suffix);
                cursor.* = line.items.len;
                try stdout.writeAll(suffix);
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
            const suffix = completion[prefix.len..];
            try line.appendSlice(self.allocator, suffix);
            cursor.* = line.items.len;
            try stdout.writeAll(suffix);
        }

        try line.append(self.allocator, ' ');
        cursor.* = line.items.len;
        try stdout.writeByte(' ');
        return true;
    }

    fn completePathArgument(self: *Shell, line: *std.ArrayList(u8), cursor: *usize, stdout: *std.Io.Writer, token_start: usize) !void {
        const prefix = line.items[token_start..];
        var matches: std.ArrayList(CompletionEntry) = .empty;
        defer {
            for (matches.items) |item| self.allocator.free(item.text);
            matches.deinit(self.allocator);
        }

        try self.addPathCompletions(&matches, prefix);

        if (matches.items.len == 0) {
            self.clearCompletionState();
            try stdout.writeByte(0x07);
            return;
        }

        sortCompletionEntries(matches.items);
        if (matches.items.len > 1) {
            const common_prefix = longestCommonPrefixEntries(matches.items);
            if (common_prefix.len > prefix.len) {
                const suffix = common_prefix[prefix.len..];
                try line.appendSlice(self.allocator, suffix);
                cursor.* = line.items.len;
                try stdout.writeAll(suffix);
                self.clearCompletionState();
                return;
            }

            if (self.last_completion_prefix) |last_prefix| {
                if (std.mem.eql(u8, last_prefix, prefix)) {
                    try self.printPathCompletionPager(stdout, matches.items, line.items);
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
        if (completion.text.len > prefix.len) {
            const suffix = completion.text[prefix.len..];
            try line.appendSlice(self.allocator, suffix);
            cursor.* = line.items.len;
            try stdout.writeAll(suffix);
        }

        if (completion.is_directory) {
            try line.append(self.allocator, '/');
            cursor.* = line.items.len;
            try stdout.writeByte('/');
        } else {
            try line.append(self.allocator, ' ');
            cursor.* = line.items.len;
            try stdout.writeByte(' ');
        }
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

        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |raw_line| {
            const candidate = trimTrailingCarriageReturn(raw_line);
            try self.addCompletionMatch(matches, prefix, candidate);
        }
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

        var parsed = try parseCommandExpanded(self.allocator, active_line, self);
        defer parsed.deinit();

        if (parsed.argv.items.len == 0) return true;
        const command = parsed.argv.items[0];
        self.last_status = 0;

        if (std.mem.eql(u8, command, "exit")) {
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
            try self.helpCommand(&stdout_buffer);
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

        if (parsed.hasRedirection()) {
            try self.runViaSystemShell(active_line);
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
        var stdout = std.Io.File.stdout().writer(self.io, &.{});
        try stdout.interface.writeAll(stdout_buffer.items);
        self.last_status = 0;
        return true;
    }

    fn changeDirectory(self: *Shell, argv: []const []const u8, stderr_buffer: *std.ArrayList(u8)) !bool {
        const target = if (argv.len < 2 or std.mem.eql(u8, argv[1], "~"))
            self.env.get("HOME") orelse ""
        else
            argv[1];

        if (target.len == 0) return true;
        std.process.setCurrentPath(self.io, target) catch {
            try appendFmt(self.allocator, stderr_buffer, "cd: {s}: No such file or directory\n", .{target});
            self.last_status = 1;
            return false;
        };
        return true;
    }

    fn typeCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (argv.len < 2) return;

        for (argv[1..]) |name| {
            if (isShellBuiltin(name)) {
                try appendFmt(self.allocator, stdout_buffer, "{s} is a shell builtin\n", .{name});
            } else if (try self.findExecutable(name)) |path| {
                defer self.allocator.free(path);
                try appendFmt(self.allocator, stdout_buffer, "{s} is {s}\n", .{ name, path });
            } else {
                try appendFmt(self.allocator, stdout_buffer, "{s}: not found\n", .{name});
            }
        }
    }

    fn whichCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        const json = hasArg(argv, "--json");
        for (argv[1..]) |name| {
            if (std.mem.startsWith(u8, name, "--")) continue;

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
        }
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
        self.dir_index = if (count > self.dir_index) 0 else self.dir_index - count;
        try self.goToDirectoryIndex(stdout_buffer, stderr_buffer);
    }

    fn forwardCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) !void {
        if (self.dir_history.items.len == 0 or self.dir_index + 1 >= self.dir_history.items.len) {
            try stderr_buffer.appendSlice(self.allocator, "forward: no later directory\n");
            self.last_status = 1;
            return;
        }

        const count = if (argv.len >= 2) std.fmt.parseInt(usize, argv[1], 10) catch 1 else 1;
        self.dir_index = @min(self.dir_history.items.len - 1, self.dir_index + count);
        try self.goToDirectoryIndex(stdout_buffer, stderr_buffer);
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
        self.dir_index = target;
        try self.goToDirectoryIndex(stdout_buffer, stderr_buffer);
    }

    fn goToDirectoryIndex(self: *Shell, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8)) !void {
        if (self.dir_index >= self.dir_history.items.len) return;
        const target = self.dir_history.items[self.dir_index];
        std.process.setCurrentPath(self.io, target) catch |err| {
            try appendFmt(self.allocator, stderr_buffer, "dirs: {s}: {s}\n", .{ target, @errorName(err) });
            self.last_status = 1;
            return;
        };
        try appendFmt(self.allocator, stdout_buffer, "{s}\n", .{target});
    }

    fn echoCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        for (argv[1..], 0..) |arg, index| {
            if (index != 0) try stdout_buffer.append(self.allocator, ' ');
            try stdout_buffer.appendSlice(self.allocator, arg);
        }
        try stdout_buffer.append(self.allocator, '\n');
    }

    fn helpCommand(self: *Shell, stdout_buffer: *std.ArrayList(u8)) !void {
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
            \\  history [N]        View command history
            \\  inspect COMMAND    Explain how ZiggyZag would parse a command
            \\  jump QUERY         Fuzzy-jump to a visited directory
            \\  jobs               List background jobs
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

        if (argv.len >= 2 and std.mem.eql(u8, argv[1], "-c")) {
            for (self.history.items) |entry| self.allocator.free(entry);
            self.history.clearRetainingCapacity();
            for (self.history_meta.items) |entry| {
                self.allocator.free(entry.command);
                self.allocator.free(entry.cwd);
            }
            self.history_meta.clearRetainingCapacity();
            self.history_append_index = 0;
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

    fn loadConfigFile(self: *Shell, path: []const u8) !void {
        const file = if (std.fs.path.isAbsolute(path))
            try std.Io.Dir.openFileAbsolute(self.io, path, .{})
        else
            try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);

        var read_buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(self.io, &read_buffer);
        const contents = try reader.interface.allocRemaining(self.allocator, .unlimited);
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
        const contents = try reader.interface.allocRemaining(self.allocator, .unlimited);
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
        const contents = try reader.interface.allocRemaining(self.allocator, .unlimited);
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
                const existing = try reader.interface.allocRemaining(self.allocator, .unlimited);
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

        if (std.fs.path.isAbsolute(path)) {
            var file = try std.Io.Dir.createFileAbsolute(self.io, path, .{});
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, output.items);
        } else {
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = output.items });
        }
    }

    fn recordHistoryMeta(self: *Shell, command: []const u8, timestamp: i64, duration_ms: i64, status: u8) !void {
        const cwd_raw = std.process.currentPathAlloc(self.io, self.allocator) catch null;
        defer if (cwd_raw) |raw| self.allocator.free(raw);
        const cwd = if (cwd_raw) |raw| try self.allocator.dupe(u8, raw) else try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(cwd);
        const owned_command = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_command);

        try self.history_meta.append(self.allocator, .{
            .command = owned_command,
            .cwd = cwd,
            .status = status,
            .duration_ms = duration_ms,
            .timestamp = timestamp,
        });
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

        if (std.fs.path.isAbsolute(path)) {
            var file = try std.Io.Dir.createFileAbsolute(self.io, path, .{});
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, output.items);
        } else {
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = output.items });
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

    fn promptCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
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
        } else {
            try appendFmt(self.allocator, stdout_buffer, "prompt: {s}: expected classic, smart, compact, dev, dashboard, or themes\n", .{argv[1]});
        }
    }

    fn configCommand(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
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
                \\export ZIGGYZAG_HISTORY_DB=~/.ziggyzag-history.tsv
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
        const metadata_path = self.env.get("ZIGGYZAG_HISTORY_DB") orelse "";

        if (hasArg(argv, "--json")) {
            try stdout_buffer.appendSlice(self.allocator, "{\"prompt_mode\":");
            try appendJsonString(self.allocator, stdout_buffer, @tagName(self.prompt_mode));
            try appendFmt(self.allocator, stdout_buffer, ",\"last_status\":{d},\"last_duration_ms\":{d},\"history\":{d},\"history_meta\":{d},\"aliases\":{d},\"abbreviations\":{d},\"completion_helpers\":{d},\"completion_candidates\":{d},\"jobs\":{d},\"config_path\":", .{
                self.last_status,
                self.last_duration_ms,
                self.history.items.len,
                self.history_meta.items.len,
                self.aliases.items.len,
                self.abbreviations.items.len,
                self.completion_specs.items.len,
                self.completion_candidates.items.len,
                self.background_jobs.items.len,
            });
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
        const contents = try reader.interface.allocRemaining(self.allocator, .unlimited);
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

        var stdout = std.Io.File.stdout().writer(self.io, &.{});
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
            var stdout = std.Io.File.stdout().writer(self.io, &.{});
            try stdout.interface.writeAll(output.items);
        }

        self.removeDoneJobs();
    }

    fn refreshBackgroundJobs(self: *Shell) void {
        for (self.background_jobs.items) |*job| {
            if (!job.done and childHasExited(&job.child)) job.done = true;
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
        try self.completion_candidates.append(self.allocator, .{
            .command = owned_command,
            .candidate = owned_candidate,
            .description = owned_description,
        });
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
            var stdout = std.Io.File.stdout().writer(self.io, &.{});
            try stdout.interface.writeAll(stdout_bytes);
        }

        if (parsed.stderr_redirect) |redirect| {
            try self.writeRedirect(redirect, stderr_bytes);
        } else if (stderr_bytes.len > 0) {
            var stderr = std.Io.File.stderr().writer(self.io, &.{});
            try stderr.interface.writeAll(stderr_bytes);
        }
    }

    fn writeRedirect(self: *Shell, redirect: Redirection, bytes: []const u8) !void {
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
            const existing = try reader.interface.allocRemaining(self.allocator, .unlimited);
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
                else => |e| return e,
            };
            defer result.deinit(self.allocator);

            self.allocator.free(input);
            input = try self.allocator.dupe(u8, result.stdout);
            try stderr_output.appendSlice(self.allocator, result.stderr);
            status = result.status;
        }

        var stdout = std.Io.File.stdout().writer(self.io, &.{});
        try stdout.interface.writeAll(input);
        var stderr = std.Io.File.stderr().writer(self.io, &.{});
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

        var child = try std.process.spawn(self.io, .{
            .argv = argv.items,
            .environ_map = self.env,
            .stdin = if (input.len > 0) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        errdefer child.kill(self.io);

        if (input.len > 0) {
            var stdin_file = child.stdin.?;
            try stdin_file.writeStreamingAll(self.io, input);
            stdin_file.close(self.io);
            child.stdin = null;
        }

        var stdout_buffer: [4096]u8 = undefined;
        var stdout_reader = child.stdout.?.readerStreaming(self.io, &stdout_buffer);
        const stdout_bytes = try stdout_reader.interface.allocRemaining(self.allocator, .unlimited);
        errdefer self.allocator.free(stdout_bytes);

        var stderr_buffer: [4096]u8 = undefined;
        var stderr_reader = child.stderr.?.readerStreaming(self.io, &stderr_buffer);
        const stderr_bytes = try stderr_reader.interface.allocRemaining(self.allocator, .unlimited);
        errdefer self.allocator.free(stderr_bytes);

        const term = try child.wait(self.io);
        return .{
            .stdout = stdout_bytes,
            .stderr = stderr_bytes,
            .status = termExitCode(term),
        };
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

    fn enable() !?Self {
        return null;
    }

    fn restore(self: Self) void {
        _ = self;
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
};

const RedirectTarget = enum {
    stdout,
    stderr,
};

const RedirectionSpec = struct {
    target: RedirectTarget,
    append: bool,
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

        var index: usize = 0;
        while (index < self.argv.items.len) {
            const token = self.argv.items[index];
            if (parseRedirectionOperator(token)) |spec| {
                self.allocator.free(token);
                if (index + 1 >= self.argv.items.len) {
                    index += 1;
                    break;
                }

                const path = self.argv.items[index + 1];
                self.setRedirection(spec, path);
                index += 2;
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
        const redirect: Redirection = .{ .path = path, .append = spec.append };
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

    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        switch (c) {
            ' ', '\t' => {
                try flushToken(allocator, &argv, &current);
                i += 1;
            },
            '>' => {
                try flushToken(allocator, &argv, &current);
                if (i + 1 < line.len and line[i + 1] == '>') {
                    try appendToken(allocator, &argv, ">>");
                    i += 2;
                } else {
                    try appendToken(allocator, &argv, ">");
                    i += 1;
                }
            },
            '1', '2' => {
                if (current.items.len == 0 and i + 1 < line.len and line[i + 1] == '>') {
                    if (i + 2 < line.len and line[i + 2] == '>') {
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
                i += 1;
                while (i < line.len and line[i] != '\'') : (i += 1) {
                    try current.append(allocator, line[i]);
                }
                if (i < line.len) i += 1;
            },
            '"' => {
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
                        if (next == '$' or next == '`' or next == '"' or next == '\\' or next == '\n') {
                            try current.append(allocator, next);
                            i += 1;
                            continue;
                        }
                    }
                    try current.append(allocator, line[i]);
                }
                if (i < line.len) i += 1;
            },
            '$' => {
                if (!try appendParameterExpansion(allocator, &argv, &current, line, &i, shell, true)) {
                    try current.append(allocator, c);
                    i += 1;
                }
            },
            '\\' => {
                if (i + 1 < line.len) {
                    try current.append(allocator, line[i + 1]);
                    i += 2;
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

    try flushToken(allocator, &argv, &current);
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

fn childHasExited(child: *std.process.Child) bool {
    if (child.id == null) return true;

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

fn appendJsonString(allocator: Allocator, buffer: *std.ArrayList(u8), value: []const u8) !void {
    try buffer.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try buffer.appendSlice(allocator, "\\\""),
            '\\' => try buffer.appendSlice(allocator, "\\\\"),
            '\n' => try buffer.appendSlice(allocator, "\\n"),
            '\r' => try buffer.appendSlice(allocator, "\\r"),
            '\t' => try buffer.appendSlice(allocator, "\\t"),
            else => try buffer.append(allocator, c),
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

fn isConfigDirective(command: []const u8) bool {
    return std.mem.eql(u8, command, "alias") or
        std.mem.eql(u8, command, "abbr") or
        std.mem.eql(u8, command, "export") or
        std.mem.eql(u8, command, "complete") or
        std.mem.eql(u8, command, "prompt");
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
    if (std.mem.eql(u8, name, "cd")) return "change directory";
    if (std.mem.eql(u8, name, "complete")) return "register completions";
    if (std.mem.eql(u8, name, "config")) return "show, reload, and validate startup config";
    if (std.mem.eql(u8, name, "declare")) return "set shell variables";
    if (std.mem.eql(u8, name, "dirs")) return "show directory history";
    if (std.mem.eql(u8, name, "doctor")) return "inspect shell runtime state";
    if (std.mem.eql(u8, name, "echo")) return "print arguments";
    if (std.mem.eql(u8, name, "env")) return "show environment variables";
    if (std.mem.eql(u8, name, "exit")) return "leave the shell";
    if (std.mem.eql(u8, name, "export")) return "set environment variables";
    if (std.mem.eql(u8, name, "forward")) return "move forward in directory history";
    if (std.mem.eql(u8, name, "help")) return "show shell help";
    if (std.mem.eql(u8, name, "history")) return "show and search history";
    if (std.mem.eql(u8, name, "inspect")) return "explain command parsing and execution path";
    if (std.mem.eql(u8, name, "jump")) return "fuzzy-jump to a visited directory";
    if (std.mem.eql(u8, name, "jobs")) return "list background jobs";
    if (std.mem.eql(u8, name, "mkcd")) return "create and enter a directory";
    if (std.mem.eql(u8, name, "path")) return "show PATH entries";
    if (std.mem.eql(u8, name, "project")) return "detect project tasks";
    if (std.mem.eql(u8, name, "prompt")) return "configure prompt modules";
    if (std.mem.eql(u8, name, "pwd")) return "print current directory";
    if (std.mem.eql(u8, name, "repeat")) return "run a command multiple times";
    if (std.mem.eql(u8, name, "run")) return "run a project-aware task";
    if (std.mem.eql(u8, name, "source")) return "run commands from a file";
    if (std.mem.eql(u8, name, "timeit")) return "time a command";
    if (std.mem.eql(u8, name, "type")) return "explain command resolution";
    if (std.mem.eql(u8, name, "unalias")) return "remove an alias";
    if (std.mem.eql(u8, name, "unabbr")) return "remove an abbreviation";
    if (std.mem.eql(u8, name, "up")) return "move up parent directories";
    if (std.mem.eql(u8, name, "unset")) return "remove a variable";
    if (std.mem.eql(u8, name, "vars")) return "show shell variable map";
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

fn isCompletionWhitespace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn completionTokenStart(line: []const u8) usize {
    var start: usize = 0;
    for (line, 0..) |c, index| {
        if (isCompletionWhitespace(c)) start = index + 1;
    }
    return start;
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
    "dirs",
    "echo",
    "env",
    "exit",
    "forward",
    "type",
    "pwd",
    "cd",
    "history",
    "jump",
    "declare",
    "jobs",
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
    "repeat",
    "run",
    "source",
    "timeit",
    "up",
    "unset",
    "vars",
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
    try std.testing.expect(!isConfigDirective("rm"));
    try std.testing.expect(isValidName("ZIGGYZAG_1"));
    try std.testing.expect(!isValidName("1ZIGGYZAG"));
}

pub fn main(init_data: std.process.Init) !void {
    var shell = Shell.init(init_data.gpa, init_data.io, init_data.environ_map);
    defer shell.deinit();
    try shell.run();
}
