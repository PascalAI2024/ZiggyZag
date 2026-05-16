const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;

pub const Approval = enum {
    none,
    ask,
    host,

    fn text(self: Approval) []const u8 {
        return switch (self) {
            .none => "none",
            .ask => "ask",
            .host => "host",
        };
    }
};

pub const Spec = struct {
    name: []const u8,
    description: []const u8,
    approval: Approval,
};

pub const specs = [_]Spec{
    .{
        .name = "project.info",
        .description = "Report the current workspace and known ZiggyZag binaries.",
        .approval = .none,
    },
    .{
        .name = "file.read",
        .description = "Read a bounded UTF-8-ish file from the current workspace. Requires a flat JSON path field.",
        .approval = .none,
    },
    .{
        .name = "rg.search",
        .description = "Run ripgrep for a query in the current workspace.",
        .approval = .none,
    },
    .{
        .name = "git.diff",
        .description = "Return the current git diff.",
        .approval = .none,
    },
    .{
        .name = "zig.build",
        .description = "Run zig build or zig build test. This writes build artifacts and should be approved by the host UI.",
        .approval = .ask,
    },
    .{
        .name = "terminal.write",
        .description = "Ask the terminal host to write text into the active PTY.",
        .approval = .host,
    },
};

pub fn findSpec(name: []const u8) ?Spec {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingTool => "tools/call requires a tool field",
        error.UnknownTool => "unknown tool name",
        error.MissingPath => "file.read requires a path field",
        error.UnsafePath => "file.read path must be relative and stay inside the workspace",
        error.MissingQuery => "rg.search requires a query field",
        error.EmptyQuery => "rg.search query cannot be empty",
        error.QueryTooLarge => "rg.search query is too large",
        error.MissingText => "terminal.write requires a text field",
        error.EmptyText => "terminal.write text cannot be empty",
        error.TextTooLarge => "terminal.write text is too large",
        error.UnsupportedBuildCommand => "zig.build command must be omitted, \"build\", or \"test\"",
        error.InvalidZigPath => "configured Zig path contains invalid bytes",
        error.ConfiguredZigUnavailable => "configured Zig path was not found; check ZIGGYZAG_ZIG_PATH or ZIG_EXE",
        error.ZigUnavailable => "zig.build could not find Zig; set ZIGGYZAG_ZIG_PATH or ZIG_EXE, add zig to PATH, or install Zig",
        error.FileNotFound => "required command or file was not found",
        error.AccessDenied => "access denied while running tool",
        else => "tool call failed",
    };
}

pub const Result = struct {
    json: []u8,

    pub fn deinit(self: Result, allocator: Allocator) void {
        allocator.free(self.json);
    }
};

pub fn listJsonAlloc(allocator: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"tools\":[");
    for (specs, 0..) |spec, index| {
        if (index > 0) try out.append(allocator, ',');
        try out.append(allocator, '{');
        try out.appendSlice(allocator, "\"name\":");
        try protocol.appendJsonString(allocator, &out, spec.name);
        try out.appendSlice(allocator, ",\"description\":");
        try protocol.appendJsonString(allocator, &out, spec.description);
        try out.appendSlice(allocator, ",\"approval\":");
        try protocol.appendJsonString(allocator, &out, spec.approval.text());
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

pub fn run(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    request: protocol.Request,
) !Result {
    const tool = request.tool orelse return error.MissingTool;
    _ = findSpec(tool) orelse return error.UnknownTool;
    if (std.mem.eql(u8, tool, "project.info")) return .{ .json = try projectInfoJsonAlloc(allocator, io) };
    if (std.mem.eql(u8, tool, "file.read")) return .{ .json = try readFileJsonAlloc(allocator, io, request.path orelse return error.MissingPath) };
    if (std.mem.eql(u8, tool, "rg.search")) return .{ .json = try rgSearchJsonAlloc(allocator, io, env, request.query orelse return error.MissingQuery) };
    if (std.mem.eql(u8, tool, "git.diff")) return .{ .json = try commandJsonAlloc(allocator, io, env, &.{ "git", "diff", "--" }) };
    if (std.mem.eql(u8, tool, "zig.build")) return .{ .json = try runZigBuildJsonAlloc(allocator, io, env, request.command) };
    if (std.mem.eql(u8, tool, "terminal.write")) return .{ .json = try terminalWriteJsonAlloc(allocator, request.text orelse return error.MissingText) };
    unreachable;
}

fn projectInfoJsonAlloc(allocator: Allocator, io: std.Io) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"cwd\":");
    try protocol.appendJsonString(allocator, &out, cwd);
    try out.appendSlice(allocator, ",\"binaries\":[\"ziggyzag\",\"ziggyzag-desktop\",\"ziggyzag-agentd\"]}");
    return out.toOwnedSlice(allocator);
}

