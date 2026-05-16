const std = @import("std");
const agentd = @import("lib.zig");

const Allocator = std.mem.Allocator;
const max_agent_prompt_bytes = 64 * 1024;

pub fn main(init_data: std.process.Init) !void {
    const allocator = init_data.gpa;
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init_data.io, &stdout_buffer);
    var stderr = std.Io.File.stderr().writer(init_data.io, &stderr_buffer);
    defer stdout.interface.flush() catch {};
    defer stderr.interface.flush() catch {};

    var args = try std.process.Args.Iterator.initAllocator(init_data.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    const first = args.next() orelse {
        try printHelp(&stdout.interface);
        return;
    };

    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        try printHelp(&stdout.interface);
    } else if (std.mem.eql(u8, first, "--describe-tools")) {
        const json = try agentd.tools.listJsonAlloc(allocator);
        defer allocator.free(json);
        try stdout.interface.print("{s}\n", .{json});
    } else if (std.mem.eql(u8, first, "--stdio")) {
        try runStdio(allocator, init_data.io, init_data.environ_map, &stdout.interface);
    } else if (std.mem.eql(u8, first, "--oneshot")) {
        const prompt = args.next() orelse {
            try stderr.interface.print("ziggyzag-agentd: --oneshot requires a prompt\n", .{});
            return error.MissingPrompt;
        };
        try runOneShot(allocator, init_data.io, init_data.environ_map, prompt, &stdout.interface);
    } else if (std.mem.eql(u8, first, "--provider-request")) {
        const prompt = args.next() orelse "hello";
        const config = agentd.provider.Config.fromEnv(init_data.environ_map);
        const body = try config.requestBodyAlloc(allocator, prompt);
        defer allocator.free(body);
        const endpoint = try config.endpointAlloc(allocator);
        defer allocator.free(endpoint);
        try stdout.interface.print("POST {s}\n{s}\n", .{ endpoint, body });
    } else {
        try stderr.interface.print("ziggyzag-agentd: unknown argument: {s}\n\n", .{first});
        try printHelp(&stderr.interface);
        return error.UnknownArgument;
    }
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\ZiggyZag AgentD
        \\
        \\A slim Zig-native agent runtime for the ZiggyZag terminal.
        \\
        \\Usage:
        \\  ziggyzag-agentd --describe-tools
        \\  ziggyzag-agentd --stdio
        \\  ziggyzag-agentd --oneshot "what changed?"
        \\  ziggyzag-agentd --provider-request "draft a plan"
        \\
        \\Environment:
        \\  ZIGGYZAG_AGENT_PROVIDER=ollama | openai-compatible
        \\  ZIGGYZAG_AGENT_BASE_URL=http://127.0.0.1:11434
        \\  ZIGGYZAG_AGENT_MODEL=qwen2.5-coder:1.5b
        \\  ZIGGYZAG_AGENT_API_KEY=...
        \\  ZIGGYZAG_AGENT_STREAM=1
        \\
        \\JSON-line methods:
        \\  {"id":0,"method":"agent/health"}
        \\  {"id":1,"method":"tools/list"}    # includes schemas, approval, effect, and context policy
        \\  {"id":2,"method":"tools/call","tool":"project.info"}
        \\  {"id":3,"method":"tools/call","tool":"file.read","path":"README.md"}
        \\  {"id":4,"method":"tools/call","tool":"rg.search","query":"TODO"}
        \\  {"id":5,"method":"tools/call","tool":"terminal.write","text":"zig build\n"}  # approval-shaped host action
        \\  {"id":6,"method":"agent/run","prompt":"summarize the workspace"}
        \\
    );
}

fn runOneShot(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    prompt: []const u8,
    writer: *std.Io.Writer,
) !void {
    const result = providerAgentRunJsonAlloc(allocator, io, env, prompt) catch |err|
        try localAgentRunJsonAlloc(allocator, env, prompt, providerFallbackStatus(err));
    defer allocator.free(result);
    try writer.print("{s}\n", .{result});
}

