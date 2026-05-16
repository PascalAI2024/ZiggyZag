const std = @import("std");
const builtin = @import("builtin");
const theme = @import("theme.zig");

const Allocator = std.mem.Allocator;

pub fn run(init_data: std.process.Init) !void {
    const allocator = init_data.gpa;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init_data.io, &stderr_buffer);
    defer stderr.interface.flush() catch {};

    const shell_path = resolveShellPath(allocator, init_data.io, init_data.environ_map) catch |err| {
        try stderr.interface.print(
            \\ZiggyZag Desktop ({s})
            \\
            \\Unable to find the ZiggyZag shell binary.
            \\- Run `zig build` from the repository root, or
            \\- Put `ziggyzag` beside this executable in a release package, or
            \\- Set ZIGGYZAG_SHELL_PATH to the shell executable.
            \\
            \\error: {s}
            \\
        , .{ backendName(), @errorName(err) });
        return err;
    };
    defer allocator.free(shell_path);

    try init_data.environ_map.put("ZIGGYZAG_APP", "1");
    try init_data.environ_map.put("ZIGGYZAG_INTEGRATION", "1");
    if (init_data.environ_map.get("TERM") == null) {
        try init_data.environ_map.put("TERM", "xterm-256color");
    }

    if (!shouldSkipPty(init_data.environ_map)) {
        try printLaunchNote(&stderr.interface, shell_path, true);
        try stderr.interface.flush();
        const term = runWithScript(init_data.io, init_data.environ_map, allocator, shell_path) catch |err| {
            try printPtyFallback(&stderr.interface, err, shell_path);
            try stderr.interface.flush();
            const fallback_term = runDirect(init_data.io, init_data.environ_map, shell_path) catch |fallback_err| {
                try printDirectFailure(&stderr.interface, fallback_err, shell_path);
                stderr.interface.flush() catch {};
                std.process.exit(127);
            };
            std.process.exit(termExitCode(fallback_term));
        };
        std.process.exit(termExitCode(term));
    }

    try printLaunchNote(&stderr.interface, shell_path, false);
    try stderr.interface.flush();
    const term = runDirect(init_data.io, init_data.environ_map, shell_path) catch |err| {
        try printDirectFailure(&stderr.interface, err, shell_path);
        stderr.interface.flush() catch {};
        std.process.exit(127);
    };
    std.process.exit(termExitCode(term));
}

fn runWithScript(
    io: std.Io,
    env: *const std.process.Environ.Map,
    allocator: Allocator,
    shell_path: []const u8,
) !std.process.Child.Term {
    switch (builtin.os.tag) {
        .linux => {
            const command = try shellCommandLine(allocator, shell_path);
            defer allocator.free(command);
            var argv = [_][]const u8{ "script", "-q", "-e", "-c", command, "/dev/null" };
            return spawnAndWait(io, env, &argv);
        },
        .macos, .freebsd, .netbsd, .openbsd => {
            var argv = [_][]const u8{ "script", "-q", "/dev/null", shell_path };
            return spawnAndWait(io, env, &argv);
        },
        else => return error.UnsupportedPosixHost,
    }
}

fn runDirect(io: std.Io, env: *const std.process.Environ.Map, shell_path: []const u8) !std.process.Child.Term {
    var argv = [_][]const u8{shell_path};
    return spawnAndWait(io, env, &argv);
}

fn spawnAndWait(io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8) !std.process.Child.Term {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    errdefer child.kill(io);
    return try child.wait(io);
}

pub fn resolveShellPath(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
) ![]u8 {
    if (env.get("ZIGGYZAG_SHELL_PATH")) |path| {
        try validateShellPath(path);
        return try allocator.dupe(u8, path);
    }

    const exe_dir = std.process.executableDirPathAlloc(io, allocator) catch null;
    if (exe_dir) |dir| {
        defer allocator.free(dir);
        const sibling = try std.fs.path.join(allocator, &.{ dir, "ziggyzag" });
        errdefer allocator.free(sibling);
        if (exists(io, sibling)) return sibling;
        allocator.free(sibling);
    }

    if (try existingCandidate(allocator, io, "zig-out/bin/ziggyzag")) |path| return path;
    if (try existingCandidate(allocator, io, "ziggyzag")) |path| return path;
    if (try pathCandidate(allocator, io, env, "ziggyzag")) |path| return path;

    return error.ShellBinaryNotFound;
}

fn existingCandidate(allocator: Allocator, io: std.Io, path: []const u8) !?[]u8 {
    if (!exists(io, path)) return null;
    try validateShellPath(path);
    return try allocator.dupe(u8, path);
}

