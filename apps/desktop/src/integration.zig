const std = @import("std");

const Allocator = std.mem.Allocator;
const prefix = "\x1b]777;ziggyzag:event:";
const bel: u8 = 0x07;
pub const default_max_payload_len: usize = 64 * 1024;
pub const default_max_event_len: usize = prefix.len + default_max_payload_len + 1;

pub const EventKind = enum {
    session_ready,
    prompt_rendered,
    command_started,
    command_finished,
    unknown,
};

pub const Event = struct {
    kind: EventKind,
    payload: []u8,

    pub fn deinit(self: Event, allocator: Allocator) void {
        allocator.free(self.payload);
    }
};

pub const Extracted = struct {
    display: []u8,
    events: std.ArrayList(Event),

    pub fn deinit(self: *Extracted, allocator: Allocator) void {
        allocator.free(self.display);
        for (self.events.items) |event| event.deinit(allocator);
        self.events.deinit(allocator);
    }
};

pub fn extract(allocator: Allocator, bytes: []const u8) !Extracted {
    var parser = Parser.init(allocator);
    defer parser.deinit();
    return parser.consume(bytes, true);
}

pub const Parser = struct {
    allocator: Allocator,
    carry: std.ArrayList(u8) = .empty,
    max_payload_len: usize = default_max_payload_len,

    pub fn init(allocator: Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn initWithMaxPayloadLen(allocator: Allocator, max_payload_len: usize) Parser {
        return .{
            .allocator = allocator,
            .max_payload_len = max_payload_len,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.carry.deinit(self.allocator);
    }

    pub fn feed(self: *Parser, bytes: []const u8) !Extracted {
        return self.consume(bytes, false);
    }

    pub fn flush(self: *Parser) !Extracted {
        return self.consume("", true);
    }

    fn maxEventLen(self: *const Parser) usize {
        return prefix.len + self.max_payload_len + 1;
    }

    fn consume(self: *Parser, bytes: []const u8, flush_incomplete: bool) !Extracted {
        var display: std.ArrayList(u8) = .empty;
        errdefer display.deinit(self.allocator);

        var events: std.ArrayList(Event) = .empty;
        errdefer {
            for (events.items) |event| event.deinit(self.allocator);
            events.deinit(self.allocator);
        }

        var source_owned: ?[]u8 = null;
        defer if (source_owned) |source| self.allocator.free(source);

        const source: []const u8 = if (self.carry.items.len == 0) bytes else source: {
            var combined: std.ArrayList(u8) = .empty;
            errdefer combined.deinit(self.allocator);
            try combined.appendSlice(self.allocator, self.carry.items);
            try combined.appendSlice(self.allocator, bytes);
            source_owned = try combined.toOwnedSlice(self.allocator);
            break :source source_owned.?;
        };
        self.carry.clearRetainingCapacity();

        var index: usize = 0;
        while (index < source.len) {
            if (std.mem.startsWith(u8, source[index..], prefix)) {
                const payload_start = index + prefix.len;
                const payload_end_offset = std.mem.indexOfScalar(u8, source[payload_start..], bel);
                if (payload_end_offset) |offset| {
                    const payload = source[payload_start .. payload_start + offset];
                    if (payload.len <= self.max_payload_len and isValidEventPayload(payload)) {
                        try events.append(self.allocator, .{
                            .kind = eventKind(payload),
                            .payload = try self.allocator.dupe(u8, payload),
                        });
                    }
                    index = payload_start + offset + 1;
                    continue;
                }

                if (source.len - index > self.maxEventLen()) {
                    index = source.len;
                    continue;
                }

                if (flush_incomplete) {
                    try display.appendSlice(self.allocator, source[index..]);
                } else {
                    try self.carry.appendSlice(self.allocator, source[index..]);
                }
                break;
            }

            if (!flush_incomplete and isPrefixFragment(source[index..])) {
                try self.carry.appendSlice(self.allocator, source[index..]);
                break;
            }

            try display.append(self.allocator, source[index]);
            index += 1;
        }

        return .{
            .display = try display.toOwnedSlice(self.allocator),
            .events = events,
        };
    }
};

fn isPrefixFragment(bytes: []const u8) bool {
    return bytes.len > 0 and bytes.len < prefix.len and std.mem.startsWith(u8, prefix, bytes);
}

fn isValidEventPayload(payload: []const u8) bool {
    const trimmed = std.mem.trim(u8, payload, " \n\r\t");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return false;
    return jsonStringValue(trimmed, "type") != null;
}

pub fn eventKind(payload: []const u8) EventKind {
    const event_type = jsonStringValue(payload, "type") orelse return .unknown;
    if (std.mem.eql(u8, event_type, "session.ready")) return .session_ready;
    if (std.mem.eql(u8, event_type, "prompt.rendered")) return .prompt_rendered;
    if (std.mem.eql(u8, event_type, "command.started")) return .command_started;
    if (std.mem.eql(u8, event_type, "command.finished")) return .command_finished;
    return .unknown;
}

pub fn jsonStringValue(payload: []const u8, key: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < payload.len) : (index += 1) {
        if (payload[index] != '"') continue;
        const key_start = index + 1;
        const key_end_offset = std.mem.indexOfScalar(u8, payload[key_start..], '"') orelse return null;
        const key_end = key_start + key_end_offset;
        index = key_end + 1;
        if (!std.mem.eql(u8, payload[key_start..key_end], key)) continue;

        while (index < payload.len and isJsonWhitespace(payload[index])) : (index += 1) {}
        if (index >= payload.len or payload[index] != ':') return null;
        index += 1;
        while (index < payload.len and isJsonWhitespace(payload[index])) : (index += 1) {}
        if (index >= payload.len or payload[index] != '"') return null;

        const value_start = index + 1;
        var value_end = value_start;
        while (value_end < payload.len) : (value_end += 1) {
            if (payload[value_end] == '"' and (value_end == value_start or payload[value_end - 1] != '\\')) {
                return payload[value_start..value_end];
            }
        }
        return null;
    }
    return null;
}

pub fn jsonIntValue(comptime T: type, payload: []const u8, key: []const u8) ?T {
    var index: usize = 0;
    while (index < payload.len) : (index += 1) {
        if (payload[index] != '"') continue;
        const key_start = index + 1;
        const key_end_offset = std.mem.indexOfScalar(u8, payload[key_start..], '"') orelse return null;
        const key_end = key_start + key_end_offset;
        index = key_end + 1;
        if (!std.mem.eql(u8, payload[key_start..key_end], key)) continue;

        while (index < payload.len and isJsonWhitespace(payload[index])) : (index += 1) {}
        if (index >= payload.len or payload[index] != ':') return null;
        index += 1;
        while (index < payload.len and isJsonWhitespace(payload[index])) : (index += 1) {}

        const value_start = index;
        if (index < payload.len and payload[index] == '-') index += 1;
        while (index < payload.len and std.ascii.isDigit(payload[index])) : (index += 1) {}
        if (index == value_start) return null;
        return std.fmt.parseInt(T, payload[value_start..index], 10) catch null;
    }
    return null;
}

fn isJsonWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\n' or byte == '\r' or byte == '\t';
}

