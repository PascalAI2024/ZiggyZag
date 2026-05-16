const std = @import("std");
const theme = @import("theme.zig");

pub const Font = struct {
    family: []const u8 = "Cascadia Mono",
    size: u8 = 14,
};

pub const Options = struct {
    show_status_bar: bool = true,
    smooth_scroll: bool = true,
    bell: bool = false,
};

pub const Config = struct {
    selected_theme: theme.Theme = theme.ziggy,
    font: Font = .{},
    options: Options = .{},

    pub fn defaults() Config {
        return .{};
    }
};

pub const ParseError = error{
    MissingEquals,
    MissingKey,
    UnknownKey,
    UnknownTheme,
    InvalidBoolean,
    InvalidFontSize,
    InvalidHexColor,
    InvalidInteger,
};

pub fn parse(contents: []const u8) ParseError!Config {
    var config = Config.defaults();
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const equals_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.MissingEquals;
        const key = std.mem.trim(u8, line[0..equals_index], " \t");
        const value = unquote(std.mem.trim(u8, line[equals_index + 1 ..], " \t"));
        if (key.len == 0) return error.MissingKey;

        try apply(&config, key, value);
    }
    return config;
}

fn apply(config: *Config, key: []const u8, value: []const u8) ParseError!void {
    if (std.ascii.eqlIgnoreCase(key, "theme")) {
        config.selected_theme = theme.maybeByName(value) orelse return error.UnknownTheme;
    } else if (std.ascii.eqlIgnoreCase(key, "theme.background")) {
        config.selected_theme = config.selected_theme.withBackground(try theme.Color.fromHex(value));
    } else if (std.ascii.eqlIgnoreCase(key, "theme.foreground")) {
        config.selected_theme = config.selected_theme.withForeground(try theme.Color.fromHex(value));
    } else if (std.ascii.eqlIgnoreCase(key, "theme.cursor")) {
        config.selected_theme = config.selected_theme.withCursor(try theme.Color.fromHex(value));
    } else if (std.ascii.eqlIgnoreCase(key, "theme.accent")) {
        config.selected_theme = config.selected_theme.withAccent(try theme.Color.fromHex(value));
    } else if (std.ascii.eqlIgnoreCase(key, "font.family")) {
        config.font.family = value;
    } else if (std.ascii.eqlIgnoreCase(key, "font.size")) {
        const size = std.fmt.parseInt(u8, value, 10) catch return error.InvalidFontSize;
        if (size < 6 or size > 72) return error.InvalidFontSize;
        config.font.size = size;
    } else if (std.ascii.eqlIgnoreCase(key, "show_status_bar")) {
        config.options.show_status_bar = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "smooth_scroll")) {
        config.options.smooth_scroll = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "bell")) {
        config.options.bell = try parseBool(value);
    } else {
        return error.UnknownKey;
    }
}

fn parseBool(value: []const u8) ParseError!bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or
        std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(value, "false") or
        std.mem.eql(u8, value, "0") or
        std.ascii.eqlIgnoreCase(value, "no") or
        std.ascii.eqlIgnoreCase(value, "off"))
    {
        return false;
    }
    return error.InvalidBoolean;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and
        ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        return value[1 .. value.len - 1];
    }
    return value;
}

test "defaults select ziggy theme and desktop font" {
    const config = Config.defaults();
    try std.testing.expectEqualStrings("Ziggy", config.selected_theme.name);
    try std.testing.expectEqualStrings("Cascadia Mono", config.font.family);
    try std.testing.expectEqual(@as(u8, 14), config.font.size);
    try std.testing.expect(config.options.show_status_bar);
}

test "parses key value desktop config" {
    const parsed = try parse(
        \\# ZiggyZag Desktop
        \\theme = paper
        \\font.family = "JetBrains Mono"
        \\font.size = 16
        \\show_status_bar = off
        \\smooth_scroll = yes
        \\bell = true
        \\
    );

    try std.testing.expectEqualStrings("Paper", parsed.selected_theme.name);
    try std.testing.expectEqualStrings("JetBrains Mono", parsed.font.family);
    try std.testing.expectEqual(@as(u8, 16), parsed.font.size);
    try std.testing.expect(!parsed.options.show_status_bar);
    try std.testing.expect(parsed.options.smooth_scroll);
    try std.testing.expect(parsed.options.bell);
}

test "parses theme color overrides" {
    const parsed = try parse(
        \\theme = ember
        \\theme.background = #010203
        \\theme.foreground = 0a0b0c
        \\theme.cursor = #111213
        \\theme.accent = #212223
    );

    try std.testing.expectEqualStrings("Ember", parsed.selected_theme.name);
    try std.testing.expect(parsed.selected_theme.background.eql(theme.Color.rgb(1, 2, 3)));
    try std.testing.expect(parsed.selected_theme.foreground.eql(theme.Color.rgb(0x0a, 0x0b, 0x0c)));
    try std.testing.expect(parsed.selected_theme.cursor.eql(theme.Color.rgb(0x11, 0x12, 0x13)));
    try std.testing.expect(parsed.selected_theme.accent.eql(theme.Color.rgb(0x21, 0x22, 0x23)));
}

test "rejects unknown keys and invalid values" {
    try std.testing.expectError(error.UnknownKey, parse("window.opacity=90\n"));
    try std.testing.expectError(error.UnknownTheme, parse("theme=neon\n"));
    try std.testing.expectError(error.InvalidFontSize, parse("font.size=3\n"));
    try std.testing.expectError(error.InvalidBoolean, parse("bell=maybe\n"));
}