fn runStdio(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    writer: *std.Io.Writer,
) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    while (true) {
        const line = (try stdin.interface.takeDelimiter('\n')) orelse break;
        const request_line = std.mem.trim(u8, line, " \t\r");
        if (request_line.len == 0) continue;
        var request = agentd.protocol.parseRequestAlloc(allocator, request_line) catch |err| {
            const json = try agentd.protocol.writeErrorEnvelope(
                allocator,
                agentd.protocol.bestEffortId(request_line),
                agentd.protocol.parseErrorCode(err),
                agentd.protocol.parseErrorMessage(err),
            );
            defer allocator.free(json);
            try writer.writeAll(json);
            continue;
        };
        defer request.deinit();
        try handleRequest(allocator, io, env, request, writer);
    }
}

fn handleRequest(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    request: agentd.protocol.Request,
    writer: *std.Io.Writer,
) !void {
    if (std.mem.eql(u8, request.method, "agent/health")) {
        const result = try agentd.provider.statusJsonAlloc(allocator, io, env);
        defer allocator.free(result);
        const envelope = try agentd.protocol.writeOkEnvelope(allocator, request.id, result);
        defer allocator.free(envelope);
        try writer.writeAll(envelope);
        return;
    }

    if (std.mem.eql(u8, request.method, "tools/list")) {
        const result = try agentd.tools.listJsonAlloc(allocator);
        defer allocator.free(result);
        const envelope = try agentd.protocol.writeOkEnvelope(allocator, request.id, result);
        defer allocator.free(envelope);
        try writer.writeAll(envelope);
        return;
    }

    if (std.mem.eql(u8, request.method, "tools/call")) {
        const result = agentd.tools.run(allocator, io, env, request) catch |err| {
            const envelope = try agentd.protocol.writeErrorEnvelope(allocator, request.id, @errorName(err), agentd.tools.errorMessage(err));
            defer allocator.free(envelope);
            try writer.writeAll(envelope);
            return;
        };
        defer result.deinit(allocator);
        const envelope = try agentd.protocol.writeOkEnvelope(allocator, request.id, result.json);
        defer allocator.free(envelope);
        try writer.writeAll(envelope);
        return;
    }

    if (std.mem.eql(u8, request.method, "agent/run")) {
        const prompt = request.prompt orelse "";
        validateAgentPrompt(prompt) catch |err| {
            const envelope = try agentd.protocol.writeErrorEnvelope(allocator, request.id, @errorName(err), agentRunErrorMessage(err));
            defer allocator.free(envelope);
            try writer.writeAll(envelope);
            return;
        };
        const result = providerAgentRunJsonAlloc(allocator, io, env, prompt) catch |err|
            try localAgentRunJsonAlloc(allocator, env, prompt, providerFallbackStatus(err));
        defer allocator.free(result);
        const envelope = try agentd.protocol.writeOkEnvelope(allocator, request.id, result);
        defer allocator.free(envelope);
        try writer.writeAll(envelope);
        return;
    }

    const envelope = try agentd.protocol.writeErrorEnvelope(allocator, request.id, "unknown_method", request.method);
    defer allocator.free(envelope);
    try writer.writeAll(envelope);
}

fn localAgentRunJsonAlloc(
    allocator: Allocator,
    env: *std.process.Environ.Map,
    prompt: []const u8,
    status: []const u8,
) ![]u8 {
    const config = agentd.provider.Config.fromEnv(env);
    const endpoint = try config.endpointAlloc(allocator);
    defer allocator.free(endpoint);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"provider\":");
    try agentd.protocol.appendJsonString(allocator, &out, config.kind.name());
    try out.appendSlice(allocator, ",\"model\":");
    try agentd.protocol.appendJsonString(allocator, &out, config.model);
    try out.appendSlice(allocator, ",\"endpoint\":");
    try agentd.protocol.appendJsonString(allocator, &out, endpoint);
    try out.appendSlice(allocator, ",\"prompt\":");
    try agentd.protocol.appendJsonString(allocator, &out, prompt);
    try out.appendSlice(allocator, ",\"status\":");
    try agentd.protocol.appendJsonString(allocator, &out, status);
    try out.appendSlice(allocator, ",\"next_tools\":[\"tools/list\",\"tools/call\"]}");
    return out.toOwnedSlice(allocator);
}

