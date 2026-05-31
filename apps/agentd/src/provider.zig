const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum {
    ollama,
    openai_compatible,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .ollama => "ollama",
            .openai_compatible => "openai-compatible",
        };
    }
};

pub const Config = struct {
    kind: Kind = .ollama,
    base_url: []const u8 = "http://127.0.0.1:11434",
    model: []const u8 = "qwen2.5-coder:1.5b",
    api_key: ?[]const u8 = null,
    stream: bool = false,

    pub fn fromEnv(env: *std.process.Environ.Map) Config {
        const provider = env.get("ZIGGYZAG_AGENT_PROVIDER") orelse "ollama";
        const kind: Kind = if (std.ascii.eqlIgnoreCase(provider, "openai") or
            std.ascii.eqlIgnoreCase(provider, "openai-compatible"))
            .openai_compatible
        else
            .ollama;

        return .{
            .kind = kind,
            .base_url = env.get("ZIGGYZAG_AGENT_BASE_URL") orelse defaultBaseUrl(kind),
            .model = env.get("ZIGGYZAG_AGENT_MODEL") orelse defaultModel(kind),
            .api_key = env.get("ZIGGYZAG_AGENT_API_KEY") orelse env.get("OPENAI_API_KEY"),
            .stream = envFlag(env, "ZIGGYZAG_AGENT_STREAM"),
        };
    }

    pub fn endpointAlloc(self: Config, allocator: Allocator) ![]u8 {
        const base = trimTrailingSlash(self.base_url);
        return switch (self.kind) {
            .ollama => try std.fmt.allocPrint(allocator, "{s}/api/chat", .{base}),
            .openai_compatible => blk: {
                if (std.mem.endsWith(u8, base, "/v1")) {
                    break :blk try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base});
                }
                break :blk try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{base});
            },
        };
    }

    pub fn healthEndpointAlloc(self: Config, allocator: Allocator) ![]u8 {
        const base = trimTrailingSlash(self.base_url);
        return switch (self.kind) {
            .ollama => try std.fmt.allocPrint(allocator, "{s}/api/tags", .{base}),
            .openai_compatible => blk: {
                if (std.mem.endsWith(u8, base, "/v1")) {
                    break :blk try std.fmt.allocPrint(allocator, "{s}/models", .{base});
                }
                break :blk try std.fmt.allocPrint(allocator, "{s}/v1/models", .{base});
            },
        };
    }

    pub fn requestBodyAlloc(self: Config, allocator: Allocator, prompt: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "{\"model\":");
        try protocol.appendJsonString(allocator, &out, self.model);
        try out.appendSlice(allocator, ",\"stream\":");
        try out.appendSlice(allocator, if (self.stream) "true" else "false");
        try out.appendSlice(allocator, ",\"messages\":[{\"role\":\"system\",\"content\":");
        try protocol.appendJsonString(allocator, &out, systemPrompt);
        try out.appendSlice(allocator, "},{\"role\":\"user\",\"content\":");
        try protocol.appendJsonString(allocator, &out, prompt);
        try out.appendSlice(allocator, "}]}");
        return out.toOwnedSlice(allocator);
    }
};

pub fn statusJsonAlloc(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
) ![]u8 {
    const config = Config.fromEnv(env);
    const endpoint = try config.endpointAlloc(allocator);
    defer allocator.free(endpoint);
    const health_endpoint = try config.healthEndpointAlloc(allocator);
    defer allocator.free(health_endpoint);
    const curl_ready = curlAvailable(allocator, io, env);
    const key_state = apiKeyState(config);
    const provider_status = providerStatus(allocator, io, env, config, health_endpoint, curl_ready, key_state);
    const ready = std.mem.eql(u8, provider_status, "reachable");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"provider\":");
    try protocol.appendJsonString(allocator, &out, config.kind.name());
    try out.appendSlice(allocator, ",\"model\":");
    try protocol.appendJsonString(allocator, &out, config.model);
    try out.appendSlice(allocator, ",\"endpoint\":");
    try protocol.appendJsonString(allocator, &out, endpoint);
    try out.appendSlice(allocator, ",\"health_endpoint\":");
    try protocol.appendJsonString(allocator, &out, health_endpoint);
    try out.appendSlice(allocator, ",\"stream\":");
    try out.appendSlice(allocator, if (config.stream) "true" else "false");
    try out.appendSlice(allocator, ",\"curl\":");
    try protocol.appendJsonString(allocator, &out, if (curl_ready) "available" else "unavailable");
    try out.appendSlice(allocator, ",\"api_key\":");
    try protocol.appendJsonString(allocator, &out, key_state);
    try out.appendSlice(allocator, ",\"provider_status\":");
    try protocol.appendJsonString(allocator, &out, provider_status);
    try out.appendSlice(allocator, ",\"ready\":");
    try out.appendSlice(allocator, if (ready) "true" else "false");
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn curlAvailable(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "curl", "--version" },
        .environ_map = env,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub const systemPrompt =
    \\You are ZiggyZag Agent, a small terminal-native coding assistant.
    \\Prefer short plans, explicit tool calls, and conservative edits.
    \\When you need host capabilities, ask for one of the advertised tools by name.
;

fn defaultBaseUrl(kind: Kind) []const u8 {
    return switch (kind) {
        .ollama => "http://127.0.0.1:11434",
        .openai_compatible => "https://api.openai.com",
    };
}

