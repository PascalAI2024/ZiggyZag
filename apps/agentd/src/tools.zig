const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const max_file_output_bytes = 64 * 1024;
const max_command_stdout_bytes = 96 * 1024;
const max_command_stderr_bytes = 24 * 1024;

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
    input_schema: []const u8,
    output_schema: []const u8,
    effect: []const u8,
    approval_reason: []const u8,
    context_policy: []const u8,
};

pub const specs = [_]Spec{
    .{
        .name = "project.info",
        .description = "Report the current workspace and known ZiggyZag binaries.",
        .approval = .none,
        .input_schema = "{\"type\":\"object\",\"additionalProperties\":false}",
        .output_schema = "{\"type\":\"object\",\"required\":[\"cwd\",\"binaries\"]}",
        .effect = "read_workspace_metadata",
        .approval_reason = "Read-only workspace metadata.",
        .context_policy = "minimal",
    },
    .{
        .name = "file.read",
        .description = "Read a bounded UTF-8-ish file from the current workspace. Requires a flat JSON path field.",
        .approval = .none,
        .input_schema = "{\"type\":\"object\",\"required\":[\"path\"],\"properties\":{\"path\":{\"type\":\"string\",\"maxLength\":4096}},\"additionalProperties\":false}",
        .output_schema = "{\"type\":\"object\",\"required\":[\"path\",\"content\",\"bytes_read\",\"content_truncated\",\"redacted\"]}",
        .effect = "read_file",
        .approval_reason = "Read-only bounded file access within the workspace.",
        .context_policy = "bounded_64k_redacted",
    },
    .{
        .name = "rg.search",
        .description = "Run ripgrep for a query in the current workspace.",
        .approval = .none,
        .input_schema = "{\"type\":\"object\",\"required\":[\"query\"],\"properties\":{\"query\":{\"type\":\"string\",\"maxLength\":1024}},\"additionalProperties\":false}",
        .output_schema = "{\"type\":\"object\",\"required\":[\"status\",\"stdout\",\"stderr\",\"stdout_truncated\",\"stderr_truncated\",\"redacted\"]}",
        .effect = "read_search_index",
        .approval_reason = "Read-only bounded search output.",
        .context_policy = "bounded_redacted_command_output",
    },
    .{
        .name = "git.diff",
        .description = "Return the current git diff.",
        .approval = .none,
        .input_schema = "{\"type\":\"object\",\"additionalProperties\":false}",
        .output_schema = "{\"type\":\"object\",\"required\":[\"status\",\"stdout\",\"stderr\",\"stdout_truncated\",\"stderr_truncated\",\"redacted\"]}",
        .effect = "read_git_diff",
        .approval_reason = "Read-only git inspection.",
        .context_policy = "bounded_redacted_command_output",
    },
    .{
        .name = "zig.build",
        .description = "Run zig build or zig build test. This writes build artifacts and should be approved by the host UI.",
        .approval = .ask,
        .input_schema = "{\"type\":\"object\",\"properties\":{\"command\":{\"enum\":[\"build\",\"test\"]}},\"additionalProperties\":false}",
        .output_schema = "{\"type\":\"object\",\"required\":[\"host_action\",\"approval\",\"requires_host\",\"command\",\"argv\",\"audit\",\"event\"]}",
        .effect = "write_build_artifacts",
        .approval_reason = "Build commands can write artifacts and execute build scripts.",
        .context_policy = "host_action_only_no_execution",
    },
    .{
        .name = "terminal.write",
        .description = "Ask the terminal host to write text into the active PTY after approval.",
        .approval = .ask,
        .input_schema = "{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"text\":{\"type\":\"string\",\"maxLength\":16384}},\"additionalProperties\":false}",
        .output_schema = "{\"type\":\"object\",\"required\":[\"host_action\",\"approval\",\"requires_host\",\"text\",\"preview\",\"audit\",\"event\"]}",
        .effect = "write_terminal_input",
        .approval_reason = "Writing to the active PTY can execute commands or mutate state.",
        .context_policy = "host_action_preview_only",
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
        error.InvalidQuery => "rg.search query contains invalid bytes",
        error.QueryTooLarge => "rg.search query is too large",
        error.MissingText => "terminal.write requires a text field",
        error.EmptyText => "terminal.write text cannot be empty",
        error.InvalidText => "terminal.write text contains invalid bytes",
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
        try out.appendSlice(allocator, ",\"requires_approval\":");
        try out.appendSlice(allocator, if (spec.approval == .ask) "true" else "false");
        try out.appendSlice(allocator, ",\"approval_reason\":");
        try protocol.appendJsonString(allocator, &out, spec.approval_reason);
        try out.appendSlice(allocator, ",\"effect\":");
        try protocol.appendJsonString(allocator, &out, spec.effect);
        try out.appendSlice(allocator, ",\"context_policy\":");
        try protocol.appendJsonString(allocator, &out, spec.context_policy);
        try out.appendSlice(allocator, ",\"input_schema\":");
        try out.appendSlice(allocator, spec.input_schema);
        try out.appendSlice(allocator, ",\"output_schema\":");
        try out.appendSlice(allocator, spec.output_schema);
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
    const spec = findSpec(tool) orelse return error.UnknownTool;
    if (spec.approval == .ask) {
        if (std.mem.eql(u8, tool, "zig.build")) return .{ .json = try zigBuildAskJsonAlloc(allocator, request.command) };
        if (std.mem.eql(u8, tool, "terminal.write")) return .{ .json = try terminalWriteJsonAlloc(allocator, request.text orelse return error.MissingText) };
        unreachable;
    }

    if (std.mem.eql(u8, tool, "project.info")) return .{ .json = try projectInfoJsonAlloc(allocator, io) };
    if (std.mem.eql(u8, tool, "file.read")) return .{ .json = try readFileJsonAlloc(allocator, io, request.path orelse return error.MissingPath) };
    if (std.mem.eql(u8, tool, "rg.search")) return .{ .json = try rgSearchJsonAlloc(allocator, io, env, request.query orelse return error.MissingQuery) };
    if (std.mem.eql(u8, tool, "git.diff")) return .{ .json = try commandJsonAlloc(allocator, io, env, &.{ "git", "diff", "--" }) };
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
    const redacted = try redactSecretsAlloc(allocator, contents);
    defer redacted.deinit(allocator);
    const clipped = clippedView(redacted.text, max_file_output_bytes);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"path\":");
    try protocol.appendJsonString(allocator, &out, path);
    try out.appendSlice(allocator, ",\"content\":");
    try protocol.appendJsonString(allocator, &out, clipped.text);
    try out.appendSlice(allocator, ",\"bytes_read\":");
    try appendUsize(allocator, &out, contents.len);
    try out.appendSlice(allocator, ",\"content_truncated\":");
    try out.appendSlice(allocator, if (clipped.truncated) "true" else "false");
    try out.appendSlice(allocator, ",\"redacted\":");
    try out.appendSlice(allocator, if (redacted.changed) "true" else "false");
    try out.appendSlice(allocator, ",\"context_policy\":\"bounded_64k_redacted\"");
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn zigBuildAskJsonAlloc(allocator: Allocator, command: ?[]const u8) ![]u8 {
    const normalized = try normalizeZigBuildCommand(command);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"host_action\":\"zig.build\",\"approval\":\"ask\",\"requires_host\":true,\"command\":");
    try protocol.appendJsonString(allocator, &out, normalized);
    try out.appendSlice(allocator, ",\"argv\":[\"zig\",\"build\"");
    if (std.mem.eql(u8, normalized, "test")) try out.appendSlice(allocator, ",\"test\"");
    try out.appendSlice(allocator, "],\"description\":");
    try protocol.appendJsonString(allocator, &out, if (std.mem.eql(u8, normalized, "test")) "Run zig build test" else "Run zig build");
    try out.appendSlice(allocator, ",\"audit\":");
    try appendAuditObject(allocator, &out, "zig.build", "write_build_artifacts", true, "approval_required");
    try out.appendSlice(allocator, ",\"event\":");
    try appendEventObject(allocator, &out, "host_action.requested", "zig.build", "ask", "pending_host_approval");
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn normalizeZigBuildCommand(command: ?[]const u8) ![]const u8 {
    const value = command orelse return "build";
    if (std.mem.eql(u8, value, "build")) return "build";
    if (std.mem.eql(u8, value, "test")) return "test";
    return error.UnsupportedBuildCommand;
}

fn rgSearchJsonAlloc(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    query: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyQuery;
    if (std.mem.indexOfScalar(u8, trimmed, 0) != null) return error.InvalidQuery;
    if (trimmed.len > 1024) return error.QueryTooLarge;
    return commandJsonAlloc(allocator, io, env, &.{ "rg", "--line-number", "--color", "never", "--", trimmed, "." });
}

fn terminalWriteJsonAlloc(allocator: Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return error.EmptyText;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidText;
    if (text.len > 16 * 1024) return error.TextTooLarge;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"host_action\":\"terminal.write\",\"approval\":\"ask\",\"text\":");
    try protocol.appendJsonString(allocator, &out, text);
    try out.appendSlice(allocator, ",\"preview\":");
    try protocol.appendJsonString(allocator, &out, clippedView(text, 512).text);
    try out.appendSlice(allocator, ",\"text_bytes\":");
    try appendUsize(allocator, &out, text.len);
    try out.appendSlice(allocator, ",\"preview_truncated\":");
    try out.appendSlice(allocator, if (text.len > 512) "true" else "false");
    try out.appendSlice(allocator, ",\"requires_host\":true,\"audit\":");
    try appendAuditObject(allocator, &out, "terminal.write", "write_terminal_input", true, "approval_required");
    try out.appendSlice(allocator, ",\"event\":");
    try appendEventObject(allocator, &out, "host_action.requested", "terminal.write", "ask", "pending_host_approval");
    try out.append(allocator, '}');
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
    const stdout_redacted = try redactSecretsAlloc(allocator, result.stdout);
    defer stdout_redacted.deinit(allocator);
    const stderr_redacted = try redactSecretsAlloc(allocator, result.stderr);
    defer stderr_redacted.deinit(allocator);
    const stdout_clipped = clippedView(stdout_redacted.text, max_command_stdout_bytes);
    const stderr_clipped = clippedView(stderr_redacted.text, max_command_stderr_bytes);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"status\":");
    var status_buffer: [16]u8 = undefined;
    const status_text = std.fmt.bufPrint(&status_buffer, "{d}", .{termStatus(result.term)}) catch unreachable;
    try out.appendSlice(allocator, status_text);
    try out.appendSlice(allocator, ",\"stdout\":");
    try protocol.appendJsonString(allocator, &out, stdout_clipped.text);
    try out.appendSlice(allocator, ",\"stderr\":");
    try protocol.appendJsonString(allocator, &out, stderr_clipped.text);
    try out.appendSlice(allocator, ",\"stdout_truncated\":");
    try out.appendSlice(allocator, if (stdout_clipped.truncated) "true" else "false");
    try out.appendSlice(allocator, ",\"stderr_truncated\":");
    try out.appendSlice(allocator, if (stderr_clipped.truncated) "true" else "false");
    try out.appendSlice(allocator, ",\"redacted\":");
    try out.appendSlice(allocator, if (stdout_redacted.changed or stderr_redacted.changed) "true" else "false");
    try out.appendSlice(allocator, ",\"audit\":");
    try appendAuditObject(allocator, &out, argv[0], "read_command_output", false, "completed");
    try out.appendSlice(allocator, ",\"event\":");
    try appendEventObject(allocator, &out, "tool.completed", argv[0], "none", if (termStatus(result.term) == 0) "ok" else "nonzero_exit");
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

