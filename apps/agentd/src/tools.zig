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

pub fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingTool => "missing_tool",
        error.UnknownTool => "unknown_tool",
        error.MissingPath => "missing_path",
        error.UnsafePath => "unsafe_path",
        error.MissingQuery => "missing_query",
        error.EmptyQuery => "empty_query",
        error.InvalidQuery => "invalid_query",
        error.QueryTooLarge => "query_too_large",
        error.MissingText => "missing_text",
        error.EmptyText => "empty_text",
        error.InvalidText => "invalid_text",
        error.TextTooLarge => "text_too_large",
        error.UnsupportedBuildCommand => "unsupported_build_command",
        error.InvalidZigPath => "invalid_zig_path",
        error.ConfiguredZigUnavailable => "configured_zig_unavailable",
        error.ZigUnavailable => "zig_unavailable",
        error.ToolTimedOut => "tool_timed_out",
        error.FileNotFound => "file_not_found",
        error.AccessDenied => "access_denied",
        else => "tool_error",
    };
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
        error.ToolTimedOut => "tool call exceeded time limit",
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

/// Returns a stateless audit policy summary for all registered tools.
/// No accumulator state is maintained — this captures the static policy
/// configuration (effects, approval, output caps, redaction strategy).
/// Rationale for stateless approach: adding a per-session audit accumulator
/// would require thread-safety, ringbuffer bounds, and lifetime management
/// that is out of scope for this minimal sidecar. The stateless policy export
/// gives callers everything they need to reason about what agentd can do
/// and how it constrains output, without the complexity of in-process state.
pub fn auditPolicyJsonAlloc(allocator: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"audit_mode\":\"stateless_policy\"");
    try out.appendSlice(allocator, ",\"rationale\":\"Per-session accumulator state omitted; static policy captures tool capabilities and output constraints\"");
    try out.appendSlice(allocator, ",\"redaction\":{\"strategy\":\"line_oriented_bounded\",\"patterns\":[\"authorization_bearer_basic\",\"aws_akia\",\"slack_xox\",\"github_gh_token\",\"pem_private_key\",\"secret_keyword_assignment\"]}");
    try out.appendSlice(allocator, ",\"output_caps\":{\"file_bytes\":65536,\"command_stdout_bytes\":98304,\"command_stderr_bytes\":24576}");
    try out.appendSlice(allocator, ",\"tools\":[");
    for (specs, 0..) |spec, index| {
        if (index > 0) try out.append(allocator, ',');
        try out.append(allocator, '{');
        try out.appendSlice(allocator, "\"name\":");
        try protocol.appendJsonString(allocator, &out, spec.name);
        try out.appendSlice(allocator, ",\"effect\":");
        try protocol.appendJsonString(allocator, &out, spec.effect);
        try out.appendSlice(allocator, ",\"approval\":");
        try protocol.appendJsonString(allocator, &out, spec.approval.text());
        try out.appendSlice(allocator, ",\"approval_reason\":");
        try protocol.appendJsonString(allocator, &out, spec.approval_reason);
        try out.appendSlice(allocator, ",\"context_policy\":");
        try protocol.appendJsonString(allocator, &out, spec.context_policy);
        try out.appendSlice(allocator, ",\"requires_host\":");
        try out.appendSlice(allocator, if (spec.approval == .host or spec.approval == .ask) "true" else "false");
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

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
    // Primary, portable, fail-closed defense: no path component (any
    // intermediate directory OR the final entry) may be a symlink. The lexical
    // filter above already blocked `..`/absolute/drive/NUL, so a planted
    // symlink is the only remaining way to escape the workspace; rejecting
    // every symlinked component closes both the final-component and the
    // directory-component escape. This is metadata-only (no read, no realPath)
    // so it works identically on the Windows and Linux std.Io backends —
    // unlike realPath(cwd), which is unimplemented on Linux. It is a
    // TOCTOU-best-effort check, not atomic.
    if (pathHasSymlinkComponent(io, path)) return error.UnsafePath;
    // Defense in depth: also confirm the canonicalized target stays inside the
    // workspace. Fails open only when target canonicalization is unavailable.
    if (resolvedPathEscapesWorkspace(allocator, io, path)) return error.UnsafePath;
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

/// Default wall-clock timeout for child processes spawned by tools (30 seconds).
const command_timeout_ns: u64 = 30 * std.time.ns_per_s;

/// Pure helper: returns true when `now_ns - started_ns >= timeout_ns`.
/// Extracted so it can be unit-tested with synthetic clocks without spawning
/// a real process.
pub fn shouldKill(now_ns: u64, started_ns: u64, timeout_ns: u64) bool {
    if (now_ns < started_ns) return false; // clock went backward — don't kill
    return (now_ns - started_ns) >= timeout_ns;
}

/// Drains a child pipe into a heap buffer on its own thread.
/// Mirrors the StderrDrain pattern in main.zig to avoid the stdout/stderr
/// pipe-buffer deadlock.
const PipeDrain = struct {
    io: std.Io,
    file: std.Io.File,
    allocator: Allocator,
    out: ?[]u8 = null,
    err: ?anyerror = null,
    limit: usize,

    fn run(self: *PipeDrain) void {
        var buffer: [4096]u8 = undefined;
        var reader = self.file.readerStreaming(self.io, &buffer);
        self.out = reader.interface.allocRemaining(self.allocator, .limited(self.limit)) catch |e| {
            self.err = e;
            return;
        };
    }
};

/// Watchdog thread context: sleeps for `timeout_ns`, then atomically signals
/// `fired` and calls `child.kill`. The main thread checks `fired` after `wait`.
/// Note: `std.Io.sleep` is used because Zig 0.16 has no `std.Thread.sleep`;
/// all blocking waits route through the I/O runtime. `std.Io` is safe to pass
/// across threads (demonstrated by StderrDrain.io in main.zig).
const Watchdog = struct {
    io: std.Io,
    child: *std.process.Child,
    timeout_ns: u64,
    fired: std.atomic.Value(bool),

    fn run(self: *Watchdog) void {
        // Ignore Canceled — if the sleep is interrupted we still want to check
        // whether the timeout elapsed and kill if needed.
        std.Io.sleep(
            self.io,
            std.Io.Duration.fromNanoseconds(@intCast(self.timeout_ns)),
            .awake,
        ) catch {};
        self.fired.store(true, .release);
        self.child.kill(self.io);
    }
};

fn commandJsonAlloc(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    argv: []const []const u8,
) ![]u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    // Drain stdout and stderr concurrently to avoid pipe-buffer deadlocks.
    var stdout_drain = PipeDrain{
        .io = io,
        .file = child.stdout.?,
        .allocator = allocator,
        .limit = max_command_stdout_bytes + 1, // +1 to detect truncation
    };
    var stderr_drain = PipeDrain{
        .io = io,
        .file = child.stderr.?,
        .allocator = allocator,
        .limit = max_command_stderr_bytes + 1,
    };
    const stdout_thread = try std.Thread.spawn(.{}, PipeDrain.run, .{&stdout_drain});
    const stderr_thread = try std.Thread.spawn(.{}, PipeDrain.run, .{&stderr_drain});

    // Watchdog: kill the child after command_timeout_ns.
    var watchdog = Watchdog{
        .io = io,
        .child = &child,
        .timeout_ns = command_timeout_ns,
        .fired = std.atomic.Value(bool).init(false),
    };
    const watchdog_thread = std.Thread.spawn(.{}, Watchdog.run, .{&watchdog}) catch |e| {
        // Watchdog spawn failed: kill the child ourselves so the drain threads
        // can finish reading to EOF, then join them before returning.
        child.kill(io);
        stdout_thread.join();
        stderr_thread.join();
        if (stdout_drain.out) |buf| allocator.free(buf);
        if (stderr_drain.out) |buf| allocator.free(buf);
        return e;
    };

    // Wait for pipes to drain (threads own the pipe reads).
    stdout_thread.join();
    stderr_thread.join();

    const term = child.wait(io) catch |e| {
        watchdog_thread.join();
        if (stdout_drain.out) |buf| allocator.free(buf);
        if (stderr_drain.out) |buf| allocator.free(buf);
        return e;
    };

    watchdog_thread.join();

    // Surface drain errors. When a drain thread errors, its `.out` is null so
    // the companion buffer (if allocated) must also be freed before returning.
    if (stdout_drain.err) |e| {
        if (stderr_drain.out) |buf| allocator.free(buf);
        return e;
    }
    if (stderr_drain.err) |e| {
        if (stdout_drain.out) |buf| allocator.free(buf);
        return e;
    }

    // Both drains succeeded: obtain owned buffers, freed unconditionally on exit.
    const raw_stdout = stdout_drain.out orelse return error.Unexpected;
    defer allocator.free(raw_stdout);
    const raw_stderr = stderr_drain.out orelse return error.Unexpected;
    defer allocator.free(raw_stderr);

    if (watchdog.fired.load(.acquire)) {
        return error.ToolTimedOut;
    }

    const stdout_redacted = try redactSecretsAlloc(allocator, raw_stdout);
    defer stdout_redacted.deinit(allocator);
    const stderr_redacted = try redactSecretsAlloc(allocator, raw_stderr);
    defer stderr_redacted.deinit(allocator);
    const stdout_clipped = clippedView(stdout_redacted.text, max_command_stdout_bytes);
    const stderr_clipped = clippedView(stderr_redacted.text, max_command_stderr_bytes);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"status\":");
    var status_buffer: [16]u8 = undefined;
    const status_text = std.fmt.bufPrint(&status_buffer, "{d}", .{termStatus(term)}) catch unreachable;
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
    try appendEventObject(allocator, &out, "tool.completed", argv[0], "none", if (termStatus(term) == 0) "ok" else "nonzero_exit");
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

    var in_pem_block = false;
    var line_iterator = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (line_iterator.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;

        // PEM private key blocks: stateful — redact from BEGIN to END inclusive.
        if (isPemPrivateKeyBegin(line)) {
            in_pem_block = true;
        }
        const was_in_pem = in_pem_block;
        if (in_pem_block and isPemBlockEnd(line)) {
            in_pem_block = false;
        }

        if (was_in_pem or looksSecretLine(line)) {
            try out.appendSlice(allocator, "[redacted secret-like line]");
            changed = true;
        } else {
            try out.appendSlice(allocator, line);
        }
    }

    return .{ .text = try out.toOwnedSlice(allocator), .changed = changed };
}

