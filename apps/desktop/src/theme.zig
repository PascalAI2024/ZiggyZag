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
    id: []const u8,
    name: []const u8,
    background: Color,
    foreground: Color,
    cursor: Color,
    accent: Color,
    panel: Color,
    muted: Color,
    ansi: [16]Color,

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

    pub fn withPanel(self: Theme, panel: Color) Theme {
        var copy = self;
        copy.panel = panel;
        return copy;
    }

    pub fn withMuted(self: Theme, muted: Color) Theme {
        var copy = self;
        copy.muted = muted;
        return copy;
    }
};

pub const ziggy = Theme{
    .id = "ziggy",
    .name = "Ziggy",
    .background = Color.rgb(0x11, 0x13, 0x15),
    .foreground = Color.rgb(0xee, 0xf2, 0xe2),
    .cursor = Color.rgb(0xb6, 0xf0, 0x9c),
    .accent = Color.rgb(0x9b, 0xe2, 0x8f),
    .panel = Color.rgb(0x19, 0x1c, 0x1d),
    .muted = Color.rgb(0x6a, 0x70, 0x72),
    .ansi = .{
        Color.rgb(0x1d, 0x20, 0x21),
        Color.rgb(0xe6, 0x6a, 0x6a),
        Color.rgb(0x9b, 0xe2, 0x8f),
        Color.rgb(0xf2, 0xcd, 0x76),
        Color.rgb(0x7a, 0xb7, 0xff),
        Color.rgb(0xcf, 0x9b, 0xff),
        Color.rgb(0x73, 0xd7, 0xd7),
        Color.rgb(0xee, 0xf2, 0xe2),
        Color.rgb(0x6a, 0x70, 0x72),
        Color.rgb(0xff, 0x8a, 0x8a),
        Color.rgb(0xba, 0xf5, 0xa9),
        Color.rgb(0xff, 0xdf, 0x8a),
        Color.rgb(0x9d, 0xcb, 0xff),
        Color.rgb(0xdf, 0xb6, 0xff),
        Color.rgb(0x91, 0xef, 0xef),
        Color.rgb(0xff, 0xfd, 0xf2),
    },
};

pub const catppuccin_mocha = Theme{
    .id = "catppuccin-mocha",
    .name = "Catppuccin Mocha",
    .background = Color.rgb(0x1e, 0x1e, 0x2e),
    .foreground = Color.rgb(0xcd, 0xd6, 0xf4),
    .cursor = Color.rgb(0xf5, 0xe0, 0xdc),
    .accent = Color.rgb(0x89, 0xb4, 0xfa),
    .panel = Color.rgb(0x18, 0x18, 0x25),
    .muted = Color.rgb(0xa6, 0xad, 0xc8),
    .ansi = .{
        Color.rgb(0x45, 0x47, 0x5a),
        Color.rgb(0xf3, 0x8b, 0xa8),
        Color.rgb(0xa6, 0xe3, 0xa1),
        Color.rgb(0xf9, 0xe2, 0xaf),
        Color.rgb(0x89, 0xb4, 0xfa),
        Color.rgb(0xf5, 0xc2, 0xe7),
        Color.rgb(0x94, 0xe2, 0xd5),
        Color.rgb(0xba, 0xc2, 0xde),
        Color.rgb(0x58, 0x5b, 0x70),
        Color.rgb(0xf3, 0x8b, 0xa8),
        Color.rgb(0xa6, 0xe3, 0xa1),
        Color.rgb(0xf9, 0xe2, 0xaf),
        Color.rgb(0x89, 0xb4, 0xfa),
        Color.rgb(0xf5, 0xc2, 0xe7),
        Color.rgb(0x94, 0xe2, 0xd5),
        Color.rgb(0xa6, 0xad, 0xc8),
    },
};

