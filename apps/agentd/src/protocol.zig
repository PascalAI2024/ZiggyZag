const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Request = struct {
    id: []const u8 = "null",
    method: []const u8,
    prompt: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    path: ?[]const u8 = null,
    query: ?[]const u8 = null,
    command: ?[]const u8 = null,
    text: ?[]const u8 = null,
    parsed: ?std.json.Parsed(std.json.Value) = null,

    pub fn deinit(self: *Request) void {
        if (self.parsed) |*parsed| parsed.deinit();
        self.* = undefined;
    }
};

pub const ParseRequestError = error{
    EmptyRequest,
    InvalidJson,
    RequestMustBeObject,
    MissingMethod,
    MethodMustBeString,
    FieldMustBeString,
    IdMustBeStringNumberOrNull,
};

pub fn parseRequestAlloc(allocator: Allocator, line: []const u8) ParseRequestError!Request {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyRequest;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.InvalidJson;
    errdefer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.RequestMustBeObject,
    };

    if (object.get("id")) |id_value| {
        if (!validIdValue(id_value)) return error.IdMustBeStringNumberOrNull;
    }

    const method_value = object.get("method") orelse return error.MissingMethod;
    const method = stringValue(method_value) orelse return error.MethodMustBeString;

    return .{
        .id = bestEffortId(trimmed),
        .method = method,
        .prompt = try optionalString(object, "prompt"),
        .tool = try optionalString(object, "tool"),
        .path = try optionalString(object, "path"),
        .query = try optionalString(object, "query"),
        .command = try optionalString(object, "command"),
        .text = try optionalString(object, "text"),
        .parsed = parsed,
    };
}

pub fn parseRequest(line: []const u8) ?Request {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    const method = jsonStringValue(trimmed, "method") orelse return null;
    return .{
        .id = jsonRawValue(trimmed, "id") orelse "null",
        .method = method,
        .prompt = jsonStringValue(trimmed, "prompt"),
        .tool = jsonStringValue(trimmed, "tool"),
        .path = jsonStringValue(trimmed, "path"),
        .query = jsonStringValue(trimmed, "query"),
        .command = jsonStringValue(trimmed, "command"),
        .text = jsonStringValue(trimmed, "text"),
    };
}

pub fn parseErrorCode(err: ParseRequestError) []const u8 {
    return switch (err) {
        error.EmptyRequest => "empty_request",
        error.InvalidJson => "invalid_json",
        error.RequestMustBeObject => "request_must_be_object",
        error.MissingMethod => "missing_method",
        error.MethodMustBeString => "method_must_be_string",
        error.FieldMustBeString => "field_must_be_string",
        error.IdMustBeStringNumberOrNull => "id_must_be_string_number_or_null",
    };
}

pub fn parseErrorMessage(err: ParseRequestError) []const u8 {
    return switch (err) {
        error.EmptyRequest => "expected a non-empty JSON-line request",
        error.InvalidJson => "expected valid JSON on one line",
        error.RequestMustBeObject => "request must be a JSON object",
        error.MissingMethod => "request is missing a method field",
        error.MethodMustBeString => "method must be a string",
        error.FieldMustBeString => "optional request fields must be strings",
        error.IdMustBeStringNumberOrNull => "id must be a string, number, or null",
    };
}

pub fn bestEffortId(payload: []const u8) []const u8 {
    const raw = jsonRawValue(payload, "id") orelse return "null";
    if (!safeRawId(raw)) return "null";
    return raw;
}

pub fn jsonRawValue(payload: []const u8, key: []const u8) ?[]const u8 {
    const value_start = valueStart(payload, key) orelse return null;
    var index = value_start;
    if (index >= payload.len) return null;
    if (payload[index] == '"') {
        index += 1;
        var escaped = false;
        while (index < payload.len) : (index += 1) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (payload[index] == '\\') {
                escaped = true;
                continue;
            }
            if (payload[index] == '"') return payload[value_start .. index + 1];
        }
        return null;
    }
    while (index < payload.len and payload[index] != ',' and payload[index] != '}') : (index += 1) {}
    return std.mem.trim(u8, payload[value_start..index], " \t\r\n");
}

pub fn jsonStringValue(payload: []const u8, key: []const u8) ?[]const u8 {
    const start_quote = valueStart(payload, key) orelse return null;
    if (start_quote >= payload.len or payload[start_quote] != '"') return null;
    const value_start_index = start_quote + 1;
    var index = value_start_index;
    var escaped = false;
    while (index < payload.len) : (index += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (payload[index] == '\\') {
            escaped = true;
            continue;
        }
        if (payload[index] == '"') return payload[value_start_index..index];
    }
    return null;
}

pub fn writeOkEnvelope(
    allocator: Allocator,
    id: []const u8,
    result_json: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"id\":");
    try out.appendSlice(allocator, id);
    try out.appendSlice(allocator, ",\"ok\":true,\"result\":");
    try out.appendSlice(allocator, result_json);
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