/// Unescape a JSON string body (the raw bytes between the surrounding quotes,
/// as returned by `jsonStringValue`) into `dest`. Returns the number of bytes
/// written. Handles the common single-character escapes (`\\`, `\"`, `\/`,
/// `\n`, `\r`, `\t`, `\b`, `\f`) and skips unrecognised `\uXXXX` sequences
/// by emitting a replacement `?`. The destination is never overflowed; writing
/// stops when `dest` is full.
pub fn jsonUnescapeInto(dest: []u8, src: []const u8) usize {
    var di: usize = 0;
    var si: usize = 0;
    while (si < src.len and di < dest.len) {
        if (src[si] != '\\') {
            dest[di] = src[si];
            di += 1;
            si += 1;
            continue;
        }
        // backslash escape — need at least one more byte
        if (si + 1 >= src.len) break;
        si += 1;
        switch (src[si]) {
            '\\' => {
                dest[di] = '\\';
                di += 1;
            },
            '"' => {
                dest[di] = '"';
                di += 1;
            },
            '/' => {
                dest[di] = '/';
                di += 1;
            },
            'n' => {
                dest[di] = '\n';
                di += 1;
            },
            'r' => {
                dest[di] = '\r';
                di += 1;
            },
            't' => {
                dest[di] = '\t';
                di += 1;
            },
            'b' => {
                dest[di] = 0x08;
                di += 1;
            },
            'f' => {
                dest[di] = 0x0c;
                di += 1;
            },
            'u' => {
                // skip \uXXXX (4 hex digits); emit '?' as placeholder
                if (si + 4 < src.len) si += 4;
                dest[di] = '?';
                di += 1;
            },
            else => {
                dest[di] = src[si];
                di += 1;
            },
        }
        si += 1;
    }
    return di;
}

test "extracts OSC 777 events and strips them from display bytes" {
    const input = "a\x1b]777;ziggyzag:event:{\"type\":\"command.finished\",\"status\":0}\x07b";
    var extracted = try extract(std.testing.allocator, input);
    defer extracted.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ab", extracted.display);
    try std.testing.expectEqual(@as(usize, 1), extracted.events.items.len);
    try std.testing.expectEqual(EventKind.command_finished, extracted.events.items[0].kind);
}

test "keeps incomplete integration events visible" {
    const input = "a\x1b]777;ziggyzag:event:{\"type\":\"session.ready\"}";
    var extracted = try extract(std.testing.allocator, input);
    defer extracted.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(input, extracted.display);
    try std.testing.expectEqual(@as(usize, 0), extracted.events.items.len);
}