const RedactedText = struct {
    text: []u8,
    changed: bool,

    fn deinit(self: RedactedText, allocator: Allocator) void {
        allocator.free(self.text);
    }
};

const Clip = struct {
    text: []const u8,
    truncated: bool,
};

fn clippedView(text: []const u8, limit: usize) Clip {
    if (text.len <= limit) return .{ .text = text, .truncated = false };
    return .{ .text = text[0..limit], .truncated = true };
}

fn redactSecretsAlloc(allocator: Allocator, text: []const u8) !RedactedText {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var changed = false;

    var line_iterator = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (line_iterator.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;

        if (looksSecretLine(line)) {
            try out.appendSlice(allocator, "[redacted secret-like line]");
            changed = true;
        } else {
            try out.appendSlice(allocator, line);
        }
    }

    return .{ .text = try out.toOwnedSlice(allocator), .changed = changed };
}

fn looksSecretLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (containsAnyIgnoreCase(trimmed, &.{ "api_key", "apikey", "auth_token", "access_token", "secret", "password", "bearer " })) {
        return std.mem.indexOfAny(u8, trimmed, "=:") != null or containsIgnoreCase(trimmed, "bearer ");
    }
    return false;
}

fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(haystack, needle)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn appendAuditObject(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    action: []const u8,
    effect: []const u8,
    requires_host: bool,
    outcome: []const u8,
) !void {
    try out.appendSlice(allocator, "{\"action\":");
    try protocol.appendJsonString(allocator, out, action);
    try out.appendSlice(allocator, ",\"effect\":");
    try protocol.appendJsonString(allocator, out, effect);
    try out.appendSlice(allocator, ",\"requires_host\":");
    try out.appendSlice(allocator, if (requires_host) "true" else "false");
    try out.appendSlice(allocator, ",\"outcome\":");
    try protocol.appendJsonString(allocator, out, outcome);
    try out.append(allocator, '}');
}