pub const tokyo_night = Theme{
    .id = "tokyo-night",
    .name = "Tokyo Night",
    .background = Color.rgb(0x1a, 0x1b, 0x26),
    .foreground = Color.rgb(0xc0, 0xca, 0xf5),
    .cursor = Color.rgb(0xc0, 0xca, 0xf5),
    .accent = Color.rgb(0x7a, 0xa2, 0xf7),
    .panel = Color.rgb(0x16, 0x16, 0x1e),
    .muted = Color.rgb(0xa9, 0xb1, 0xd6),
    .ansi = .{
        Color.rgb(0x15, 0x16, 0x1e),
        Color.rgb(0xf7, 0x76, 0x8e),
        Color.rgb(0x9e, 0xce, 0x6a),
        Color.rgb(0xe0, 0xaf, 0x68),
        Color.rgb(0x7a, 0xa2, 0xf7),
        Color.rgb(0xbb, 0x9a, 0xf7),
        Color.rgb(0x7d, 0xcf, 0xff),
        Color.rgb(0xa9, 0xb1, 0xd6),
        Color.rgb(0x41, 0x48, 0x68),
        Color.rgb(0xf7, 0x76, 0x8e),
        Color.rgb(0x9e, 0xce, 0x6a),
        Color.rgb(0xe0, 0xaf, 0x68),
        Color.rgb(0x7a, 0xa2, 0xf7),
        Color.rgb(0xbb, 0x9a, 0xf7),
        Color.rgb(0x7d, 0xcf, 0xff),
        Color.rgb(0xc0, 0xca, 0xf5),
    },
};

pub const dracula = Theme{
    .id = "dracula",
    .name = "Dracula",
    .background = Color.rgb(0x28, 0x2a, 0x36),
    .foreground = Color.rgb(0xf8, 0xf8, 0xf2),
    .cursor = Color.rgb(0xf8, 0xf8, 0xf2),
    .accent = Color.rgb(0xbd, 0x93, 0xf9),
    .panel = Color.rgb(0x21, 0x22, 0x2c),
    .muted = Color.rgb(0x62, 0x72, 0xa4),
    .ansi = .{
        Color.rgb(0x21, 0x22, 0x2c),
        Color.rgb(0xff, 0x55, 0x55),
        Color.rgb(0x50, 0xfa, 0x7b),
        Color.rgb(0xf1, 0xfa, 0x8c),
        Color.rgb(0xbd, 0x93, 0xf9),
        Color.rgb(0xff, 0x79, 0xc6),
        Color.rgb(0x8b, 0xe9, 0xfd),
        Color.rgb(0xf8, 0xf8, 0xf2),
        Color.rgb(0x62, 0x72, 0xa4),
        Color.rgb(0xff, 0x6e, 0x6e),
        Color.rgb(0x69, 0xff, 0x94),
        Color.rgb(0xff, 0xff, 0xa5),
        Color.rgb(0xd6, 0xac, 0xff),
        Color.rgb(0xff, 0x92, 0xdf),
        Color.rgb(0xa4, 0xff, 0xff),
        Color.rgb(0xff, 0xff, 0xff),
    },
};

pub const nord = Theme{
    .id = "nord",
    .name = "Nord",
    .background = Color.rgb(0x2e, 0x34, 0x40),
    .foreground = Color.rgb(0xd8, 0xde, 0xe9),
    .cursor = Color.rgb(0xd8, 0xde, 0xe9),
    .accent = Color.rgb(0x88, 0xc0, 0xd0),
    .panel = Color.rgb(0x3b, 0x42, 0x52),
    .muted = Color.rgb(0x81, 0xa1, 0xc1),
    .ansi = .{
        Color.rgb(0x3b, 0x42, 0x52),
        Color.rgb(0xbf, 0x61, 0x6a),
        Color.rgb(0xa3, 0xbe, 0x8c),
        Color.rgb(0xeb, 0xcb, 0x8b),
        Color.rgb(0x81, 0xa1, 0xc1),
        Color.rgb(0xb4, 0x8e, 0xad),
        Color.rgb(0x88, 0xc0, 0xd0),
        Color.rgb(0xe5, 0xe9, 0xf0),
        Color.rgb(0x4c, 0x56, 0x6a),
        Color.rgb(0xbf, 0x61, 0x6a),
        Color.rgb(0xa3, 0xbe, 0x8c),
        Color.rgb(0xeb, 0xcb, 0x8b),
        Color.rgb(0x81, 0xa1, 0xc1),
        Color.rgb(0xb4, 0x8e, 0xad),
        Color.rgb(0x8f, 0xbc, 0xbb),
        Color.rgb(0xec, 0xef, 0xf4),
    },
};