fn readFileJsonAlloc(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (!safeRelativePath(path)) return error.UnsafePath;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buffer);
    const contents = try reader.interface.allocRemaining(allocator, .limited(128 * 1024));
    defer allocator.free(contents);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"path\":");
    try protocol.appendJsonString(allocator, &out, path);
    try out.appendSlice(allocator, ",\"content\":");
    try protocol.appendJsonString(allocator, &out, contents);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn runZigBuildJsonAlloc(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    command: ?[]const u8,
) ![]u8 {
    const zig = try resolveZigExeAlloc(allocator, io, env);
    defer zig.deinit(allocator);

    if (command) |value| {
        if (std.mem.eql(u8, value, "test")) {
            const argv = [_][]const u8{ zig.path, "build", "test" };
            return commandJsonAlloc(allocator, io, env, &argv);
        }
        if (!std.mem.eql(u8, value, "build")) return error.UnsupportedBuildCommand;
    }
    const argv = [_][]const u8{ zig.path, "build" };
    return commandJsonAlloc(allocator, io, env, &argv);
}

fn rgSearchJsonAlloc(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    query: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyQuery;
    if (trimmed.len > 1024) return error.QueryTooLarge;
    return commandJsonAlloc(allocator, io, env, &.{ "rg", "--line-number", "--color", "never", trimmed, "." });
}

fn terminalWriteJsonAlloc(allocator: Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return error.EmptyText;
    if (text.len > 16 * 1024) return error.TextTooLarge;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"host_action\":\"terminal.write\",\"text\":");
    try protocol.appendJsonString(allocator, &out, text);
    try out.appendSlice(allocator, ",\"requires_host\":true}");
    return out.toOwnedSlice(allocator);
}

fn commandJsonAlloc(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    argv: []const []const u8,
) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = env,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"status\":");
    var status_buffer: [16]u8 = undefined;
    const status_text = std.fmt.bufPrint(&status_buffer, "{d}", .{termStatus(result.term)}) catch unreachable;
    try out.appendSlice(allocator, status_text);
    try out.appendSlice(allocator, ",\"stdout\":");
    try protocol.appendJsonString(allocator, &out, result.stdout);
    try out.appendSlice(allocator, ",\"stderr\":");
    try protocol.appendJsonString(allocator, &out, result.stderr);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