fn appendEventObject(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    event_type: []const u8,
    action: []const u8,
    approval: []const u8,
    status: []const u8,
) !void {
    try out.appendSlice(allocator, "{\"type\":");
    try protocol.appendJsonString(allocator, out, event_type);
    try out.appendSlice(allocator, ",\"action\":");
    try protocol.appendJsonString(allocator, out, action);
    try out.appendSlice(allocator, ",\"approval\":");
    try protocol.appendJsonString(allocator, out, approval);
    try out.appendSlice(allocator, ",\"status\":");
    try protocol.appendJsonString(allocator, out, status);
    try out.append(allocator, '}');
}

fn appendUsize(allocator: Allocator, out: *std.ArrayList(u8), value: usize) !void {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    try out.appendSlice(allocator, text);
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
    if (path.len > 4096) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
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

test "tool list describes approval policies for mutating host actions" {
    const json = try listJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"zig.build\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"terminal.write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"approval\":\"ask\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_approval\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"effect\":\"write_build_artifacts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"context_policy\":\"host_action_only_no_execution\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input_schema\":{\"type\":\"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"output_schema\":{\"type\":\"object\"") != null);
}

test "finds known tools and rejects unknown tools" {
    try std.testing.expect(findSpec("project.info") != null);
    try std.testing.expect(findSpec("does.not.exist") == null);
}