pub const rose_pine = Theme{
    .id = "rose-pine",
    .name = "Rose Pine",
    .background = Color.rgb(0x19, 0x17, 0x24),
    .foreground = Color.rgb(0xe0, 0xde, 0xf4),
    .cursor = Color.rgb(0xe0, 0xde, 0xf4),
    .accent = Color.rgb(0xc4, 0xa7, 0xe7),
    .panel = Color.rgb(0x1f, 0x1d, 0x2e),
    .muted = Color.rgb(0x90, 0x8c, 0xaa),
    .ansi = .{
        Color.rgb(0x26, 0x23, 0x3a),
        Color.rgb(0xeb, 0x6f, 0x92),
        Color.rgb(0x31, 0x74, 0x8f),
        Color.rgb(0xf6, 0xc1, 0x77),
        Color.rgb(0x9c, 0xcf, 0xd8),
        Color.rgb(0xc4, 0xa7, 0xe7),
        Color.rgb(0xeb, 0xbc, 0xba),
        Color.rgb(0xe0, 0xde, 0xf4),
        Color.rgb(0x6e, 0x6a, 0x86),
        Color.rgb(0xeb, 0x6f, 0x92),
        Color.rgb(0x31, 0x74, 0x8f),
        Color.rgb(0xf6, 0xc1, 0x77),
        Color.rgb(0x9c, 0xcf, 0xd8),
        Color.rgb(0xc4, 0xa7, 0xe7),
        Color.rgb(0xeb, 0xbc, 0xba),
        Color.rgb(0xe0, 0xde, 0xf4),
    },
};

pub const gruvbox_dark = Theme{
    .id = "gruvbox-dark",
    .name = "Gruvbox Dark",
    .background = Color.rgb(0x28, 0x28, 0x28),
    .foreground = Color.rgb(0xeb, 0xdb, 0xb2),
    .cursor = Color.rgb(0xeb, 0xdb, 0xb2),
    .accent = Color.rgb(0xfe, 0x80, 0x19),
    .panel = Color.rgb(0x3c, 0x38, 0x36),
    .muted = Color.rgb(0x92, 0x83, 0x74),
    .ansi = .{
        Color.rgb(0x28, 0x28, 0x28),
        Color.rgb(0xcc, 0x24, 0x1d),
        Color.rgb(0x98, 0x97, 0x1a),
        Color.rgb(0xd7, 0x99, 0x21),
        Color.rgb(0x45, 0x85, 0x88),
        Color.rgb(0xb1, 0x62, 0x86),
        Color.rgb(0x68, 0x9d, 0x6a),
        Color.rgb(0xa8, 0x99, 0x84),
        Color.rgb(0x92, 0x83, 0x74),
        Color.rgb(0xfb, 0x49, 0x34),
        Color.rgb(0xb8, 0xbb, 0x26),
        Color.rgb(0xfa, 0xbd, 0x2f),
        Color.rgb(0x83, 0xa5, 0x98),
        Color.rgb(0xd3, 0x86, 0x9b),
        Color.rgb(0x8e, 0xc0, 0x7c),
        Color.rgb(0xeb, 0xdb, 0xb2),
    },
};

