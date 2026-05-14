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

const AliasSpec = struct {
    name: []u8,
    value: []u8,
};

const BackgroundJob = struct {
    number: usize,
    child: std.process.Child,
    command: []u8,
    done: bool = false,
};

const Shell = struct {
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    history: std.ArrayList([]u8),
    history_append_index: usize,
    completion_specs: std.ArrayList(CompletionSpec),
    aliases: std.ArrayList(AliasSpec),
    background_jobs: std.ArrayList(BackgroundJob),
    manual_echo: bool,
    last_completion_prefix: ?[]u8,

    fn init(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map) Shell {
        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .history = .empty,
            .history_append_index = 0,
            .completion_specs = .empty,
            .aliases = .empty,
            .background_jobs = .empty,
            .manual_echo = false,
            .last_completion_prefix = null,
        };
    }

    fn deinit(self: *Shell) void {
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.deinit(self.allocator);
        for (self.completion_specs.items) |spec| {
            self.allocator.free(spec.command);
            self.allocator.free(spec.completer);
        }
        self.completion_specs.deinit(self.allocator);
        for (self.aliases.items) |alias| {
            self.allocator.free(alias.name);
            self.allocator.free(alias.value);
        }
        self.aliases.deinit(self.allocator);
        for (self.background_jobs.items) |*job| {
            job.child.kill(self.io);
            self.allocator.free(job.command);
        }
        self.background_jobs.deinit(self.allocator);
        self.clearCompletionState();
    }

    fn run(self: *Shell) !void {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin = std.Io.File.stdin().readerStreaming(self.io, &stdin_buffer);
        var stdout = std.Io.File.stdout().writer(self.io, &.{});
        const terminal_mode = try TerminalMode.enable();
        defer if (terminal_mode) |mode| mode.restore();
        self.manual_echo = terminal_mode != null;
        defer self.manual_echo = false;

        const histfile = self.env.get("HISTFILE");
        if (histfile) |path| {
            self.readHistoryFile(path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            self.history_append_index = self.history.items.len;
        }
        defer if (histfile) |path| self.writeHistoryFile(path, false, 0) catch {};

        while (true) {
            try self.reapAndPrintDoneJobs();
            try stdout.interface.print("$ ", .{});

            const owned_line = try self.readLine(&stdin.interface, &stdout.interface) orelse break;
            defer self.allocator.free(owned_line);
            if (owned_line.len == 0) continue;

            try self.history.append(self.allocator, try self.allocator.dupe(u8, owned_line));
            const keep_running = try self.execute(owned_line);
            if (!keep_running) break;
        }
    }

    fn readLine(self: *Shell, reader: *std.Io.Reader, stdout: *std.Io.Writer) !?[]u8 {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(self.allocator);
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
                    if (self.manual_echo) try stdout.writeByte('\n');
                    return try line.toOwnedSlice(self.allocator);
                },
                '\r' => {},
                '\t' => try self.completeCommand(&line, stdout),
                0x1b => try self.handleEscapeSequence(reader, stdout, &line, &history_index, &draft_line),
                0x08, 0x7f => {
                    self.clearCompletionState();
                    if (line.items.len > 0) {
                        _ = line.pop();
                        if (self.manual_echo) try stdout.writeAll("\x08 \x08");
                    }
                },
                else => {
                    self.clearCompletionState();
                    try line.append(self.allocator, byte);
                    if (self.manual_echo) try stdout.writeByte(byte);
                },
            }
        }
    }

    fn handleEscapeSequence(
        self: *Shell,
        reader: *std.Io.Reader,
        stdout: *std.Io.Writer,
        line: *std.ArrayList(u8),
        history_index: *usize,
        draft_line: *?[]u8,
    ) !void {
        const introducer = reader.takeByte() catch return;
        if (introducer != '[' and introducer != 'O') return;

        const key = reader.takeByte() catch return;
        switch (key) {
            'A' => try self.navigateHistory(.previous, stdout, line, history_index, draft_line),
            'B' => try self.navigateHistory(.next, stdout, line, history_index, draft_line),
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
            },
            .next => {
                if (history_index.* + 1 < self.history.items.len) {
                    history_index.* += 1;
                    try self.replaceCurrentLine(line, self.history.items[history_index.*]);
                } else {
                    history_index.* = self.history.items.len;
                    try self.replaceCurrentLine(line, draft_line.* orelse "");
                }
            },
        }

        try self.redrawPromptLine(stdout, line.items);
    }

    fn replaceCurrentLine(self: *Shell, line: *std.ArrayList(u8), contents: []const u8) !void {
        while (line.items.len > 0) {
            _ = line.pop();
        }
        try line.appendSlice(self.allocator, contents);
    }

    fn redrawPromptLine(self: *Shell, stdout: *std.Io.Writer, line: []const u8) !void {
        if (!self.manual_echo) return;
        try stdout.writeAll("\r\x1b[2K$ ");
        try stdout.writeAll(line);
    }

    fn completeCommand(self: *Shell, line: *std.ArrayList(u8), stdout: *std.Io.Writer) !void {
        const token_start = completionTokenStart(line.items);
        if (token_start > 0) {
            if (try self.completeRegisteredCommand(line, stdout, token_start)) return;
            try self.completePathArgument(line, stdout, token_start);
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
                try stdout.writeAll(suffix);
                self.clearCompletionState();
                return;
            }

            if (self.last_completion_prefix) |last_prefix| {
                if (std.mem.eql(u8, last_prefix, prefix)) {
                    try stdout.writeByte('\n');
                    for (matches.items, 0..) |item, index| {
                        if (index != 0) try stdout.writeAll("  ");
                        try stdout.writeAll(item);
                    }
                    try stdout.writeAll("\n$ ");
                    try stdout.writeAll(line.items);
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
            try stdout.writeAll(suffix);
        }

        try line.append(self.allocator, ' ');
        try stdout.writeByte(' ');
    }

    fn completeRegisteredCommand(self: *Shell, line: *std.ArrayList(u8), stdout: *std.Io.Writer, token_start: usize) !bool {
        const command = commandNameForCompletion(line.items) orelse return false;
        const spec = self.findCompletionSpec(command) orelse return false;
        const prefix = line.items[token_start..];
        const previous_word = previousCompletionWord(line.items, token_start);

        var matches: std.ArrayList([]u8) = .empty;
        defer {
            for (matches.items) |item| self.allocator.free(item);
            matches.deinit(self.allocator);
        }

        self.addCompleterMatches(&matches, spec.completer, command, prefix, previous_word, line.items) catch {
            self.clearCompletionState();
            try stdout.writeByte(0x07);
            return true;
        };

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
                try stdout.writeAll(suffix);
                self.clearCompletionState();
                return true;
            }

            if (self.last_completion_prefix) |last_prefix| {
                if (std.mem.eql(u8, last_prefix, prefix)) {
                    try stdout.writeByte('\n');
                    for (matches.items, 0..) |item, index| {
                        if (index != 0) try stdout.writeAll("  ");
                        try stdout.writeAll(item);
                    }
                    try stdout.writeAll("\n$ ");
                    try stdout.writeAll(line.items);
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
            try stdout.writeAll(suffix);
        }

        try line.append(self.allocator, ' ');
        try stdout.writeByte(' ');
        return true;
    }

    fn completePathArgument(self: *Shell, line: *std.ArrayList(u8), stdout: *std.Io.Writer, token_start: usize) !void {
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
                try stdout.writeAll(suffix);
                self.clearCompletionState();
                return;
            }

            if (self.last_completion_prefix) |last_prefix| {
                if (std.mem.eql(u8, last_prefix, prefix)) {
                    try stdout.writeByte('\n');
                    for (matches.items, 0..) |item, index| {
                        if (index != 0) try stdout.writeAll("  ");
                        try stdout.writeAll(item.text);
                        if (item.is_directory) try stdout.writeByte('/');
                    }
                    try stdout.writeAll("\n$ ");
                    try stdout.writeAll(line.items);
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
            try stdout.writeAll(suffix);
        }

        if (completion.is_directory) {
            try line.append(self.allocator, '/');
            try stdout.writeByte('/');
        } else {
            try line.append(self.allocator, ' ');
            try stdout.writeByte(' ');
        }
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

    fn execute(self: *Shell, line: []const u8) !bool {
        const expanded_alias_line = try self.expandAliasLine(line);
        defer if (expanded_alias_line) |owned| self.allocator.free(owned);
        const active_line = expanded_alias_line orelse line;

        if (trailingBackgroundCommand(active_line)) |command_line| {
            try self.startBackgroundJob(command_line);
            return true;
        }

        if (hasUnquotedPipe(active_line)) {
            try self.runViaSystemShell(active_line);
            return true;
        }

        var parsed = try parseCommandExpanded(self.allocator, active_line, self);
        defer parsed.deinit();

        if (parsed.argv.items.len == 0) return true;
        const command = parsed.argv.items[0];

        if (std.mem.eql(u8, command, "exit")) {
            return false;
        }

        if (std.mem.eql(u8, command, "cd")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.changeDirectory(parsed.argv.items, &stderr_buffer);
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

        if (std.mem.eql(u8, command, "history")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.historyCommand(parsed.argv.items, &stdout_buffer);
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

        if (std.mem.eql(u8, command, "jobs")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try self.printJobs(&stdout_buffer);
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
            return true;
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

        if (!isShellBuiltin(command) and (try self.findExecutable(command)) == null) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
            try appendFmt(self.allocator, &stderr_buffer, "{s}: command not found\n", .{command});
            try self.emitCommandOutput(&parsed, stdout_buffer.items, stderr_buffer.items);
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

    fn changeDirectory(self: *Shell, argv: []const []const u8, stderr_buffer: *std.ArrayList(u8)) !void {
        const target = if (argv.len < 2 or std.mem.eql(u8, argv[1], "~"))
            self.env.get("HOME") orelse ""
        else
            argv[1];

        if (target.len == 0) return;
        std.process.setCurrentPath(self.io, target) catch {
            try appendFmt(self.allocator, stderr_buffer, "cd: {s}: No such file or directory\n", .{target});
        };
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
            \\  alias NAME=VALUE   Create a shortcut for a command
            \\  unalias NAME       Remove a shortcut
            \\  cd [DIR]           Change directories
            \\  complete ...       Register programmable completions
            \\  declare NAME=VALUE Store a shell variable
            \\  echo [ARGS...]     Print text
            \\  export NAME=VALUE  Store an environment variable
            \\  history [N]        View command history
            \\  jobs               List background jobs
            \\  pwd                Print the current directory
            \\  type NAME          Explain how a command resolves
            \\  unset NAME         Remove a variable
            \\  exit               Leave the shell
            \\
            \\Line editing:
            \\  Tab completion, Up/Down history navigation, redirection, pipes, and background jobs.
            \\
        );
    }

    fn printWorkingDirectory(self: *Shell, stdout_buffer: *std.ArrayList(u8)) !void {
        const cwd = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd);
        try appendFmt(self.allocator, stdout_buffer, "{s}\n", .{cwd});
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
            self.history_append_index = 0;
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

    fn printJobs(self: *Shell, stdout_buffer: *std.ArrayList(u8)) !void {
        self.refreshBackgroundJobs();
        for (self.background_jobs.items) |*job| {
            try self.appendJobLine(stdout_buffer, job);
        }
        self.removeDoneJobs();
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

    fn completeBuiltin(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        if (argv.len >= 3 and std.mem.eql(u8, argv[1], "-p")) {
            const command = argv[2];
            if (self.findCompletionSpec(command)) |spec| {
                try appendFmt(self.allocator, stdout_buffer, "complete -C '{s}' {s}\n", .{ spec.completer, spec.command });
            } else {
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
        _ = try child.wait(self.io);
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
    "echo",
    "exit",
    "type",
    "pwd",
    "cd",
    "history",
    "declare",
    "jobs",
    "complete",
    "help",
    "alias",
    "unalias",
    "export",
    "unset",
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

pub fn main(init_data: std.process.Init) !void {
    var shell = Shell.init(init_data.gpa, init_data.io, init_data.environ_map);
    defer shell.deinit();
    try shell.run();
}