fn defaultModel(kind: Kind) []const u8 {
    return switch (kind) {
        .ollama => "qwen2.5-coder:1.5b",
        .openai_compatible => "gpt-4.1-mini",
    };
}

fn envFlag(env: *std.process.Environ.Map, name: []const u8) bool {
    const value = env.get(name) orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}

fn apiKeyState(config: Config) []const u8 {
    return switch (config.kind) {
        .ollama => "not_required",
        .openai_compatible => if (config.api_key == null) "missing" else "present",
    };
}

fn providerStatus(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    config: Config,
    health_endpoint: []const u8,
    curl_ready: bool,
    key_state: []const u8,
) []const u8 {
    if (std.mem.eql(u8, key_state, "missing")) return "missing_api_key";
    if (!curl_ready) return "curl_unavailable";
    return if (probeProviderHealth(allocator, io, env, config, health_endpoint)) "reachable" else "unreachable";
}

fn probeProviderHealth(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    config: Config,
    health_endpoint: []const u8,
) bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var auth_file: ?AuthHeaderFile = null;
    defer if (auth_file) |f| f.deinit(allocator, io);
    var auth_arg: ?[]u8 = null;
    defer if (auth_arg) |a| allocator.free(a);

    argv.appendSlice(allocator, &.{
        "curl",
        "-fsS",
        "--max-time",
        "2",
        "-o",
        nullDevicePath(),
    }) catch return false;

    if (config.kind == .openai_compatible) {
        const api_key = config.api_key orelse return false;
        auth_file = writeAuthHeaderFile(allocator, io, env, api_key) catch return false;
        auth_arg = std.fmt.allocPrint(allocator, "@{s}", .{auth_file.?.path}) catch return false;
        argv.appendSlice(allocator, &.{ "-H", auth_arg.? }) catch return false;
    }

    argv.append(allocator, health_endpoint) catch return false;

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .environ_map = env,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn nullDevicePath() []const u8 {
    return if (builtin.os.tag == .windows) "NUL" else "/dev/null";
}

/// A short-lived, private file holding the `Authorization` header. curl reads
/// it via `-H @path` (curl >= 7.55) so the bearer token never appears as a
/// curl argv element — argv is world-readable through `ps` and
/// `/proc/<pid>/cmdline` on multi-user POSIX hosts, which would otherwise leak
/// the most sensitive secret the daemon holds for the lifetime of the request.
pub const AuthHeaderFile = struct {
    path: []u8,

    pub fn deinit(self: AuthHeaderFile, allocator: Allocator, io: std.Io) void {
        std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
        allocator.free(self.path);
    }
};

fn authTempRoot(env: *const std.process.Environ.Map) []const u8 {
    if (env.get("TMPDIR")) |p| return p;
    if (env.get("TEMP")) |p| return p;
    if (env.get("TMP")) |p| return p;
    return if (builtin.os.tag == .windows) "." else "/tmp";
}

pub fn writeAuthHeaderFile(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    api_key: []const u8,
) !AuthHeaderFile {
    const root = authTempRoot(env);
    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        const hex = std.fmt.bytesToHex(random_bytes, .lower);
        const name = try std.fmt.allocPrint(allocator, "ziggyzag-auth-{s}", .{hex[0..]});
        defer allocator.free(name);

        const path = try std.fs.path.join(allocator, &.{ root, name });
        errdefer allocator.free(path);

        var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .mode = 0o600 }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => |e| return e,
        };
        errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
        defer file.close(io);

        const header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}\n", .{api_key});
        defer allocator.free(header);
        try file.writeStreamingAll(io, header);
        return .{ .path = path };
    }
    return error.TempFileCreateFailed;
}

fn trimTrailingSlash(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}

test "builds ollama request target and body" {
    const config = Config{};
    const endpoint = try config.endpointAlloc(std.testing.allocator);
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/api/chat", endpoint);

    const health_endpoint = try config.healthEndpointAlloc(std.testing.allocator);
    defer std.testing.allocator.free(health_endpoint);
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/api/tags", health_endpoint);

    const body = try config.requestBodyAlloc(std.testing.allocator, "hello");
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"qwen2.5-coder:1.5b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"hello\"") != null);
}

test "builds openai compatible endpoint with v1" {
    const config = Config{
        .kind = .openai_compatible,
        .base_url = "https://example.test/v1/",
        .model = "small",
    };
    const endpoint = try config.endpointAlloc(std.testing.allocator);
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://example.test/v1/chat/completions", endpoint);

    const health_endpoint = try config.healthEndpointAlloc(std.testing.allocator);
    defer std.testing.allocator.free(health_endpoint);
    try std.testing.expectEqualStrings("https://example.test/v1/models", health_endpoint);
}

test "builds openai compatible request body with escaped prompt" {
    const config = Config{
        .kind = .openai_compatible,
        .base_url = "https://example.test",
        .model = "small",
        .stream = false,
    };
    const body = try config.requestBodyAlloc(std.testing.allocator, "say \"hi\"\n");
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"small\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "say \\\"hi\\\"\\n") != null);
}

test "health reports missing OpenAI-compatible API key as not ready" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZIGGYZAG_AGENT_PROVIDER", "openai-compatible");
    try env.put("ZIGGYZAG_AGENT_BASE_URL", "https://example.test");

    const json = try statusJsonAlloc(std.testing.allocator, std.testing.io, &env);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider\":\"openai-compatible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"api_key\":\"missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider_status\":\"missing_api_key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ready\":false") != null);
}