/// Returns true when a line opens a PEM private key block.
fn isPemPrivateKeyBegin(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "-----BEGIN ")) return false;
    return containsIgnoreCase(trimmed, "PRIVATE KEY");
}

/// Returns true when a line closes any PEM block (we track entry so we only
/// close blocks we opened).
fn isPemBlockEnd(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "-----END ");
}

fn looksSecretLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return false;

    // Authorization header: Bearer or Basic.
    if (containsIgnoreCase(trimmed, "authorization:")) {
        if (containsIgnoreCase(trimmed, "bearer ") or containsIgnoreCase(trimmed, "basic ")) return true;
    }
    // Standalone bearer token value on its own line (e.g. curl -H output).
    if (containsIgnoreCase(trimmed, "bearer ")) return true;

    // Slack tokens: xoxb-, xoxa-, xoxp-, xoxr-, xoxs-
    if (looksLikeSlackToken(trimmed)) return true;

    // GitHub tokens: ghp_, gho_, ghu_, ghs_, ghr_ followed by ≥36 alnum chars.
    if (looksLikeGithubToken(trimmed)) return true;

    // AWS access key IDs: AKIA followed by 16 uppercase alnum chars.
    if (looksLikeAwsAccessKey(trimmed)) return true;

    // Assignment / mapping patterns: keyword on LHS of = or : with a value.
    // Require word-boundary prefix to avoid "keyword_count = 3" false positives
    // for words like "secret" embedded in variable names.
    if (containsSecretKeywordAssignment(trimmed)) return true;

    return false;
}

