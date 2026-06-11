const std = @import("std");
const agentd = @import("lib.zig");

const Allocator = std.mem.Allocator;
const max_agent_prompt_bytes = 64 * 1024;

// Session-scoped cancel flag. Set by agent/cancel; cleared before each
// agent/run. The streaming loop checks this flag on every chunk so the
// host can abort a long generation without waiting for curl to finish.
// Access is relaxed — the writer thread owns the run and reads the flag;
// the reader loop (a separate OS thread) sets it. There is no ordering
// dependency between setting the flag and any other memory operation, so
// relaxed is correct and cheaper than acquire/release.
var g_cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

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
        \\  {"id":7,"method":"audit/policy"}                                # stateless tool-effect and redaction policy
        \\  {"id":8,"method":"agent/cancel"}                                # abort an in-flight agent/run (streaming only)
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
        // A line longer than stdin_buffer (or an underlying read failure) would
        // otherwise propagate out and tear down the whole JSON-lines session on
        // a single bad input. Emit a structured error and stop cleanly — with a
        // fixed buffer we can't safely resume mid-line, and continuing would
        // re-hit the full buffer in a tight loop.
        const maybe_line = stdin.interface.takeDelimiter('\n') catch |err| {
            const json = agentd.protocol.writeErrorEnvelope(allocator, "", "read_error", @errorName(err)) catch break;
            writer.writeAll(json) catch {};
            allocator.free(json);
            break;
        };
        const line = maybe_line orelse break;
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
            const envelope = try agentd.protocol.writeErrorEnvelope(allocator, request.id, agentd.tools.errorCode(err), agentd.tools.errorMessage(err));
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

    if (std.mem.eql(u8, request.method, "audit/policy")) {
        const result = try agentd.tools.auditPolicyJsonAlloc(allocator);
        defer allocator.free(result);
        const envelope = try agentd.protocol.writeOkEnvelope(allocator, request.id, result);
        defer allocator.free(envelope);
        try writer.writeAll(envelope);
        return;
    }

    // agent/cancel: signal any in-flight agent/run to stop after the current
    // chunk. The acknowledgment is sent immediately; the cancellation effect
    // is asynchronous (the streaming loop notices on its next iteration).
    if (std.mem.eql(u8, request.method, "agent/cancel")) {
        g_cancel.store(true, .monotonic);
        const result = "{\"cancelled\":true}";
        const envelope = try agentd.protocol.writeOkEnvelope(allocator, request.id, result);
        defer allocator.free(envelope);
        try writer.writeAll(envelope);
        return;
    }

    if (std.mem.eql(u8, request.method, "agent/run")) {
        // Clear any stale cancel from a previous run before starting.
        g_cancel.store(false, .monotonic);
        const prompt = request.prompt orelse "";
        validateAgentPrompt(prompt) catch |err| {
            const envelope = try agentd.protocol.writeErrorEnvelope(allocator, request.id, agentRunErrorCode(err), agentRunErrorMessage(err));
            defer allocator.free(envelope);
            try writer.writeAll(envelope);
            return;
        };
        const config = agentd.provider.Config.fromEnv(env);
        if (config.stream and agentd.provider.curlAvailable(allocator, io, env)) {
            streamProviderAgentRun(allocator, io, env, request.id, prompt, writer) catch |err| {
                const fallback_result = try localAgentRunJsonAlloc(allocator, env, prompt, providerFallbackStatus(err));
                defer allocator.free(fallback_result);
                const envelope = try agentd.protocol.writeOkEnvelope(allocator, request.id, fallback_result);
                defer allocator.free(envelope);
                try writer.writeAll(envelope);
            };
            return;
        }
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

/// Stream an agent/run request to the provider, emitting one
/// {"id":N,"event":"agent/stream","delta":"..."} line per content chunk, then
/// a final ok-envelope with the assembled full response text.
///
/// Ollama chunks (stream:true): {"message":{"content":"..."}, "done":false}
/// OpenAI chunks (stream:true): data: {"choices":[{"delta":{"content":"..."}}]}
///
/// Non-content lines (role-only chunks, [DONE] sentinel) are skipped silently.
/// Secrets are redacted from every delta before it leaves the process.
fn streamProviderAgentRun(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    request_id: []const u8,
    prompt: []const u8,
    writer: *std.Io.Writer,
) !void {
    const config = agentd.provider.Config.fromEnv(env);
    const endpoint = try config.endpointAlloc(allocator);
    defer allocator.free(endpoint);
    const body = try config.requestBodyAlloc(allocator, prompt);
    defer allocator.free(body);

    if (config.kind == .openai_compatible and config.api_key == null) return error.MissingApiKey;

    // Build curl argv for streaming (same as non-streaming but body via stdin).
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var auth_file: ?agentd.provider.AuthHeaderFile = null;
    defer if (auth_file) |f| f.deinit(allocator, io);
    var auth_arg: ?[]u8 = null;
    defer if (auth_arg) |a| allocator.free(a);

    try argv.appendSlice(allocator, &.{
        "curl",
        "-sS",
        "-f",
        "-N",
        "--max-time",
        "120",
        "-H",
        "Content-Type: application/json",
    });
    if (config.kind == .openai_compatible) {
        const api_key = config.api_key orelse return error.MissingApiKey;
        auth_file = try agentd.provider.writeAuthHeaderFile(allocator, io, env, api_key);
        auth_arg = try std.fmt.allocPrint(allocator, "@{s}", .{auth_file.?.path});
        try argv.appendSlice(allocator, &.{ "-H", auth_arg.? });
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

    // Feed the request body and close stdin so curl sends the request.
    var stdin_file = child.stdin.?;
    try stdin_file.writeStreamingAll(io, body);
    stdin_file.close(io);
    child.stdin = null;

    // Drain stderr on a thread to prevent pipe-full deadlock.
    var drain = StderrDrain{ .io = io, .file = child.stderr.?, .allocator = allocator };
    const stderr_thread = try std.Thread.spawn(.{}, StderrDrain.run, .{&drain});

    // Read stdout line by line, emit stream events for each content chunk.
    var stdout_buf: [8192]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(io, &stdout_buf);

    var full_text: std.ArrayList(u8) = .empty;
    defer full_text.deinit(allocator);

    // Read stdout line by line using the same takeDelimiter('\n') API used by
    // runStdio. Each line is one streaming chunk from the provider.
    var cancelled = false;
    while (true) {
        // Check the session-scoped cancel flag before each chunk. The host
        // sets it via agent/cancel; we kill the curl child and break so the
        // final envelope reports the cancellation.
        if (g_cancel.load(.monotonic)) {
            cancelled = true;
            child.kill(io);
            break;
        }
        const maybe_line = stdout_reader.interface.takeDelimiter('\n') catch break;
        const raw_line = maybe_line orelse break;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        // OpenAI SSE lines are prefixed "data: "; strip the prefix.
        const chunk = if (std.mem.startsWith(u8, line, "data: "))
            line["data: ".len..]
        else
            line;

        // Skip the SSE stream terminator.
        if (std.mem.eql(u8, chunk, "[DONE]")) continue;

        // Extract content delta. Skip chunks with no content (role-only, etc).
        const delta_raw = extractContentDelta(config.kind, chunk) orelse continue;
        if (delta_raw.len == 0) continue;

        // Redact secrets from the delta before it leaves the process.
        const redacted = try agentd.tools.redactSecretsAlloc(allocator, delta_raw);
        defer redacted.deinit(allocator);
        const delta = redacted.text;

        // Accumulate into the full response text for the final envelope.
        try full_text.appendSlice(allocator, delta);

        // Emit the stream event line to the host.
        var event_buf: std.ArrayList(u8) = .empty;
        defer event_buf.deinit(allocator);
        try event_buf.appendSlice(allocator, "{\"id\":");
        try agentd.protocol.appendJsonString(allocator, &event_buf, request_id);
        try event_buf.appendSlice(allocator, ",\"event\":\"agent/stream\",\"delta\":");
        try agentd.protocol.appendJsonString(allocator, &event_buf, delta);
        try event_buf.append(allocator, '}');
        try event_buf.append(allocator, '\n');
        try writer.writeAll(event_buf.items);
        try writer.flush();
    }

    stderr_thread.join();
    const term = try child.wait(io);
    const exit_status = termStatus(term);

    // If cancelled, emit an error envelope instead of the normal ok envelope
    // so the host knows the stream was cut short deliberately.
    if (cancelled) {
        if (drain.out) |buf| allocator.free(buf);
        const envelope = try agentd.protocol.writeErrorEnvelope(allocator, request_id, "cancelled", "agent/run was cancelled by agent/cancel");
        defer allocator.free(envelope);
        try writer.writeAll(envelope);
        try writer.flush();
        return;
    }

    // Redact the assembled full text one final time for the envelope.
    const full_redacted = try agentd.tools.redactSecretsAlloc(allocator, full_text.items);
    defer full_redacted.deinit(allocator);
    const stderr_redacted = try agentd.tools.redactSecretsAlloc(
        allocator,
        drain.out orelse "",
    );
    defer stderr_redacted.deinit(allocator);
    if (drain.out) |buf| allocator.free(buf);

    // Emit the final ok-envelope so the host knows the stream is complete.
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    try result.appendSlice(allocator, "{\"provider\":");
    try agentd.protocol.appendJsonString(allocator, &result, config.kind.name());
    try result.appendSlice(allocator, ",\"model\":");
    try agentd.protocol.appendJsonString(allocator, &result, config.model);
    try result.appendSlice(allocator, ",\"endpoint\":");
    try agentd.protocol.appendJsonString(allocator, &result, endpoint);
    try result.appendSlice(allocator, ",\"status\":");
    try agentd.protocol.appendJsonString(allocator, &result, if (exit_status == 0) "ok" else "provider_error");
    try result.appendSlice(allocator, ",\"stream\":true,\"full_text\":");
    try agentd.protocol.appendJsonString(allocator, &result, full_redacted.text);
    try result.appendSlice(allocator, ",\"redacted\":");
    try result.appendSlice(allocator, if (full_redacted.changed or stderr_redacted.changed) "true" else "false");
    try result.append(allocator, '}');

    const envelope = try agentd.protocol.writeOkEnvelope(allocator, request_id, result.items);
    defer allocator.free(envelope);
    try writer.writeAll(envelope);
    try writer.flush();
}

/// Extract the content text from one streaming chunk line.
/// Returns null for role-only or empty-delta chunks.
fn extractContentDelta(kind: agentd.provider.Kind, chunk: []const u8) ?[]const u8 {
    // Both providers use "content":"..." somewhere in the chunk.
    // Find the key and extract the string value without allocation.
    // The key to look for:
    //   Ollama:  {"message":{"content":"DELTA",...},...}
    //   OpenAI:  {"choices":[{"delta":{"content":"DELTA"},...}],...}
    _ = kind; // same extraction logic works for both providers
    const needle = "\"content\":\"";
    const start_idx = std.mem.indexOf(u8, chunk, needle) orelse return null;
    const val_start = start_idx + needle.len;
    if (val_start >= chunk.len) return null;
    // Scan forward handling basic JSON escape sequences to find the closing quote.
    // We only unescape \n, \t, \\, \" — sufficient for prose content.
    var end = val_start;
    while (end < chunk.len) {
        if (chunk[end] == '\\' and end + 1 < chunk.len) {
            end += 2; // skip escape pair
        } else if (chunk[end] == '"') {
            break;
        } else {
            end += 1;
        }
    }
    const raw = chunk[val_start..end];
    return if (raw.len == 0) null else raw;
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

    // Provider stdout/stderr can echo secret-shaped strings (a key pasted into
    // a prompt, an auth header bounced back in an error body). Redact both
    // before they enter the envelope, matching the file.read / rg.search /
    // git.diff tool paths and the "redacted output" posture in the README.
    const response_redacted = try agentd.tools.redactSecretsAlloc(allocator, call.stdout);
    defer response_redacted.deinit(allocator);
    const stderr_redacted = try agentd.tools.redactSecretsAlloc(allocator, call.stderr);
    defer stderr_redacted.deinit(allocator);

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
    try agentd.protocol.appendJsonString(allocator, &out, response_redacted.text);
    try out.appendSlice(allocator, ",\"stderr\":");
    try agentd.protocol.appendJsonString(allocator, &out, stderr_redacted.text);
    try out.appendSlice(allocator, ",\"redacted\":");
    try out.appendSlice(allocator, if (response_redacted.changed or stderr_redacted.changed) "true" else "false");
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

/// Drains a child pipe on its own thread so stdout and stderr are read
/// concurrently. Reading them sequentially deadlocks: curl can fill the
/// stderr pipe buffer (and block) while the parent is still blocked reading
/// stdout that never closes.
const StderrDrain = struct {
    io: std.Io,
    file: std.Io.File,
    allocator: Allocator,
    out: ?[]u8 = null,
    err: ?anyerror = null,

    fn run(self: *StderrDrain) void {
        var buffer: [4096]u8 = undefined;
        var reader = self.file.readerStreaming(self.io, &buffer);
        self.out = reader.interface.allocRemaining(self.allocator, .limited(128 * 1024)) catch |e| {
            self.err = e;
            return;
        };
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
    // The bearer token goes through a private 0600 temp file passed as
    // `-H @path`, never as an argv element — see writeAuthHeaderFile. Both the
    // file and the `@path` argument live until this function returns, by which
    // point curl has already run to completion.
    var auth_file: ?agentd.provider.AuthHeaderFile = null;
    defer if (auth_file) |f| f.deinit(allocator, io);
    var auth_arg: ?[]u8 = null;
    defer if (auth_arg) |a| allocator.free(a);

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
        auth_file = try agentd.provider.writeAuthHeaderFile(allocator, io, env, api_key);
        auth_arg = try std.fmt.allocPrint(allocator, "@{s}", .{auth_file.?.path});
        try argv.appendSlice(allocator, &.{ "-H", auth_arg.? });
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

    var drain = StderrDrain{ .io = io, .file = child.stderr.?, .allocator = allocator };
    const stderr_thread = try std.Thread.spawn(.{}, StderrDrain.run, .{&drain});

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(io, &stdout_buffer);
    const stdout_result = stdout_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));

    // The thread borrows `drain` and the stderr pipe, so it must finish before
    // this frame returns under any path.
    stderr_thread.join();

    const stdout = stdout_result catch |e| {
        if (drain.out) |buf| allocator.free(buf);
        return e;
    };
    errdefer allocator.free(stdout);
    if (drain.err) |e| return e;
    const stderr = drain.out orelse return error.Unexpected;
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

fn agentRunErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.PromptTooLarge => "prompt_too_large",
        error.InvalidPrompt => "invalid_prompt",
        else => "invalid_request",
    };
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