const ZigExe = struct {
    path: []u8,

    fn deinit(self: ZigExe, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

fn resolveZigExeAlloc(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
) !ZigExe {
    if (envZigPath(env)) |configured| {
        if (!validExecutablePathText(configured)) return error.InvalidZigPath;
        if (!executableFileExists(io, configured)) return error.ConfiguredZigUnavailable;
        return .{ .path = try allocator.dupe(u8, configured) };
    }

    if (commandAvailable(allocator, io, env, "zig")) {
        return .{ .path = try allocator.dupe(u8, "zig") };
    }

    if (try knownWindowsZigAlloc(allocator, io, env)) |path| {
        return .{ .path = path };
    }

    return error.ZigUnavailable;
}

fn envZigPath(env: *std.process.Environ.Map) ?[]const u8 {
    const raw = env.get("ZIGGYZAG_ZIG_PATH") orelse env.get("ZIG_EXE") orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn validExecutablePathText(path: []const u8) bool {
    return path.len > 0 and std.mem.indexOfScalar(u8, path, 0) == null;
}

fn executableFileExists(io: std.Io, path: []const u8) bool {
    if (!validExecutablePathText(path)) return false;
    const file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn commandAvailable(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    command: []const u8,
) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ command, "version" },
        .environ_map = env,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return termStatus(result.term) == 0;
}

fn knownWindowsZigAlloc(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
) !?[]u8 {
    if (builtin.os.tag != .windows) return null;

    if (try envSubpathIfExistsAlloc(allocator, io, env, "LOCALAPPDATA", &.{
        "Microsoft",
        "WinGet",
        "Links",
        "zig.exe",
    })) |path| return path;

    if (try wingetPackageZigAlloc(allocator, io, env)) |path| return path;

    if (try envSubpathIfExistsAlloc(allocator, io, env, "USERPROFILE", &.{
        "scoop",
        "shims",
        "zig.exe",
    })) |path| return path;

    if (try envSubpathIfExistsAlloc(allocator, io, env, "ProgramData", &.{
        "scoop",
        "shims",
        "zig.exe",
    })) |path| return path;

    if (executableFileExists(io, "C:\\ProgramData\\chocolatey\\bin\\zig.exe")) {
        return try allocator.dupe(u8, "C:\\ProgramData\\chocolatey\\bin\\zig.exe");
    }

    if (executableFileExists(io, "C:\\Program Files\\Zig\\zig.exe")) {
        return try allocator.dupe(u8, "C:\\Program Files\\Zig\\zig.exe");
    }

    return null;
}

fn envSubpathIfExistsAlloc(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    env_name: []const u8,
    sub_path: []const []const u8,
) !?[]u8 {
    const base = env.get(env_name) orelse return null;
    if (!validExecutablePathText(base)) return null;

    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);
    try segments.append(allocator, base);
    try segments.appendSlice(allocator, sub_path);

    const candidate = try std.fs.path.join(allocator, segments.items);
    errdefer allocator.free(candidate);
    if (!executableFileExists(io, candidate)) {
        allocator.free(candidate);
        return null;
    }
    return candidate;
}

fn wingetPackageZigAlloc(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
) !?[]u8 {
    const local_app_data = env.get("LOCALAPPDATA") orelse return null;
    if (!validExecutablePathText(local_app_data)) return null;

    const package_root = try std.fs.path.join(allocator, &.{
        local_app_data,
        "Microsoft",
        "WinGet",
        "Packages",
        "zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe",
    });
    defer allocator.free(package_root);

    var dir = std.Io.Dir.openDirAbsolute(io, package_root, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var it = dir.iterateAssumeFirstIteration();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "zig-")) continue;

        const candidate = try std.fs.path.join(allocator, &.{ package_root, entry.name, "zig.exe" });
        errdefer allocator.free(candidate);
        if (executableFileExists(io, candidate)) return candidate;
        allocator.free(candidate);
    }

    return null;
}

pub fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn termStatus(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => 128,
        .stopped => 128,
        .unknown => 1,
    };
}

test "tool list includes terminal host action" {
    const json = try listJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "terminal.write") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"approval\":\"host\"") != null);
}

test "finds known tools and rejects unknown tools" {
    try std.testing.expect(findSpec("project.info") != null);
    try std.testing.expect(findSpec("does.not.exist") == null);
}

test "rejects unsafe paths" {
    try std.testing.expect(!safeRelativePath("../README.md"));
    try std.testing.expect(!safeRelativePath("docs/../README.md"));
    try std.testing.expect(!safeRelativePath("C:\\temp\\secret.txt"));
    try std.testing.expect(!safeRelativePath("README.md:ads"));
    try std.testing.expect(!safeRelativePath(""));
    try std.testing.expect(safeRelativePath("docs/README.md"));
}

test "resolves configured zig path before path lookup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zig.exe", .data = "" });
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const fake_zig = try std.fs.path.join(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "zig.exe",
    });
    defer std.testing.allocator.free(fake_zig);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZIG_EXE", "zig-should-not-win");
    try env.put("ZIGGYZAG_ZIG_PATH", fake_zig);

    const resolved = try resolveZigExeAlloc(std.testing.allocator, std.testing.io, &env);
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(fake_zig, resolved.path);
}

test "reports unavailable configured zig path" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZIGGYZAG_ZIG_PATH", "missing-zig-for-agentd-test.exe");

    try std.testing.expectError(error.ConfiguredZigUnavailable, resolveZigExeAlloc(std.testing.allocator, std.testing.io, &env));
}

test "rejects NUL in configured zig path" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZIGGYZAG_ZIG_PATH", "bad\x00zig.exe");

    try std.testing.expectError(error.InvalidZigPath, resolveZigExeAlloc(std.testing.allocator, std.testing.io, &env));
}