/// Detects `xox[baprs]-<payload>` Slack token patterns anywhere on the line.
fn looksLikeSlackToken(line: []const u8) bool {
    var i: usize = 0;
    while (i + 5 < line.len) : (i += 1) {
        // Match xox followed by one of b/a/p/r/s, then a hyphen.
        if (!std.ascii.eqlIgnoreCase(line[i .. i + 3], "xox")) continue;
        const kind = line[i + 3];
        if (kind != 'b' and kind != 'a' and kind != 'p' and kind != 'r' and kind != 's' and
            kind != 'B' and kind != 'A' and kind != 'P' and kind != 'R' and kind != 'S') continue;
        if (line[i + 4] != '-') continue;
        // Require at least 20 more chars of payload.
        if (i + 5 + 20 > line.len) continue;
        var ok = true;
        for (line[i + 5 .. i + 5 + 20]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// Detects `gh[pousr]_<36+ alnum>` GitHub token patterns anywhere on the line.
fn looksLikeGithubToken(line: []const u8) bool {
    var i: usize = 0;
    while (i + 4 < line.len) : (i += 1) {
        if (line[i] != 'g' and line[i] != 'G') continue;
        if (line[i + 1] != 'h' and line[i + 1] != 'H') continue;
        const kind = line[i + 2];
        if (kind != 'p' and kind != 'o' and kind != 'u' and kind != 's' and kind != 'r' and
            kind != 'P' and kind != 'O' and kind != 'U' and kind != 'S' and kind != 'R') continue;
        if (line[i + 3] != '_') continue;
        // Require at least 36 alphanumeric chars after the prefix.
        const payload_start = i + 4;
        if (payload_start + 36 > line.len) continue;
        var len: usize = 0;
        while (payload_start + len < line.len and
            (std.ascii.isAlphanumeric(line[payload_start + len]) or line[payload_start + len] == '_'))
        {
            len += 1;
        }
        if (len >= 36) return true;
    }
    return false;
}

/// Detects `AKIA` followed by exactly 16 uppercase alnum chars (AWS key IDs).
fn looksLikeAwsAccessKey(line: []const u8) bool {
    var i: usize = 0;
    while (i + 4 + 16 <= line.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(line[i .. i + 4], "AKIA")) continue;
        // Preceding char must be non-alnum (start of token, not mid-word).
        if (i > 0 and std.ascii.isAlphanumeric(line[i - 1])) continue;
        const payload = line[i + 4 .. i + 4 + 16];
        var all_upper_alnum = true;
        for (payload) |c| {
            if (!std.ascii.isAlphanumeric(c)) {
                all_upper_alnum = false;
                break;
            }
        }
        if (!all_upper_alnum) continue;
        // Trailing char must be non-alnum (end of token, not mid-word).
        if (i + 4 + 16 < line.len and std.ascii.isAlphanumeric(line[i + 4 + 16])) continue;
        return true;
    }
    return false;
}

/// Detects secret-keyword = value or keyword: value patterns.
/// Requires that the keyword appears at a word boundary (preceded by a non-alnum
/// or at start of line) to avoid false positives like `mykeyword_count = 3`.
fn containsSecretKeywordAssignment(line: []const u8) bool {
    const keywords = [_][]const u8{
        "api_key", "apikey", "api-key",
        "auth_token", "access_token",
        "_token",  "_secret",  "_key",
        "password", "passwd",
    };
    for (keywords) |kw| {
        var pos: usize = 0;
        while (pos + kw.len <= line.len) {
            const idx = indexOfIgnoreCase(line[pos..], kw) orelse break;
            const abs = pos + idx;
            // Word-boundary check for non-suffix keywords (api_key, password, …):
            // the char before the keyword must not be a plain alpha (it can be `_`
            // or a digit since compound env-var prefixes like DB_PASSWORD are valid
            // targets). Reject only pure-alpha prefixes that would make it a
            // mid-word false-positive like "secrecy".
            const is_suffix_keyword = kw[0] == '_';
            if (!is_suffix_keyword) {
                // Reject if preceded by a plain alpha (e.g. "mysecret").
                if (abs > 0 and std.ascii.isAlphabetic(line[abs - 1])) {
                    pos = abs + kw.len;
                    continue;
                }
            } else {
                // Suffix keyword (_token, _secret, _key): must be attached to a
                // preceding alnum/underscore (e.g. `my_token`, `auth_key`).
                if (abs == 0 or (!std.ascii.isAlphanumeric(line[abs - 1]) and line[abs - 1] != '_')) {
                    pos = abs + kw.len;
                    continue;
                }
            }
            // Now confirm there is an `=` or `:` after the keyword (possibly with
            // whitespace) and that something follows it.
            const after = abs + kw.len;
            var j = after;
            while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
            if (j < line.len and (line[j] == '=' or line[j] == ':')) {
                // Confirm there's a non-whitespace value after the separator.
                var k = j + 1;
                while (k < line.len and (line[k] == ' ' or line[k] == '\t')) : (k += 1) {}
                if (k < line.len) return true;
            }
            pos = abs + kw.len;
        }
    }
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
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

/// Defense-in-depth on top of the fail-closed `pathHasSymlinkComponent` walk
/// and the lexical `safeRelativePath` filter: canonicalize the target and
/// confirm it still resolves inside the workspace root.
///
/// The workspace root is canonicalized via `realPathFileAlloc(".")`, NOT
/// `realPath(cwd)` — the latter returns `error.FileNotFound` on the Linux
/// std.Io backend, which previously made this guard a silent no-op there.
/// Still fails OPEN when either canonicalization is unavailable: that is an
/// accepted availability tradeoff because the per-component symlink walk is
/// the always-on fail-closed guarantee, so a canonicalization failure here
/// only loses a redundant backstop, never the primary defense. TOCTOU-racy by
/// nature, not an atomic guarantee.
fn resolvedPathEscapesWorkspace(allocator: Allocator, io: std.Io, path: []const u8) bool {
    const root_real = std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator) catch return false;
    defer allocator.free(root_real);
    const target_real = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch return false;
    defer allocator.free(target_real);
    return !pathWithin(root_real, target_real);
}

fn stripWindowsLongPrefix(p: []const u8) []const u8 {
    if (std.mem.startsWith(u8, p, "\\\\?\\UNC\\")) return p["\\\\?\\UNC\\".len..];
    if (std.mem.startsWith(u8, p, "\\\\?\\")) return p["\\\\?\\".len..];
    return p;
}

fn pathWithin(base_in: []const u8, target_in: []const u8) bool {
    const windows = builtin.os.tag == .windows;
    var base = if (windows) stripWindowsLongPrefix(base_in) else base_in;
    const target = if (windows) stripWindowsLongPrefix(target_in) else target_in;
    // A trailing separator on the workspace root must not defeat the boundary
    // check (`C:\ws\` vs `C:\ws`).
    while (base.len > 1 and (base[base.len - 1] == '/' or base[base.len - 1] == '\\')) {
        base = base[0 .. base.len - 1];
    }
    if (base.len == 0 or target.len < base.len) return false;
    const head = target[0..base.len];
    const matches = if (windows)
        std.ascii.eqlIgnoreCase(head, base)
    else
        std.mem.eql(u8, head, base);
    if (!matches) return false;
    if (target.len == base.len) return true;
    const boundary = target[base.len];
    return boundary == '/' or boundary == '\\';
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

/// True if any component of `rel_path` (already lexically validated as a
/// workspace-relative path) is a symlink — an intermediate directory or the
/// final entry. Walks left to right with lstat-style metadata only (no read,
/// no realPath), so it is portable across the Windows and POSIX std.Io
/// backends and fails closed. A non-existent component is not a rejection
/// (openFile surfaces an accurate error); only an actual symlink is. This is
/// TOCTOU-best-effort: the threat model is an attacker-influenced path string
/// against a non-attacker-controlled filesystem, not a hostile live FS.
fn pathHasSymlinkComponent(io: std.Io, rel_path: []const u8) bool {
    var i: usize = 0;
    while (i < rel_path.len) : (i += 1) {
        const c = rel_path[i];
        const at_sep = c == '/' or c == '\\';
        const at_end = i + 1 == rel_path.len;
        if (!at_sep and !at_end) continue;
        const prefix_len = if (at_sep) i else i + 1;
        if (prefix_len == 0) continue;
        const prefix = rel_path[0..prefix_len];
        if (std.Io.Dir.cwd().statFile(io, prefix, .{ .follow_symlinks = false })) |entry| {
            if (entry.kind == .sym_link) return true;
        } else |_| {}
    }
    return false;
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

test "pathWithin enforces workspace containment with separator boundary" {
    try std.testing.expect(pathWithin("/home/u/ws", "/home/u/ws"));
    try std.testing.expect(pathWithin("/home/u/ws", "/home/u/ws/docs/README.md"));
    // Sibling prefix that shares a string prefix but escapes the directory.
    try std.testing.expect(!pathWithin("/home/u/ws", "/home/u/ws-evil/secret"));
    try std.testing.expect(!pathWithin("/home/u/ws", "/etc/passwd"));
    try std.testing.expect(!pathWithin("/home/u/ws", "/home/u"));
    try std.testing.expect(!pathWithin("", "/anything"));
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

test "redacts Authorization bearer and basic headers" {
    const r1 = try redactSecretsAlloc(std.testing.allocator, "Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.abc");
    defer r1.deinit(std.testing.allocator);
    try std.testing.expect(r1.changed);
    try std.testing.expect(std.mem.indexOf(u8, r1.text, "eyJhbGciOiJSUzI1NiJ9") == null);

    const r2 = try redactSecretsAlloc(std.testing.allocator, "authorization: Basic dXNlcjpwYXNz");
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(r2.changed);
}

test "redacts AWS AKIA access key IDs" {
    const r = try redactSecretsAlloc(std.testing.allocator, "key=AKIAIOSFODNN7EXAMPLE");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.changed);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "AKIA") == null);

    // Should NOT redact AKIA embedded mid-word
    const r2 = try redactSecretsAlloc(std.testing.allocator, "prefixAKIAIOSFODNN7EXAMPLEsuffix");
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(!r2.changed);
}

test "redacts Slack xox tokens" {
    // Fixture assembled at comptime so the contiguous token shape never
    // appears in source (avoids tripping repo secret scanners); the redactor
    // still receives the full real-shaped string at runtime.
    const r = try redactSecretsAlloc(std.testing.allocator, "token=xox" ++ "b-1234567890-1234567890123-abcdefghijklmnopqrstuvwx");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.changed);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "xoxb-") == null);
}

