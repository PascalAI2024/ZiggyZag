const std = @import("std");

const Allocator = std.mem.Allocator;
const prefix = "\x1b]777;ziggyzag:event:";
const bel: u8 = 0x07;

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
    var display: std.ArrayList(u8) = .empty;
    errdefer display.deinit(allocator);

    var events: std.ArrayList(Event) = .empty;
    errdefer {
        for (events.items) |event| event.deinit(allocator);
        events.deinit(allocator);
    }

    var index: usize = 0;
    while (index < bytes.len) {
        if (std.mem.startsWith(u8, bytes[index..], prefix)) {
            const payload_start = index + prefix.len;
            const payload_end_offset = std.mem.indexOfScalar(u8, bytes[payload_start..], bel);
            if (payload_end_offset) |offset| {
                const payload = bytes[payload_start .. payload_start + offset];
                try events.append(allocator, .{
                    .kind = eventKind(payload),
                    .payload = try allocator.dupe(u8, payload),
                });
                index = payload_start + offset + 1;
                continue;
            }
        }

        try display.append(allocator, bytes[index]);
        index += 1;
    }

    return .{
        .display = try display.toOwnedSlice(allocator),
        .events = events,
    };
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

test "reads simple JSON string values" {
    const payload = "{\"type\":\"prompt.rendered\",\"cwd\":\"C:/dev/ZiggyZag\"}";
    try std.testing.expectEqualStrings("prompt.rendered", jsonStringValue(payload, "type").?);
    try std.testing.expectEqualStrings("C:/dev/ZiggyZag", jsonStringValue(payload, "cwd").?);
    try std.testing.expect(jsonStringValue(payload, "missing") == null);
}

test "reads simple JSON integer values" {
    const payload = "{\"type\":\"command.finished\",\"status\":7,\"duration_ms\":42}";
    try std.testing.expectEqual(@as(u8, 7), jsonIntValue(u8, payload, "status").?);
    try std.testing.expectEqual(@as(i64, 42), jsonIntValue(i64, payload, "duration_ms").?);
    try std.testing.expect(jsonIntValue(u8, payload, "missing") == null);
}