fn providerAgentRunJsonAlloc(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    prompt: []const u8,
) ![]u8 {
    const config = agentd.provider.Config.fromEnv(env);
    const endpoint = try config.endpointAlloc(allocator);
    defer allocator.free(endpoint);
    const body = try config.requestBodyAlloc(allocator, prompt);
    defer allocator.free(body);

    if (config.kind == .openai_compatible and config.api_key == null) return error.MissingApiKey;
    if (!agentd.provider.curlAvailable(allocator, io, env)) return error.CurlUnavailable;
    const call = try callProviderCurl(allocator, io, env, config, endpoint, body);
    defer call.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"provider\":");
    try agentd.protocol.appendJsonString(allocator, &out, config.kind.name());
    try out.appendSlice(allocator, ",\"model\":");
    try agentd.protocol.appendJsonString(allocator, &out, config.model);
    try out.appendSlice(allocator, ",\"endpoint\":");
    try agentd.protocol.appendJsonString(allocator, &out, endpoint);
    try out.appendSlice(allocator, ",\"status\":");
    try agentd.protocol.appendJsonString(allocator, &out, if (call.status == 0) "ok" else "provider_error");
    try out.appendSlice(allocator, ",\"raw_response\":");
    try agentd.protocol.appendJsonString(allocator, &out, call.stdout);
    try out.appendSlice(allocator, ",\"stderr\":");
    try agentd.protocol.appendJsonString(allocator, &out, call.stderr);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn providerFallbackStatus(err: anyerror) []const u8 {
    return switch (err) {
        error.CurlUnavailable, error.FileNotFound => "curl_unavailable",
        error.MissingApiKey => "missing_api_key",
        error.AccessDenied => "provider_unavailable",
        error.ConnectionRefused => "provider_unavailable",
        else => "provider_unavailable",
    };
}

const ProviderCall = struct {
    stdout: []u8,
    stderr: []u8,
    status: u8,

    fn deinit(self: ProviderCall, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn callProviderCurl(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    config: agentd.provider.Config,
    endpoint: []const u8,
    body: []const u8,
) !ProviderCall {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |header| allocator.free(header);

    try argv.appendSlice(allocator, &.{
        "curl",
        "-sS",
        "-f",
        "-N",
        "--max-time",
        "90",
        "-H",
        "Content-Type: application/json",
    });
    if (config.kind == .openai_compatible) {
        const api_key = config.api_key orelse return error.MissingApiKey;
        auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
        try argv.appendSlice(allocator, &.{ "-H", auth_header.? });
    }
    try argv.appendSlice(allocator, &.{ "-d", "@-", endpoint });

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    var stdin_file = child.stdin.?;
    try stdin_file.writeStreamingAll(io, body);
    stdin_file.close(io);
    child.stdin = null;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(io, &stdout_buffer);
    const stdout = try stdout_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    errdefer allocator.free(stdout);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.readerStreaming(io, &stderr_buffer);
    const stderr = try stderr_reader.interface.allocRemaining(allocator, .limited(128 * 1024));
    errdefer allocator.free(stderr);

    const term = try child.wait(io);
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .status = termStatus(term),
    };
}

fn validateAgentPrompt(prompt: []const u8) !void {
    if (prompt.len > max_agent_prompt_bytes) return error.PromptTooLarge;
    if (std.mem.indexOfScalar(u8, prompt, 0) != null) return error.InvalidPrompt;
}

fn agentRunErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.PromptTooLarge => "agent/run prompt is too large",
        error.InvalidPrompt => "agent/run prompt contains invalid bytes",
        else => "agent/run request is invalid",
    };
}

fn termStatus(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => 128,
        .stopped => 128,
        .unknown => 1,
    };
}