pub const everforest_dark = Theme{
    .id = "everforest-dark",
    .name = "Everforest Dark",
    .background = Color.rgb(0x2b, 0x33, 0x39),
    .foreground = Color.rgb(0xd3, 0xc6, 0xaa),
    .cursor = Color.rgb(0xd3, 0xc6, 0xaa),
    .accent = Color.rgb(0xa7, 0xc0, 0x80),
    .panel = Color.rgb(0x32, 0x3c, 0x41),
    .muted = Color.rgb(0x9d, 0xa9, 0xa0),
    .ansi = .{
        Color.rgb(0x3a, 0x45, 0x4a),
        Color.rgb(0xe6, 0x7e, 0x80),
        Color.rgb(0xa7, 0xc0, 0x80),
        Color.rgb(0xdb, 0xbc, 0x7f),
        Color.rgb(0x7f, 0xbb, 0xb3),
        Color.rgb(0xd6, 0x99, 0xb6),
        Color.rgb(0x83, 0xc0, 0x92),
        Color.rgb(0xd3, 0xc6, 0xaa),
        Color.rgb(0x7a, 0x84, 0x78),
        Color.rgb(0xe6, 0x7e, 0x80),
        Color.rgb(0xa7, 0xc0, 0x80),
        Color.rgb(0xdb, 0xbc, 0x7f),
        Color.rgb(0x7f, 0xbb, 0xb3),
        Color.rgb(0xd6, 0x99, 0xb6),
        Color.rgb(0x83, 0xc0, 0x92),
        Color.rgb(0xff, 0xfb, 0xef),
    },
};

pub const kanagawa_wave = Theme{
    .id = "kanagawa-wave",
    .name = "Kanagawa Wave",
    .background = Color.rgb(0x1f, 0x1f, 0x28),
    .foreground = Color.rgb(0xdc, 0xd7, 0xba),
    .cursor = Color.rgb(0xc8, 0xc0, 0x93),
    .accent = Color.rgb(0x7e, 0x9c, 0xd8),
    .panel = Color.rgb(0x2a, 0x2a, 0x37),
    .muted = Color.rgb(0x72, 0x71, 0x69),
    .ansi = .{
        Color.rgb(0x09, 0x06, 0x18),
        Color.rgb(0xc3, 0x40, 0x43),
        Color.rgb(0x76, 0x94, 0x6a),
        Color.rgb(0xc0, 0xa3, 0x6e),
        Color.rgb(0x7e, 0x9c, 0xd8),
        Color.rgb(0x95, 0x7f, 0xb8),
        Color.rgb(0x6a, 0x95, 0x89),
        Color.rgb(0xc8, 0xc0, 0x93),
        Color.rgb(0x72, 0x71, 0x69),
        Color.rgb(0xe8, 0x24, 0x24),
        Color.rgb(0x98, 0xbb, 0x6c),
        Color.rgb(0xe6, 0xc3, 0x84),
        Color.rgb(0x7f, 0xb4, 0xca),
        Color.rgb(0x93, 0x8a, 0xa9),
        Color.rgb(0x7a, 0xa8, 0x9f),
        Color.rgb(0xdc, 0xd7, 0xba),
    },
};

pub const solarized_dark = Theme{
    .id = "solarized-dark",
    .name = "Solarized Dark",
    .background = Color.rgb(0x00, 0x2b, 0x36),
    .foreground = Color.rgb(0x83, 0x94, 0x96),
    .cursor = Color.rgb(0x93, 0xa1, 0xa1),
    .accent = Color.rgb(0x26, 0x8b, 0xd2),
    .panel = Color.rgb(0x07, 0x36, 0x42),
    .muted = Color.rgb(0x58, 0x6e, 0x75),
    .ansi = .{
        Color.rgb(0x07, 0x36, 0x42),
        Color.rgb(0xdc, 0x32, 0x2f),
        Color.rgb(0x85, 0x99, 0x00),
        Color.rgb(0xb5, 0x89, 0x00),
        Color.rgb(0x26, 0x8b, 0xd2),
        Color.rgb(0xd3, 0x36, 0x82),
        Color.rgb(0x2a, 0xa1, 0x98),
        Color.rgb(0xee, 0xe8, 0xd5),
        Color.rgb(0x00, 0x2b, 0x36),
        Color.rgb(0xcb, 0x4b, 0x16),
        Color.rgb(0x58, 0x6e, 0x75),
        Color.rgb(0x65, 0x7b, 0x83),
        Color.rgb(0x83, 0x94, 0x96),
        Color.rgb(0x6c, 0x71, 0xc4),
        Color.rgb(0x93, 0xa1, 0xa1),
        Color.rgb(0xfd, 0xf6, 0xe3),
    },
};

