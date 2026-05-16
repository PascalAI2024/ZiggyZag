const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn fromHex(hex: []const u8) error{InvalidHexColor}!Color {
        const value = if (hex.len == 7 and hex[0] == '#') hex[1..] else hex;
        if (value.len != 6) return error.InvalidHexColor;
        return .{
            .r = std.fmt.parseInt(u8, value[0..2], 16) catch return error.InvalidHexColor,
            .g = std.fmt.parseInt(u8, value[2..4], 16) catch return error.InvalidHexColor,
            .b = std.fmt.parseInt(u8, value[4..6], 16) catch return error.InvalidHexColor,
        };
    }

    pub fn format(
        self: Color,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b });
    }

    pub fn eql(self: Color, other: Color) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

pub const Theme = struct {
    name: []const u8,
    background: Color,
    foreground: Color,
    cursor: Color,
    accent: Color,

    pub fn withBackground(self: Theme, background: Color) Theme {
        var copy = self;
        copy.background = background;
        return copy;
    }

    pub fn withForeground(self: Theme, foreground: Color) Theme {
        var copy = self;
        copy.foreground = foreground;
        return copy;
    }

    pub fn withCursor(self: Theme, cursor: Color) Theme {
        var copy = self;
        copy.cursor = cursor;
        return copy;
    }

    pub fn withAccent(self: Theme, accent: Color) Theme {
        var copy = self;
        copy.accent = accent;
        return copy;
    }
};

pub const ziggy = Theme{
    .name = "Ziggy",
    .background = Color.rgb(0x11, 0x13, 0x15),
    .foreground = Color.rgb(0xee, 0xf2, 0xe2),
    .cursor = Color.rgb(0xb6, 0xf0, 0x9c),
    .accent = Color.rgb(0x9b, 0xe2, 0x8f),
};

pub const paper = Theme{
    .name = "Paper",
    .background = Color.rgb(0xf8, 0xf6, 0xef),
    .foreground = Color.rgb(0x26, 0x29, 0x25),
    .cursor = Color.rgb(0x2f, 0x6f, 0x62),
    .accent = Color.rgb(0x2f, 0x6f, 0x62),
};

pub const ember = Theme{
    .name = "Ember",
    .background = Color.rgb(0x18, 0x13, 0x10),
    .foreground = Color.rgb(0xf3, 0xe6, 0xd8),
    .cursor = Color.rgb(0xff, 0xb4, 0x54),
    .accent = Color.rgb(0xff, 0x8a, 0x3d),
};

pub const themes = [_]Theme{ ziggy, paper, ember };

pub fn maybeByName(name: []const u8) ?Theme {
    for (themes) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate.name)) return candidate;
    }
    return null;
}

pub fn byName(name: []const u8) Theme {
    if (maybeByName(name)) |selected| return selected;
    return ziggy;
}

test "parses hex colors" {
    const color = try Color.fromHex("#9be28f");
    try std.testing.expectEqual(@as(u8, 0x9b), color.r);
    try std.testing.expectEqual(@as(u8, 0xe2), color.g);
    try std.testing.expectEqual(@as(u8, 0x8f), color.b);
}

test "selects themes by name" {
    try std.testing.expectEqualStrings("Paper", byName("paper").name);
    try std.testing.expectEqualStrings("Ember", byName("EMBER").name);
    try std.testing.expectEqualStrings("Ziggy", byName("unknown").name);
}

test "copies themes with overrides" {
    const themed = ziggy.withAccent(Color.rgb(1, 2, 3));
    try std.testing.expect(themed.accent.eql(Color.rgb(1, 2, 3)));
    try std.testing.expect(ziggy.accent.eql(Color.rgb(0x9b, 0xe2, 0x8f)));
}