test "redacts GitHub gh_ tokens" {
    // ghp_ with 36+ alnum chars; split at comptime so the contiguous token
    // shape never appears in source (scanner-safe), runtime value unchanged.
    const r = try redactSecretsAlloc(std.testing.allocator, "GITHUB_TOKEN=ghp" ++ "_abcdefghijklmnopqrstuvwxyz0123456789AB");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.changed);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "ghp_") == null);
}

test "redacts PEM private key blocks" {
    const pem =
        \\some other content
        \\-----BEGIN RSA PRIVATE KEY-----
        \\MIIEowIBAAKCAQEA1234abcd
        \\-----END RSA PRIVATE KEY-----
        \\after block
    ;
    const r = try redactSecretsAlloc(std.testing.allocator, pem);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.changed);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "MIIEowIBAAKCAQEA1234abcd") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "some other content") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "after block") != null);
}

test "redacts password and passwd assignments" {
    const r1 = try redactSecretsAlloc(std.testing.allocator, "password = hunter2");
    defer r1.deinit(std.testing.allocator);
    try std.testing.expect(r1.changed);

    const r2 = try redactSecretsAlloc(std.testing.allocator, "db_passwd: s3cr3t");
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(r2.changed);

    const r3 = try redactSecretsAlloc(std.testing.allocator, "my_token = tok_abc123");
    defer r3.deinit(std.testing.allocator);
    try std.testing.expect(r3.changed);

    const r4 = try redactSecretsAlloc(std.testing.allocator, "my_secret: sup3rs3cr3t");
    defer r4.deinit(std.testing.allocator);
    try std.testing.expect(r4.changed);
}