pub const one_dark = Theme{
    .id = "one-dark",
    .name = "One Dark",
    .background = Color.rgb(0x28, 0x2c, 0x34),
    .foreground = Color.rgb(0xab, 0xb2, 0xbf),
    .cursor = Color.rgb(0x52, 0x8b, 0xff),
    .accent = Color.rgb(0x61, 0xaf, 0xef),
    .panel = Color.rgb(0x21, 0x25, 0x2b),
    .muted = Color.rgb(0x5c, 0x63, 0x70),
    .ansi = .{
        Color.rgb(0x28, 0x2c, 0x34),
        Color.rgb(0xe0, 0x6c, 0x75),
        Color.rgb(0x98, 0xc3, 0x79),
        Color.rgb(0xe5, 0xc0, 0x7b),
        Color.rgb(0x61, 0xaf, 0xef),
        Color.rgb(0xc6, 0x78, 0xdd),
        Color.rgb(0x56, 0xb6, 0xc2),
        Color.rgb(0xab, 0xb2, 0xbf),
        Color.rgb(0x5c, 0x63, 0x70),
        Color.rgb(0xe0, 0x6c, 0x75),
        Color.rgb(0x98, 0xc3, 0x79),
        Color.rgb(0xe5, 0xc0, 0x7b),
        Color.rgb(0x61, 0xaf, 0xef),
        Color.rgb(0xc6, 0x78, 0xdd),
        Color.rgb(0x56, 0xb6, 0xc2),
        Color.rgb(0xff, 0xff, 0xff),
    },
};

pub const paper = Theme{
    .id = "paper",
    .name = "Paper",
    .background = Color.rgb(0xf8, 0xf6, 0xef),
    .foreground = Color.rgb(0x26, 0x29, 0x25),
    .cursor = Color.rgb(0x2f, 0x6f, 0x62),
    .accent = Color.rgb(0x2f, 0x6f, 0x62),
    .panel = Color.rgb(0xeb, 0xe7, 0xdc),
    .muted = Color.rgb(0x73, 0x77, 0x6d),
    .ansi = .{
        Color.rgb(0x26, 0x29, 0x25),
        Color.rgb(0xb9, 0x5c, 0x50),
        Color.rgb(0x2f, 0x6f, 0x62),
        Color.rgb(0x9a, 0x6b, 0x18),
        Color.rgb(0x2f, 0x5f, 0x9f),
        Color.rgb(0x8f, 0x5f, 0xbf),
        Color.rgb(0x2f, 0x7f, 0x8a),
        Color.rgb(0xf8, 0xf6, 0xef),
        Color.rgb(0x73, 0x77, 0x6d),
        Color.rgb(0xd2, 0x6b, 0x5f),
        Color.rgb(0x3d, 0x83, 0x73),
        Color.rgb(0xb0, 0x7a, 0x25),
        Color.rgb(0x42, 0x73, 0xb5),
        Color.rgb(0xa0, 0x72, 0xcb),
        Color.rgb(0x41, 0x91, 0x9c),
        Color.rgb(0xff, 0xfc, 0xf2),
    },
};

