const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;

const Shell = struct {
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    history: std.ArrayList([]u8),
    manual_echo: bool,

    fn init(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map) Shell {
        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .history = .empty,
            .manual_echo = false,
        };
    }

    fn deinit(self: *Shell) void {
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.deinit(self.allocator);
    }

    fn run(self: *Shell) !void {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin = std.Io.File.stdin().readerStreaming(self.io, &stdin_buffer);
        var stdout = std.Io.File.stdout().writer(self.io, &.{});
        const terminal_mode = try TerminalMode.enable();
        defer if (terminal_mode) |mode| mode.restore();
        self.manual_echo = terminal_mode != null;
        defer self.manual_echo = false;

        while (true) {
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
                    if (self.manual_echo) try stdout.writeByte('\n');
                    return try line.toOwnedSlice(self.allocator);
                },
                '\r' => {},
                '\t' => try self.completeCommand(&line, stdout),
                0x08, 0x7f => {
                    if (line.items.len > 0) {
                        _ = line.pop();
                        if (self.manual_echo) try stdout.writeAll("\x08 \x08");
                    }
                },
                else => {
                    try line.append(self.allocator, byte);
                    if (self.manual_echo) try stdout.writeByte(byte);
                },
            }
        }
    }

    fn completeCommand(self: *Shell, line: *std.ArrayList(u8), stdout: *std.Io.Writer) !void {
        for (line.items) |c| {
            if (c == ' ' or c == '\t') {
                try stdout.writeByte(0x07);
                return;
            }
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

        if (matches.items.len != 1) {
            try stdout.writeByte(0x07);
            return;
        }

        const completion = matches.items[0];
        if (completion.len > prefix.len) {
            const suffix = completion[prefix.len..];
            try line.appendSlice(self.allocator, suffix);
            try stdout.writeAll(suffix);
        }

        try line.append(self.allocator, ' ');
        try stdout.writeByte(' ');
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
        for (matches.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        try matches.append(self.allocator, try self.allocator.dupe(u8, name));
    }

    fn execute(self: *Shell, line: []const u8) !bool {
        if (hasUnquotedPipe(line)) {
            try self.runViaSystemShell(line);
            return true;
        }

        var parsed = try parseCommand(self.allocator, line);
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
            try self.printHistory(parsed.argv.items, &stdout_buffer);
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

        if (std.mem.eql(u8, command, "jobs")) {
            var stdout_buffer: std.ArrayList(u8) = .empty;
            defer stdout_buffer.deinit(self.allocator);
            var stderr_buffer: std.ArrayList(u8) = .empty;
            defer stderr_buffer.deinit(self.allocator);
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
            try self.runViaSystemShell(line);
            return true;
        }

        try self.runViaSystemShell(line);
        return true;
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

    fn printWorkingDirectory(self: *Shell, stdout_buffer: *std.ArrayList(u8)) !void {
        const cwd = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd);
        try appendFmt(self.allocator, stdout_buffer, "{s}\n", .{cwd});
    }

    fn printHistory(self: *Shell, argv: []const []const u8, stdout_buffer: *std.ArrayList(u8)) !void {
        const limit = if (argv.len >= 2) std.fmt.parseInt(usize, argv[1], 10) catch self.history.items.len else self.history.items.len;
        const start = if (limit < self.history.items.len) self.history.items.len - limit else 0;

        for (self.history.items[start..], start..) |entry, index| {
            try appendFmt(self.allocator, stdout_buffer, "{d: >5}  {s}\n", .{ index + 1, entry });
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
                try appendFmt(self.allocator, stdout_buffer, "declare: `{s}': not a valid identifier\n", .{name});
                continue;
            }

            try self.env.put(name, assignment[eq + 1 ..]);
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
        if (builtin.os.tag == .windows) {
            var argv = [_][]const u8{ "cmd", "/C", line };
            var child = try std.process.spawn(self.io, .{
                .argv = &argv,
                .environ_map = self.env,
            });
            _ = try child.wait(self.io);
        } else {
            var argv = [_][]const u8{ "/bin/sh", "-c", line };
            var child = try std.process.spawn(self.io, .{
                .argv = &argv,
                .environ_map = self.env,
            });
            _ = try child.wait(self.io);
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
    var parsed = try parseTokens(allocator, line);
    errdefer parsed.deinit();
    try parsed.extractRedirections();
    return parsed;
}

fn parseTokens(allocator: Allocator, line: []const u8) !ParsedCommand {
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

fn appendFmt(allocator: Allocator, buffer: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try buffer.appendSlice(allocator, text);
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
};

fn isShellBuiltin(name: []const u8) bool {
    for (shell_builtin_names) |builtin_name| {
        if (std.mem.eql(u8, name, builtin_name)) return true;
    }
    return false;
}

fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

pub fn main(init_data: std.process.Init) !void {
    var shell = Shell.init(init_data.gpa, init_data.io, init_data.environ_map);
    defer shell.deinit();
    try shell.run();
}