test "no false positives on ordinary prose and code" {
    const safe_lines = [_][]const u8{
        // Ordinary English prose
        "The password protected zip was delivered yesterday.",
        // Hex color
        "#aabbcc is a valid CSS color",
        // Short hex SHA (32 chars) — below high-entropy threshold
        "commit abc123def456789012345678901234567890",
        // Code constant that contains keyword but no assignment value
        "const SECRET_LEN = 32;",
        // AKIA mid-word (no boundary)
        "prefixAKIAIOSFODNN7EXAMPLEsuffix",
        // Password keyword without separator
        "forgot password",
        // keyword_count pattern
        "secret_count: 0",
        // gh prefix without the right 3rd char
        "ghz_notarealtoken_blahblahblahblahblahblahblahblah",
        // Normal log line
        "INFO [2024-01-01] request completed in 42ms",
    };
    for (safe_lines) |line| {
        const r = try redactSecretsAlloc(std.testing.allocator, line);
        defer r.deinit(std.testing.allocator);
        if (r.changed) {
            std.debug.print("\nFalse positive on: {s}\n", .{line});
        }
        try std.testing.expect(!r.changed);
    }
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

test "file read rejects a symlinked directory component escaping the workspace" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A real directory and file OUTSIDE the workspace root (cwd's parent).
    const outside_rel = try std.fmt.allocPrint(
        std.testing.allocator,
        "../zz_agentd_escape_{s}",
        .{tmp.sub_path[0..]},
    );
    defer std.testing.allocator.free(outside_rel);
    var outside_dir = try std.Io.Dir.cwd().createDirPathOpen(io, outside_rel, .{});
    defer {
        outside_dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, outside_rel) catch {};
    }
    try outside_dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "TOPSECRET\n" });

    var abs_buffer: [4096]u8 = undefined;
    const abs_len = outside_dir.realPath(io, &abs_buffer) catch return error.SkipZigTest;
    const outside_abs = abs_buffer[0..abs_len];

    // A directory symlink INSIDE the workspace that points at the outside dir.
    tmp.dir.symLink(io, outside_abs, "evil", .{ .is_directory = true }) catch |e| switch (e) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return e,
    };

    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "evil", "secret.txt",
    });
    defer std.testing.allocator.free(path);

    // safeRelativePath passes (no `..`) and the final component `secret.txt`
    // is a regular file, so this escape is caught by the per-component symlink
    // walk seeing that the intermediate `evil` component is a symlink (the
    // realpath containment check is defense in depth on top).
    try std.testing.expectError(
        error.UnsafePath,
        readFileJsonAlloc(std.testing.allocator, io, path),
    );
}

