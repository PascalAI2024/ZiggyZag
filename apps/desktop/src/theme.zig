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

// Additional dark variants for breadth. Four palettes from upstream
// projects, transcribed from their official specs. See:
//   https://github.com/catppuccin/palette (Frappé, Macchiato)
//   https://github.com/folke/tokyonight.nvim (Storm)
//   https://github.com/ayu-theme/ayu-colors (Dark)

// Catppuccin Frappé: hex values from catppuccin/palette palette.json (Frappé flavor).
// ANSI mapping mirrors catppuccin_mocha: Surface1/Surface2 for blacks, Subtext1/Subtext0 for whites.
pub const catppuccin_frappe = Theme{
    .id = "catppuccin-frappe",
    .name = "Catppuccin Frappé",
    .background = Color.rgb(0x30, 0x34, 0x46),
    .foreground = Color.rgb(0xc6, 0xd0, 0xf5),
    .cursor = Color.rgb(0xf2, 0xd5, 0xcf),
    .accent = Color.rgb(0x8c, 0xaa, 0xee),
    .panel = Color.rgb(0x29, 0x2c, 0x3c),
    .muted = Color.rgb(0xb5, 0xbf, 0xe2),
    .ansi = .{
        Color.rgb(0x51, 0x57, 0x6d),
        Color.rgb(0xe7, 0x82, 0x84),
        Color.rgb(0xa6, 0xd1, 0x89),
        Color.rgb(0xe5, 0xc8, 0x90),
        Color.rgb(0x8c, 0xaa, 0xee),
        Color.rgb(0xf4, 0xb8, 0xe4),
        Color.rgb(0x81, 0xc8, 0xbe),
        Color.rgb(0xb5, 0xbf, 0xe2),
        Color.rgb(0x62, 0x68, 0x80),
        Color.rgb(0xe7, 0x82, 0x84),
        Color.rgb(0xa6, 0xd1, 0x89),
        Color.rgb(0xe5, 0xc8, 0x90),
        Color.rgb(0x8c, 0xaa, 0xee),
        Color.rgb(0xf4, 0xb8, 0xe4),
        Color.rgb(0x81, 0xc8, 0xbe),
        Color.rgb(0xa5, 0xad, 0xce),
    },
};

// Catppuccin Macchiato: hex values from catppuccin/palette palette.json (Macchiato flavor).
// Same ANSI mapping convention as Frappé/Mocha.
pub const catppuccin_macchiato = Theme{
    .id = "catppuccin-macchiato",
    .name = "Catppuccin Macchiato",
    .background = Color.rgb(0x24, 0x27, 0x3a),
    .foreground = Color.rgb(0xca, 0xd3, 0xf5),
    .cursor = Color.rgb(0xf4, 0xdb, 0xd6),
    .accent = Color.rgb(0x8a, 0xad, 0xf4),
    .panel = Color.rgb(0x1e, 0x20, 0x30),
    .muted = Color.rgb(0xb8, 0xc0, 0xe0),
    .ansi = .{
        Color.rgb(0x49, 0x4d, 0x64),
        Color.rgb(0xed, 0x87, 0x96),
        Color.rgb(0xa6, 0xda, 0x95),
        Color.rgb(0xee, 0xd4, 0x9f),
        Color.rgb(0x8a, 0xad, 0xf4),
        Color.rgb(0xf5, 0xbd, 0xe6),
        Color.rgb(0x8b, 0xd5, 0xca),
        Color.rgb(0xb8, 0xc0, 0xe0),
        Color.rgb(0x5b, 0x60, 0x78),
        Color.rgb(0xed, 0x87, 0x96),
        Color.rgb(0xa6, 0xda, 0x95),
        Color.rgb(0xee, 0xd4, 0x9f),
        Color.rgb(0x8a, 0xad, 0xf4),
        Color.rgb(0xf5, 0xbd, 0xe6),
        Color.rgb(0x8b, 0xd5, 0xca),
        Color.rgb(0xa5, 0xad, 0xcb),
    },
};