pub const ember = Theme{
    .id = "ember",
    .name = "Ember",
    .background = Color.rgb(0x18, 0x13, 0x10),
    .foreground = Color.rgb(0xf3, 0xe6, 0xd8),
    .cursor = Color.rgb(0xff, 0xb4, 0x54),
    .accent = Color.rgb(0xff, 0x8a, 0x3d),
    .panel = Color.rgb(0x21, 0x1a, 0x16),
    .muted = Color.rgb(0xaa, 0x8f, 0x7d),
    .ansi = .{
        Color.rgb(0x21, 0x1a, 0x16),
        Color.rgb(0xf2, 0x68, 0x5c),
        Color.rgb(0xb0, 0xc4, 0x77),
        Color.rgb(0xff, 0xb4, 0x54),
        Color.rgb(0x7f, 0xb4, 0xd8),
        Color.rgb(0xcf, 0x9b, 0xff),
        Color.rgb(0x73, 0xd7, 0xd7),
        Color.rgb(0xf3, 0xe6, 0xd8),
        Color.rgb(0xaa, 0x8f, 0x7d),
        Color.rgb(0xff, 0x7a, 0x6b),
        Color.rgb(0xc5, 0xd9, 0x8f),
        Color.rgb(0xff, 0xc8, 0x7a),
        Color.rgb(0x9d, 0xcb, 0xff),
        Color.rgb(0xdf, 0xb6, 0xff),
        Color.rgb(0x91, 0xef, 0xef),
        Color.rgb(0xff, 0xf4, 0xe8),
    },
};

pub const themes = [_]Theme{
    ziggy,
    catppuccin_mocha,
    tokyo_night,
    dracula,
    nord,
    rose_pine,
    gruvbox_dark,
    everforest_dark,
    kanagawa_wave,
    solarized_dark,
    one_dark,
    paper,
    ember,
};

pub fn maybeByName(name: []const u8) ?Theme {
    for (themes) |candidate| {
        if (themeNameMatches(name, candidate.id) or themeNameMatches(name, candidate.name)) return candidate;
    }
    return null;
}

pub fn byName(name: []const u8) Theme {
    if (maybeByName(name)) |selected| return selected;
    return ziggy;
}

pub fn next(current: Theme) Theme {
    for (themes, 0..) |candidate, index| {
        if (std.mem.eql(u8, current.id, candidate.id)) return themes[(index + 1) % themes.len];
    }
    return themes[0];
}

fn themeNameMatches(input: []const u8, candidate: []const u8) bool {
    var input_index: usize = 0;
    var candidate_index: usize = 0;
    while (true) {
        while (input_index < input.len and isThemeSeparator(input[input_index])) : (input_index += 1) {}
        while (candidate_index < candidate.len and isThemeSeparator(candidate[candidate_index])) : (candidate_index += 1) {}
        if (input_index >= input.len or candidate_index >= candidate.len) break;
        if (std.ascii.toLower(input[input_index]) != std.ascii.toLower(candidate[candidate_index])) return false;
        input_index += 1;
        candidate_index += 1;
    }
    while (input_index < input.len and isThemeSeparator(input[input_index])) : (input_index += 1) {}
    while (candidate_index < candidate.len and isThemeSeparator(candidate[candidate_index])) : (candidate_index += 1) {}
    return input_index == input.len and candidate_index == candidate.len;
}

fn isThemeSeparator(byte: u8) bool {
    return byte == ' ' or byte == '-' or byte == '_';
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
    try std.testing.expectEqualStrings("Catppuccin Mocha", byName("catppuccin-mocha").name);
    try std.testing.expectEqualStrings("Tokyo Night", byName("tokyo night").name);
    try std.testing.expectEqualStrings("Rose Pine", byName("rose_pine").name);
    try std.testing.expectEqualStrings("Ziggy", byName("unknown").name);
}

test "copies themes with overrides" {
    const themed = ziggy.withAccent(Color.rgb(1, 2, 3));
    try std.testing.expect(themed.accent.eql(Color.rgb(1, 2, 3)));
    try std.testing.expect(ziggy.accent.eql(Color.rgb(0x9b, 0xe2, 0x8f)));
}

test "cycles through known themes" {
    try std.testing.expectEqualStrings("Catppuccin Mocha", next(ziggy).name);
    try std.testing.expectEqualStrings("Ziggy", next(ember).name);
}