test "file read rejects a symlinked final component" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "real.txt", .data = "data\n" });
    // The link target stays INSIDE the workspace, so the realpath containment
    // check would not flag it — proving the per-component symlink walk is what
    // rejects a symlinked final component.
    tmp.dir.symLink(io, "real.txt", "link.txt", .{}) catch |e| switch (e) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return e,
    };

    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "link.txt",
    });
    defer std.testing.allocator.free(path);

    try std.testing.expectError(
        error.UnsafePath,
        readFileJsonAlloc(std.testing.allocator, io, path),
    );
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

test "shouldKill correctly identifies timed-out commands" {
    // Not yet timed out: elapsed < timeout.
    try std.testing.expect(!shouldKill(500, 0, 1000));
    // Exactly at the limit: should kill.
    try std.testing.expect(shouldKill(1000, 0, 1000));
    // Well past the limit.
    try std.testing.expect(shouldKill(5000, 0, 1000));
    // Non-zero start time.
    try std.testing.expect(!shouldKill(1_000_000_200, 1_000_000_000, 1000));
    try std.testing.expect(shouldKill(1_000_001_000, 1_000_000_000, 1000));
    // Clock went backward — never kill.
    try std.testing.expect(!shouldKill(0, 500, 1000));
}

test "audit policy export is stateless and describes all tools" {
    const json = try auditPolicyJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    // Required top-level fields.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"audit_mode\":\"stateless_policy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"redaction\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"output_caps\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tools\":[") != null);
    // Each tool spec must appear.
    for (specs) |spec| {
        try std.testing.expect(std.mem.indexOf(u8, json, spec.name) != null);
        try std.testing.expect(std.mem.indexOf(u8, json, spec.effect) != null);
    }
    // Approval-required tools must set requires_host: true.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_host\":true") != null);
    // Read-only tools must have requires_host: false.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requires_host\":false") != null);
    // Redaction patterns listed.
    try std.testing.expect(std.mem.indexOf(u8, json, "aws_akia") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pem_private_key") != null);
}

test "error codes are snake_case for all known tool errors" {
    const known_errors = [_]anyerror{
        error.MissingTool,
        error.UnknownTool,
        error.MissingPath,
        error.UnsafePath,
        error.MissingQuery,
        error.EmptyQuery,
        error.InvalidQuery,
        error.QueryTooLarge,
        error.MissingText,
        error.EmptyText,
        error.InvalidText,
        error.TextTooLarge,
        error.UnsupportedBuildCommand,
        error.InvalidZigPath,
        error.ConfiguredZigUnavailable,
        error.ZigUnavailable,
        error.ToolTimedOut,
        error.FileNotFound,
        error.AccessDenied,
    };
    for (known_errors) |err| {
        const code = errorCode(err);
        try std.testing.expect(code.len > 0);
        // snake_case: no uppercase letters.
        for (code) |c| {
            try std.testing.expect(!(c >= 'A' and c <= 'Z'));
        }
        // No CamelCase: first letter lowercase or underscore.
        try std.testing.expect(code[0] != '_');
    }
    // Representative spot-checks.
    try std.testing.expectEqualStrings("unknown_tool", errorCode(error.UnknownTool));
    try std.testing.expectEqualStrings("missing_path", errorCode(error.MissingPath));
    try std.testing.expectEqualStrings("invalid_query", errorCode(error.InvalidQuery));
    try std.testing.expectEqualStrings("tool_timed_out", errorCode(error.ToolTimedOut));
}

test "error envelope shape for unknown tool" {
    // Simulate the envelope written for an UnknownTool error.
    const code = errorCode(error.UnknownTool);
    const msg = errorMessage(error.UnknownTool);
    const envelope = try protocol.writeErrorEnvelope(std.testing.allocator, "1", code, msg);
    defer std.testing.allocator.free(envelope);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"code\":\"unknown_tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"message\":\"unknown tool name\"") != null);
}

test "error envelope shape for missing path" {
    const envelope = try protocol.writeErrorEnvelope(
        std.testing.allocator,
        "null",
        errorCode(error.MissingPath),
        errorMessage(error.MissingPath),
    );
    defer std.testing.allocator.free(envelope);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"code\":\"missing_path\"") != null);
}