test "streaming parser extracts events split across chunks" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();

    var first = try parser.feed("a\x1b]777;zig");
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a", first.display);
    try std.testing.expectEqual(@as(usize, 0), first.events.items.len);

    var second = try parser.feed("gyzag:event:{\"type\":\"session");
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", second.display);
    try std.testing.expectEqual(@as(usize, 0), second.events.items.len);

    var third = try parser.feed(".ready\"}\x07b");
    defer third.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("b", third.display);
    try std.testing.expectEqual(@as(usize, 1), third.events.items.len);
    try std.testing.expectEqual(EventKind.session_ready, third.events.items[0].kind);
}

test "streaming parser discards oversized and malformed events" {
    var parser = Parser.initWithMaxPayloadLen(std.testing.allocator, 16);
    defer parser.deinit();

    var oversized = try parser.feed("a\x1b]777;ziggyzag:event:{\"type\":\"session.ready\"}\x07b");
    defer oversized.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ab", oversized.display);
    try std.testing.expectEqual(@as(usize, 0), oversized.events.items.len);

    var malformed = try parser.feed("c\x1b]777;ziggyzag:event:{\"status\":0}\x07d");
    defer malformed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cd", malformed.display);
    try std.testing.expectEqual(@as(usize, 0), malformed.events.items.len);

    var small_parser = Parser.initWithMaxPayloadLen(std.testing.allocator, 4);
    defer small_parser.deinit();

    var unterminated = try small_parser.feed("e\x1b]777;ziggyzag:event:123456");
    defer unterminated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("e", unterminated.display);
    try std.testing.expectEqual(@as(usize, 0), unterminated.events.items.len);

    var recovered = try small_parser.feed("f");
    defer recovered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("f", recovered.display);
    try std.testing.expectEqual(@as(usize, 0), recovered.events.items.len);
}

test "streaming parser keeps normal display bytes passing through" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();

    var first = try parser.feed("hello \x1b[31mred");
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello \x1b[31mred", first.display);
    try std.testing.expectEqual(@as(usize, 0), first.events.items.len);

    var second = try parser.feed(" world");
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(" world", second.display);
    try std.testing.expectEqual(@as(usize, 0), second.events.items.len);
}

test "reads simple JSON string values" {
    const payload = "{\"type\":\"prompt.rendered\",\"cwd\":\"C:/dev/ZiggyZag\"}";
    try std.testing.expectEqualStrings("prompt.rendered", jsonStringValue(payload, "type").?);
    try std.testing.expectEqualStrings("C:/dev/ZiggyZag", jsonStringValue(payload, "cwd").?);
    try std.testing.expect(jsonStringValue(payload, "missing") == null);
}

test "jsonUnescapeInto unescapes Windows backslashes in cwd" {
    // The shell emits Windows paths as JSON-escaped backslashes: C:\\Users\\foo
    // jsonStringValue returns the raw JSON body (with \\); jsonUnescapeInto
    // must convert each \\ pair back to a single backslash.
    const raw = "C:\\\\Users\\\\pasca\\\\dev\\\\ZiggyZag";
    var dest: [260]u8 = undefined;
    const len = jsonUnescapeInto(&dest, raw);
    try std.testing.expectEqualStrings("C:\\Users\\pasca\\dev\\ZiggyZag", dest[0..len]);
}

test "jsonUnescapeInto handles all common escapes" {
    var dest: [64]u8 = undefined;
    const len = jsonUnescapeInto(&dest, "tab\\there\\nnewline\\r\\\"quote\\\\slash");
    try std.testing.expectEqualStrings("tab\there\nnewline\r\"quote\\slash", dest[0..len]);
}

test "jsonUnescapeInto round-trips a prompt.rendered cwd from Windows" {
    // Simulate the full path from the shell: appendJsonString encodes
    // C:\Users\pasca\dev\ZiggyZag as "C:\\Users\\pasca\\dev\\ZiggyZag" in JSON.
    // jsonStringValue returns the body between quotes: C:\\Users\\pasca\\dev\\ZiggyZag
    // jsonUnescapeInto must yield the original path.
    const payload = "{\"type\":\"prompt.rendered\",\"cwd\":\"C:\\\\Users\\\\pasca\\\\dev\\\\ZiggyZag\"}";
    const raw_cwd = jsonStringValue(payload, "cwd").?;
    // raw_cwd is C:\\Users\\pasca\\dev\\ZiggyZag (doubled backslashes — raw JSON)
    var dest: [260]u8 = undefined;
    const len = jsonUnescapeInto(&dest, raw_cwd);
    try std.testing.expectEqualStrings("C:\\Users\\pasca\\dev\\ZiggyZag", dest[0..len]);
}

test "reads simple JSON integer values" {
    const payload = "{\"type\":\"command.finished\",\"status\":7,\"duration_ms\":42}";
    try std.testing.expectEqual(@as(u8, 7), jsonIntValue(u8, payload, "status").?);
    try std.testing.expectEqual(@as(i64, 42), jsonIntValue(i64, payload, "duration_ms").?);
    try std.testing.expect(jsonIntValue(u8, payload, "missing") == null);
}