// Tokyo Night Storm: hex values from folke/tokyonight.nvim
// (extras/lua/tokyonight_storm.lua) terminal palette.
pub const tokyo_night_storm = Theme{
    .id = "tokyo-night-storm",
    .name = "Tokyo Night Storm",
    .background = Color.rgb(0x24, 0x28, 0x3b),
    .foreground = Color.rgb(0xc0, 0xca, 0xf5),
    .cursor = Color.rgb(0xc0, 0xca, 0xf5),
    .accent = Color.rgb(0x7a, 0xa2, 0xf7),
    .panel = Color.rgb(0x1f, 0x23, 0x35),
    .muted = Color.rgb(0x9a, 0xa5, 0xce),
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

// Ayu Dark: surfaces/foreground/accent from ayu-theme/ayu-colors,
// ANSI 0-15 from alacritty/alacritty-theme/ayu_dark.toml.
pub const ayu_dark = Theme{
    .id = "ayu-dark",
    .name = "Ayu Dark",
    .background = Color.rgb(0x0b, 0x0e, 0x14),
    .foreground = Color.rgb(0xbf, 0xbd, 0xb6),
    .cursor = Color.rgb(0xe6, 0xb4, 0x50),
    .accent = Color.rgb(0xe6, 0xb4, 0x50),
    .panel = Color.rgb(0x11, 0x15, 0x1c),
    .muted = Color.rgb(0x56, 0x5b, 0x66),
    .ansi = .{
        Color.rgb(0x11, 0x15, 0x1c),
        Color.rgb(0xea, 0x6c, 0x73),
        Color.rgb(0x7f, 0xd9, 0x62),
        Color.rgb(0xf9, 0xaf, 0x4f),
        Color.rgb(0x53, 0xbd, 0xfa),
        Color.rgb(0xcd, 0xa1, 0xfa),
        Color.rgb(0x90, 0xe1, 0xc6),
        Color.rgb(0xc7, 0xc7, 0xc7),
        Color.rgb(0x68, 0x68, 0x68),
        Color.rgb(0xf0, 0x71, 0x78),
        Color.rgb(0xaa, 0xd9, 0x4c),
        Color.rgb(0xff, 0xb4, 0x54),
        Color.rgb(0x59, 0xc2, 0xff),
        Color.rgb(0xd2, 0xa6, 0xff),
        Color.rgb(0x95, 0xe6, 0xcb),
        Color.rgb(0xff, 0xff, 0xff),
    },
};

// Light-mode complements. Hex values from each project's official spec.
//   https://github.com/catppuccin/catppuccin (Latte)
//   https://github.com/altercation/solarized
//   https://primer.style/foundations/color/light

pub const catppuccin_latte = Theme{
    .id = "catppuccin-latte",
    .name = "Catppuccin Latte",
    .background = Color.rgb(0xef, 0xf1, 0xf5),
    .foreground = Color.rgb(0x4c, 0x4f, 0x69),
    .cursor = Color.rgb(0xdc, 0x8a, 0x78),
    .accent = Color.rgb(0x1e, 0x66, 0xf5),
    .panel = Color.rgb(0xe6, 0xe9, 0xef),
    .muted = Color.rgb(0x6c, 0x6f, 0x85),
    .ansi = .{
        Color.rgb(0x5c, 0x5f, 0x77),
        Color.rgb(0xd2, 0x0f, 0x39),
        Color.rgb(0x40, 0xa0, 0x2b),
        Color.rgb(0xdf, 0x8e, 0x1d),
        Color.rgb(0x1e, 0x66, 0xf5),
        Color.rgb(0xea, 0x76, 0xcb),
        Color.rgb(0x17, 0x92, 0x99),
        Color.rgb(0xac, 0xb0, 0xbe),
        Color.rgb(0x6c, 0x6f, 0x85),
        Color.rgb(0xd2, 0x0f, 0x39),
        Color.rgb(0x40, 0xa0, 0x2b),
        Color.rgb(0xdf, 0x8e, 0x1d),
        Color.rgb(0x1e, 0x66, 0xf5),
        Color.rgb(0xea, 0x76, 0xcb),
        Color.rgb(0x17, 0x92, 0x99),
        Color.rgb(0xbc, 0xc0, 0xcc),
    },
};

pub const solarized_light = Theme{
    .id = "solarized-light",
    .name = "Solarized Light",
    .background = Color.rgb(0xfd, 0xf6, 0xe3),
    .foreground = Color.rgb(0x65, 0x7b, 0x83),
    .cursor = Color.rgb(0x58, 0x6e, 0x75),
    .accent = Color.rgb(0x26, 0x8b, 0xd2),
    .panel = Color.rgb(0xee, 0xe8, 0xd5),
    .muted = Color.rgb(0x93, 0xa1, 0xa1),
    .ansi = .{
        Color.rgb(0xee, 0xe8, 0xd5),
        Color.rgb(0xdc, 0x32, 0x2f),
        Color.rgb(0x85, 0x99, 0x00),
        Color.rgb(0xb5, 0x89, 0x00),
        Color.rgb(0x26, 0x8b, 0xd2),
        Color.rgb(0xd3, 0x36, 0x82),
        Color.rgb(0x2a, 0xa1, 0x98),
        Color.rgb(0x07, 0x36, 0x42),
        Color.rgb(0xfd, 0xf6, 0xe3),
        Color.rgb(0xcb, 0x4b, 0x16),
        Color.rgb(0x58, 0x6e, 0x75),
        Color.rgb(0x65, 0x7b, 0x83),
        Color.rgb(0x83, 0x94, 0x96),
        Color.rgb(0x6c, 0x71, 0xc4),
        Color.rgb(0x93, 0xa1, 0xa1),
        Color.rgb(0x00, 0x2b, 0x36),
    },
};

pub const github_light = Theme{
    .id = "github-light",
    .name = "GitHub Light",
    .background = Color.rgb(0xff, 0xff, 0xff),
    .foreground = Color.rgb(0x24, 0x29, 0x2e),
    .cursor = Color.rgb(0x04, 0x42, 0x89),
    .accent = Color.rgb(0x03, 0x66, 0xd6),
    .panel = Color.rgb(0xf6, 0xf8, 0xfa),
    .muted = Color.rgb(0x6a, 0x73, 0x7d),
    .ansi = .{
        Color.rgb(0x24, 0x29, 0x2e),
        Color.rgb(0xd7, 0x3a, 0x49),
        Color.rgb(0x28, 0xa7, 0x45),
        Color.rgb(0xdb, 0xab, 0x09),
        Color.rgb(0x03, 0x66, 0xd6),
        Color.rgb(0x5a, 0x32, 0xa3),
        Color.rgb(0x05, 0x98, 0xbc),
        Color.rgb(0x6a, 0x73, 0x7d),
        Color.rgb(0x95, 0x9d, 0xa5),
        Color.rgb(0xcb, 0x24, 0x31),
        Color.rgb(0x22, 0x86, 0x3a),
        Color.rgb(0xb0, 0x88, 0x00),
        Color.rgb(0x00, 0x5c, 0xc5),
        Color.rgb(0x5a, 0x32, 0xa3),
        Color.rgb(0x31, 0x92, 0xaa),
        Color.rgb(0xd1, 0xd5, 0xda),
    },
};

pub const themes = [_]Theme{
    ziggy,
    catppuccin_mocha,
    catppuccin_frappe,
    catppuccin_macchiato,
    tokyo_night,
    tokyo_night_storm,
    dracula,
    nord,
    rose_pine,
    gruvbox_dark,
    everforest_dark,
    kanagawa_wave,
    solarized_dark,
    one_dark,
    ayu_dark,
    paper,
    ember,
    catppuccin_latte,
    solarized_light,
    github_light,
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
    try std.testing.expectEqualStrings("Catppuccin Frappé", byName("catppuccin-frappe").name);
    try std.testing.expectEqualStrings("Catppuccin Macchiato", byName("catppuccin_macchiato").name);
    try std.testing.expectEqualStrings("Catppuccin Latte", byName("catppuccin-latte").name);
    try std.testing.expectEqualStrings("Tokyo Night", byName("tokyo night").name);
    try std.testing.expectEqualStrings("Tokyo Night Storm", byName("tokyo-night-storm").name);
    try std.testing.expectEqualStrings("Rose Pine", byName("rose_pine").name);
    try std.testing.expectEqualStrings("Ayu Dark", byName("ayu-dark").name);
    try std.testing.expectEqualStrings("Solarized Light", byName("solarized light").name);
    try std.testing.expectEqualStrings("GitHub Light", byName("github_light").name);
    try std.testing.expectEqualStrings("Ziggy", byName("unknown").name);
}

test "theme registry contains the documented 20 themes" {
    // Regression for the docs/landing-page claim that ZiggyZag ships N themes.
    // If this number changes, README.md, docs/index.html, and
    // docs/reference/theme-authoring.md all need to update in lockstep.
    try std.testing.expectEqual(@as(usize, 20), themes.len);
}

test "copies themes with overrides" {
    const themed = ziggy.withAccent(Color.rgb(1, 2, 3));
    try std.testing.expect(themed.accent.eql(Color.rgb(1, 2, 3)));
    try std.testing.expect(ziggy.accent.eql(Color.rgb(0x9b, 0xe2, 0x8f)));
}

test "cycles through known themes" {
    // Cycle order follows the `themes` array. Catppuccin Mocha sits right
    // after Ziggy, and Ember is the final dark variant before the light
    // section opens with Catppuccin Latte.
    try std.testing.expectEqualStrings("Catppuccin Mocha", next(ziggy).name);
    try std.testing.expectEqualStrings("Catppuccin Latte", next(ember).name);
    try std.testing.expectEqualStrings("Ziggy", next(github_light).name);
}