pub fn writeErrorEnvelope(
    allocator: Allocator,
    id: []const u8,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"id\":");
    try out.appendSlice(allocator, id);
    try out.appendSlice(allocator, ",\"ok\":false,\"error\":{\"code\":");
    try appendJsonString(allocator, &out, code);
    try out.appendSlice(allocator, ",\"message\":");
    try appendJsonString(allocator, &out, message);
    try out.appendSlice(allocator, "}}\n");
    return out.toOwnedSlice(allocator);
}

pub fn appendJsonString(allocator: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(allocator, '"');
    for (text) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0c => try out.appendSlice(allocator, "\\f"),
            else => {
                if (byte < 0x20) {
                    var buf: [6]u8 = undefined;
                    const escaped = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{byte}) catch unreachable;
                    try out.appendSlice(allocator, escaped);
                } else {
                    try out.append(allocator, byte);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

pub fn objectWithTextField(
    allocator: Allocator,
    field: []const u8,
    value: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    try appendJsonString(allocator, &out, field);
    try out.append(allocator, ':');
    try appendJsonString(allocator, &out, value);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ParseRequestError!?[]const u8 {
    const value = object.get(key) orelse return null;
    return stringValue(value) orelse error.FieldMustBeString;
}

fn stringValue(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn validIdValue(value: std.json.Value) bool {
    return switch (value) {
        .null, .integer, .float, .number_string, .string => true,
        .bool, .array, .object => false,
    };
}

fn safeRawId(raw: []const u8) bool {
    if (raw.len == 0) return false;
    if (std.mem.eql(u8, raw, "null")) return true;
    if (raw[0] == '"') return raw.len >= 2 and raw[raw.len - 1] == '"';
    return raw[0] == '-' or std.ascii.isDigit(raw[0]);
}

fn valueStart(payload: []const u8, key: []const u8) ?usize {
    var index: usize = 0;
    while (index < payload.len) {
        const quote = std.mem.indexOfScalarPos(u8, payload, index, '"') orelse return null;
        const key_start = quote + 1;
        const key_end = std.mem.indexOfScalarPos(u8, payload, key_start, '"') orelse return null;
        if (std.mem.eql(u8, payload[key_start..key_end], key)) {
            var colon = key_end + 1;
            while (colon < payload.len and std.ascii.isWhitespace(payload[colon])) : (colon += 1) {}
            if (colon < payload.len and payload[colon] == ':') {
                var value = colon + 1;
                while (value < payload.len and std.ascii.isWhitespace(payload[value])) : (value += 1) {}
                return value;
            }
        }
        index = key_end + 1;
    }
    return null;
}

test "parses flat JSON request fields" {
    const request = parseRequest("{\"id\":7,\"method\":\"tools/call\",\"tool\":\"file.read\",\"path\":\"README.md\"}").?;
    try std.testing.expectEqualStrings("7", request.id);
    try std.testing.expectEqualStrings("tools/call", request.method);
    try std.testing.expectEqualStrings("file.read", request.tool.?);
    try std.testing.expectEqualStrings("README.md", request.path.?);
}

test "parses escaped request strings with allocator-backed JSON parser" {
    var request = try parseRequestAlloc(std.testing.allocator, "{\"id\":\"abc\",\"method\":\"tools/call\",\"tool\":\"terminal.write\",\"text\":\"zig build\\n\"}");
    defer request.deinit();

    try std.testing.expectEqualStrings("\"abc\"", request.id);
    try std.testing.expectEqualStrings("tools/call", request.method);
    try std.testing.expectEqualStrings("terminal.write", request.tool.?);
    try std.testing.expectEqualStrings("zig build\n", request.text.?);
}

test "reports bad request parse errors" {
    try std.testing.expectError(error.InvalidJson, parseRequestAlloc(std.testing.allocator, "{"));
    try std.testing.expectError(error.MissingMethod, parseRequestAlloc(std.testing.allocator, "{\"id\":1}"));
    try std.testing.expectError(error.MethodMustBeString, parseRequestAlloc(std.testing.allocator, "{\"id\":1,\"method\":42}"));
    try std.testing.expectError(error.FieldMustBeString, parseRequestAlloc(std.testing.allocator, "{\"id\":1,\"method\":\"tools/call\",\"path\":42}"));
    try std.testing.expectError(error.IdMustBeStringNumberOrNull, parseRequestAlloc(std.testing.allocator, "{\"id\":true,\"method\":\"tools/list\"}"));
}

test "keeps best effort id for parse error envelopes" {
    try std.testing.expectEqualStrings("99", bestEffortId("{\"id\":99,\"method\":42}"));
    try std.testing.expectEqualStrings("\"abc\"", bestEffortId("{\"id\":\"abc\",\"method\":42}"));
    try std.testing.expectEqualStrings("null", bestEffortId("{\"id\":true,\"method\":42}"));
}

test "escapes JSON strings" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendJsonString(std.testing.allocator, &out, "a\"b\\c\n");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", out.items);
}