fn pathCandidate(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map, command: []const u8) !?[]u8 {
    const path_value = env.get("PATH") orelse return null;
    var split = std.mem.splitScalar(u8, path_value, ':');
    while (split.next()) |entry| {
        const dir = if (entry.len == 0) "." else entry;
        const candidate = try std.fs.path.join(allocator, &.{ dir, command });
        errdefer allocator.free(candidate);
        if (exists(io, candidate)) {
            try validateShellPath(candidate);
            return candidate;
        }
        allocator.free(candidate);
    }
    return null;
}

fn validateShellPath(path: []const u8) !void {
    if (path.len == 0) return error.EmptyShellPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidShellPath;
}

fn exists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn shellCommandLine(allocator: Allocator, shell_path: []const u8) ![]u8 {
    const quoted = try shellQuote(allocator, shell_path);
    defer allocator.free(quoted);
    return try std.fmt.allocPrint(allocator, "exec {s}", .{quoted});
}

fn shellQuote(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}

fn shouldSkipPty(env: *const std.process.Environ.Map) bool {
    return noPtyValueEnabled(env.get("ZIGGYZAG_DESKTOP_NO_PTY"));
}

fn noPtyValueEnabled(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "0")) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "no")) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) return false;
    return true;
}

fn printLaunchNote(stderr: *std.Io.Writer, shell_path: []const u8, through_pty: bool) !void {
    try stderr.print(
        \\ZiggyZag Desktop ({s})
        \\backend: {s}; theme: {s}; shell: {s}
        \\
    , .{
        if (through_pty) "POSIX PTY" else "direct stdio",
        if (through_pty) backendName() else "direct stdio fallback",
        theme.ziggy.name,
        shell_path,
    });
}

fn printPtyFallback(stderr: *std.Io.Writer, err: anyerror, shell_path: []const u8) !void {
    try stderr.print(
        \\ZiggyZag: POSIX PTY launch failed: {s}
        \\Falling back to direct stdio for `{s}`.
        \\Install `script(1)` or run with ZIGGYZAG_DESKTOP_NO_PTY=1 to skip the PTY wrapper.
        \\
    , .{ @errorName(err), shell_path });
}

fn printDirectFailure(stderr: *std.Io.Writer, err: anyerror, shell_path: []const u8) !void {
    try stderr.print(
        \\ZiggyZag: unable to launch `{s}`: {s}
        \\Build first with `zig build`, keep `ziggyzag` beside `ziggyzag-desktop`, set ZIGGYZAG_SHELL_PATH, or add `ziggyzag` to PATH.
        \\
    , .{ shell_path, @errorName(err) });
}

fn backendName() []const u8 {
    return "POSIX PTY";
}

fn termExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| 128 + @as(u8, @intCast(@intFromEnum(signal))),
        .stopped => |signal| 128 + @as(u8, @intCast(@intFromEnum(signal))),
        .unknown => 1,
    };
}

test "shell quoting handles spaces and single quotes" {
    const quoted = try shellQuote(std.testing.allocator, "/tmp/zig gy' zag");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("'/tmp/zig gy'\\'' zag'", quoted);
}

test "script command line execs quoted shell path" {
    const command = try shellCommandLine(std.testing.allocator, "/tmp/zig gy' zag");
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("exec '/tmp/zig gy'\\'' zag'", command);
}

test "no pty flag accepts explicit true values and ignores false-like values" {
    try std.testing.expect(!noPtyValueEnabled(null));
    try std.testing.expect(!noPtyValueEnabled(""));
    try std.testing.expect(!noPtyValueEnabled(" 0 "));
    try std.testing.expect(!noPtyValueEnabled("false"));
    try std.testing.expect(!noPtyValueEnabled("NO"));
    try std.testing.expect(!noPtyValueEnabled("off"));
    try std.testing.expect(noPtyValueEnabled("1"));
    try std.testing.expect(noPtyValueEnabled("true"));
    try std.testing.expect(noPtyValueEnabled("yes"));
}

test "shell path validation rejects empty and nul bytes" {
    try std.testing.expectError(error.EmptyShellPath, validateShellPath(""));
    try std.testing.expectError(error.InvalidShellPath, validateShellPath("ziggyzag\x00bad"));
    try validateShellPath("/tmp/zig gy' zag");
}

test "term status maps exited code" {
    try std.testing.expectEqual(@as(u8, 7), termExitCode(.{ .exited = 7 }));
}
