const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;

const Shell = struct {
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    history: std.ArrayList([]u8),

    fn init(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map) Shell {
        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .history = .empty,
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

        while (true) {
            try stdout.interface.print("$ ", .{});

            const raw_line = try stdin.interface.takeDelimiter('\n') orelse break;
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len == 0) continue;

            try self.history.append(self.allocator, try self.allocator.dupe(u8, line));
            const keep_running = try self.execute(line);
            if (!keep_running) break;
        }
    }

    fn execute(self: *Shell, line: []const u8) !bool {
        var parsed = try parseTokens(self.allocator, line);
        defer parsed.deinit();

        if (parsed.argv.items.len == 0) return true;
        const command = parsed.argv.items[0];

        if (std.mem.eql(u8, command, "exit")) {
            return false;
        }

        if (std.mem.eql(u8, command, "cd")) {
            try self.changeDirectory(parsed.argv.items);
            return true;
        }

        if (std.mem.eql(u8, command, "type")) {
            try self.typeCommand(parsed.argv.items);
            return true;
        }

        if (std.mem.eql(u8, command, "echo")) {
            try self.echoCommand(parsed.argv.items);
            return true;
        }

        if (std.mem.eql(u8, command, "pwd")) {
            try self.printWorkingDirectory();
            return true;
        }

        if (std.mem.eql(u8, command, "history")) {
            try self.printHistory(parsed.argv.items);
            return true;
        }

        if (std.mem.eql(u8, command, "declare")) {
            try self.declareVariable(parsed.argv.items);
            return true;
        }

        if (std.mem.eql(u8, command, "jobs")) {
            return true;
        }

        if (!isShellBuiltin(command) and (try self.findExecutable(command)) == null) {
            var stdout = std.Io.File.stdout().writer(self.io, &.{});
            try stdout.interface.print("{s}: command not found\n", .{command});
            return true;
        }

        try self.runViaSystemShell(line);
        return true;
    }

    fn changeDirectory(self: *Shell, argv: []const []const u8) !void {
        const target = if (argv.len < 2 or std.mem.eql(u8, argv[1], "~"))
            self.env.get("HOME") orelse ""
        else
            argv[1];

        if (target.len == 0) return;
        std.process.setCurrentPath(self.io, target) catch {
            var stdout = std.Io.File.stdout().writer(self.io, &.{});
            try stdout.interface.print("cd: {s}: No such file or directory\n", .{target});
        };
    }

    fn typeCommand(self: *Shell, argv: []const []const u8) !void {
        var stdout = std.Io.File.stdout().writer(self.io, &.{});
        if (argv.len < 2) return;

        for (argv[1..]) |name| {
            if (isShellBuiltin(name)) {
                try stdout.interface.print("{s} is a shell builtin\n", .{name});
            } else if (try self.findExecutable(name)) |path| {
                defer self.allocator.free(path);
                try stdout.interface.print("{s} is {s}\n", .{ name, path });
            } else {
                try stdout.interface.print("{s}: not found\n", .{name});
            }
        }
    }

    fn echoCommand(self: *Shell, argv: []const []const u8) !void {
        var stdout = std.Io.File.stdout().writer(self.io, &.{});
        for (argv[1..], 0..) |arg, index| {
            if (index != 0) try stdout.interface.print(" ", .{});
            try stdout.interface.print("{s}", .{arg});
        }
        try stdout.interface.print("\n", .{});
    }

    fn printWorkingDirectory(self: *Shell) !void {
        var stdout = std.Io.File.stdout().writer(self.io, &.{});
        const cwd = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd);
        try stdout.interface.print("{s}\n", .{cwd});
    }

    fn printHistory(self: *Shell, argv: []const []const u8) !void {
        var stdout = std.Io.File.stdout().writer(self.io, &.{});
        const limit = if (argv.len >= 2) std.fmt.parseInt(usize, argv[1], 10) catch self.history.items.len else self.history.items.len;
        const start = if (limit < self.history.items.len) self.history.items.len - limit else 0;

        for (self.history.items[start..], start..) |entry, index| {
            try stdout.interface.print("{d: >5}  {s}\n", .{ index + 1, entry });
        }
    }

    fn declareVariable(self: *Shell, argv: []const []const u8) !void {
        var stdout = std.Io.File.stdout().writer(self.io, &.{});
        if (argv.len == 1) {
            var it = self.env.iterator();
            while (it.next()) |entry| {
                try stdout.interface.print("declare -- {s}=\"{s}\"\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            return;
        }

        for (argv[1..]) |assignment| {
            const eq = std.mem.indexOfScalar(u8, assignment, '=') orelse {
                if (self.env.get(assignment)) |value| {
                    try stdout.interface.print("declare -- {s}=\"{s}\"\n", .{ assignment, value });
                } else {
                    try stdout.interface.print("{s}: not found\n", .{assignment});
                }
                continue;
            };

            const name = assignment[0..eq];
            if (!isValidName(name)) {
                try stdout.interface.print("declare: `{s}': not a valid identifier\n", .{name});
                continue;
            }

            try self.env.put(name, assignment[eq + 1 ..]);
        }
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

const ParsedCommand = struct {
    allocator: Allocator,
    argv: std.ArrayList([]u8),

    fn deinit(self: *ParsedCommand) void {
        for (self.argv.items) |arg| self.allocator.free(arg);
        self.argv.deinit(self.allocator);
    }
};

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

fn flushToken(allocator: Allocator, argv: *std.ArrayList([]u8), current: *std.ArrayList(u8)) !void {
    if (current.items.len == 0) return;
    try argv.append(allocator, try allocator.dupe(u8, current.items));
    current.clearRetainingCapacity();
}

fn isShellBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "echo") or
        std.mem.eql(u8, name, "exit") or
        std.mem.eql(u8, name, "type") or
        std.mem.eql(u8, name, "pwd") or
        std.mem.eql(u8, name, "cd") or
        std.mem.eql(u8, name, "history") or
        std.mem.eql(u8, name, "declare") or
        std.mem.eql(u8, name, "jobs") or
        std.mem.eql(u8, name, "complete");
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