test "rejects unsafe paths" {
    try std.testing.expect(!safeRelativePath("../README.md"));
    try std.testing.expect(!safeRelativePath("docs/../README.md"));
    try std.testing.expect(!safeRelativePath("C:\\temp\\secret.txt"));
    try std.testing.expect(!safeRelativePath("\\temp\\secret.txt"));
    try std.testing.expect(!safeRelativePath("/tmp/secret.txt"));
    try std.testing.expect(!safeRelativePath("README.md:ads"));
    try std.testing.expect(!safeRelativePath(""));
    try std.testing.expect(safeRelativePath("docs/README.md"));
}

test "rejects invalid bounded tool inputs before spawning commands" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectError(error.InvalidQuery, rgSearchJsonAlloc(std.testing.allocator, std.testing.io, &env, "bad\x00query"));
    try std.testing.expectError(error.EmptyQuery, rgSearchJsonAlloc(std.testing.allocator, std.testing.io, &env, " \t\r\n"));

    var large_query: [1025]u8 = undefined;
    @memset(&large_query, 'a');
    try std.testing.expectError(error.QueryTooLarge, rgSearchJsonAlloc(std.testing.allocator, std.testing.io, &env, &large_query));

    try std.testing.expectError(error.InvalidText, terminalWriteJsonAlloc(std.testing.allocator, "bad\x00text"));
    try std.testing.expectError(error.EmptyText, terminalWriteJsonAlloc(std.testing.allocator, ""));

    var large_text: [16 * 1024 + 1]u8 = undefined;
    @memset(&large_text, 'z');
    try std.testing.expectError(error.TextTooLarge, terminalWriteJsonAlloc(std.testing.allocator, &large_text));
}

test "zig.build returns ask action without resolving or running zig" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZIGGYZAG_ZIG_PATH", "missing-zig-for-agentd-test.exe");

    var request = try protocol.parseRequestAlloc(std.testing.allocator, "{\"id\":1,\"method\":\"tools/call\",\"tool\":\"zig.build\",\"command\":\"test\"}");
    defer request.deinit();

    const result = try run(std.testing.allocator, std.testing.io, &env, request);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"host_action\":\"zig.build\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"approval\":\"ask\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"argv\":[\"zig\",\"build\",\"test\"]") != null);
}

test "zig.build validates command before returning ask action" {
    try std.testing.expectError(error.UnsupportedBuildCommand, zigBuildAskJsonAlloc(std.testing.allocator, "fmt"));
}

test "terminal.write returns ask action payload" {
    const json = try terminalWriteJsonAlloc(std.testing.allocator, "zig build\n");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"host_action\":\"terminal.write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"approval\":\"ask\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"zig build\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"audit\":{\"action\":\"terminal.write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":{\"type\":\"host_action.requested\"") != null);
}

test "host action payloads include audit and event metadata" {
    const json = try zigBuildAskJsonAlloc(std.testing.allocator, "test");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_host\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"audit\":{\"action\":\"zig.build\",\"effect\":\"write_build_artifacts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":{\"type\":\"host_action.requested\",\"action\":\"zig.build\",\"approval\":\"ask\",\"status\":\"pending_host_approval\"}") != null);
}

test "redacts secret-like lines and reports clipping" {
    const redacted = try redactSecretsAlloc(std.testing.allocator, "ok\napi_key = abc123\nAuthorization: Bearer token\n");
    defer redacted.deinit(std.testing.allocator);
    try std.testing.expect(redacted.changed);
    try std.testing.expect(std.mem.indexOf(u8, redacted.text, "abc123") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted.text, "[redacted secret-like line]") != null);

    const clipped = clippedView("abcdef", 3);
    try std.testing.expect(clipped.truncated);
    try std.testing.expectEqualStrings("abc", clipped.text);
}

test "file read returns minimized redacted metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agentd-redact-test.txt", .data = "hello\npassword: hunter2\n" });
    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "agentd-redact-test.txt",
    });
    defer std.testing.allocator.free(path);

    const json = try readFileJsonAlloc(std.testing.allocator, std.testing.io, path);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"redacted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"content_truncated\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"context_policy\":\"bounded_64k_redacted\"") != null);
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
