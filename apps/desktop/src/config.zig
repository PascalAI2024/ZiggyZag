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
    scrollback_lines: usize = 10_000,
    trim_paste_trailing_newline: bool = true,
    multiline_paste_warn: bool = true,
    right_click_paste: bool = true,
    ctrl_scroll_zoom: bool = true,
    mouse_hide_while_typing: bool = false,
    private_history: bool = false,
    show_hints: bool = true,
    copy_on_select: bool = true,
};

/// A single NAME=VALUE environment entry supplied by a profile.
pub const EnvEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// Maximum number of env entries supported per profile.
pub const max_env_entries: usize = 32;

pub const Profile = struct {
    shell_path: []const u8 = "",
    startup_directory: []const u8 = "",
    term: []const u8 = "xterm-256color",
    /// Inline environment variable overrides (NAME=VALUE).
    env_entries: [max_env_entries]EnvEntry = [_]EnvEntry{.{ .name = "", .value = "" }} ** max_env_entries,
    env_count: usize = 0,
    /// Whether the embedded AgentD process should auto-start.
    agentd_autostart: bool = false,
    /// Socket path override for AgentD (empty = use default).
    agentd_socket: []const u8 = "",
};

pub const Session = struct {
    panes: usize = 1,
    orientation: []const u8 = "vertical",
};

/// Current config schema version.  Bump when a new required field is added.
pub const current_schema_version: u32 = 1;

pub const Config = struct {
    schema_version: u32 = current_schema_version,
    selected_theme: theme.Theme = theme.ziggy,
    font: Font = .{},
    options: Options = .{},
    profile: Profile = .{},
    session: Session = .{},

    pub fn defaults() Config {
        return .{};
    }
};

// ---------------------------------------------------------------------------
// Error sets
// ---------------------------------------------------------------------------

pub const ParseError = error{
    MissingEquals,
    MissingKey,
    UnknownKey,
    UnknownTheme,
    InvalidBoolean,
    InvalidFontSize,
    InvalidHexColor,
    InvalidInteger,
    InvalidScrollback,
    InvalidSessionPanes,
    InvalidSessionOrientation,
    TooManyEnvEntries,
    InvalidEnvEntry,
    InvalidSchemaVersion,
};

pub const ValidationError = error{
    ZeroScrollback,
    ScrollbackTooLarge,
    EmptyShellPath,
    FontSizeTooSmall,
    FontSizeTooLarge,
    ZeroPanes,
    TooManyPanes,
    InvalidOrientation,
    InvalidSchemaVersion,
};

// ---------------------------------------------------------------------------
// parse
// ---------------------------------------------------------------------------

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
    if (std.ascii.eqlIgnoreCase(key, "schema_version")) {
        const ver = std.fmt.parseInt(u32, value, 10) catch return error.InvalidSchemaVersion;
        config.schema_version = ver;
    } else if (std.ascii.eqlIgnoreCase(key, "theme")) {
        config.selected_theme = theme.maybeByName(value) orelse return error.UnknownTheme;
    } else if (std.ascii.eqlIgnoreCase(key, "theme.background")) {
        config.selected_theme = config.selected_theme.withBackground(try theme.Color.fromHex(value));
    } else if (std.ascii.eqlIgnoreCase(key, "theme.foreground")) {
        config.selected_theme = config.selected_theme.withForeground(try theme.Color.fromHex(value));
    } else if (std.ascii.eqlIgnoreCase(key, "theme.cursor")) {
        config.selected_theme = config.selected_theme.withCursor(try theme.Color.fromHex(value));
    } else if (std.ascii.eqlIgnoreCase(key, "theme.accent")) {
        config.selected_theme = config.selected_theme.withAccent(try theme.Color.fromHex(value));
    } else if (std.ascii.eqlIgnoreCase(key, "theme.panel")) {
        config.selected_theme = config.selected_theme.withPanel(try theme.Color.fromHex(value));
    } else if (std.ascii.eqlIgnoreCase(key, "theme.muted")) {
        config.selected_theme = config.selected_theme.withMuted(try theme.Color.fromHex(value));
    } else if (std.ascii.eqlIgnoreCase(key, "font.family")) {
        config.font.family = value;
    } else if (std.ascii.eqlIgnoreCase(key, "font.size")) {
        const size = std.fmt.parseInt(u8, value, 10) catch return error.InvalidFontSize;
        if (size < 6 or size > 72) return error.InvalidFontSize;
        config.font.size = size;
    } else if (std.ascii.eqlIgnoreCase(key, "profile.shell") or std.ascii.eqlIgnoreCase(key, "shell.path")) {
        config.profile.shell_path = value;
    } else if (std.ascii.eqlIgnoreCase(key, "profile.cwd") or std.ascii.eqlIgnoreCase(key, "startup_directory")) {
        config.profile.startup_directory = value;
    } else if (std.ascii.eqlIgnoreCase(key, "profile.term") or std.ascii.eqlIgnoreCase(key, "term")) {
        config.profile.term = value;
    } else if (std.ascii.eqlIgnoreCase(key, "profile.env")) {
        // value must be NAME=VALUE
        const sep = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidEnvEntry;
        if (sep == 0) return error.InvalidEnvEntry;
        if (config.profile.env_count >= max_env_entries) return error.TooManyEnvEntries;
        config.profile.env_entries[config.profile.env_count] = .{
            .name = value[0..sep],
            .value = value[sep + 1 ..],
        };
        config.profile.env_count += 1;
    } else if (std.ascii.eqlIgnoreCase(key, "agentd.autostart")) {
        config.profile.agentd_autostart = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "agentd.socket")) {
        config.profile.agentd_socket = value;
    } else if (std.ascii.eqlIgnoreCase(key, "show_status_bar")) {
        config.options.show_status_bar = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "smooth_scroll")) {
        config.options.smooth_scroll = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "bell")) {
        config.options.bell = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "scrollback") or std.ascii.eqlIgnoreCase(key, "scrollback.lines")) {
        const n_lines = std.fmt.parseInt(usize, value, 10) catch return error.InvalidScrollback;
        if (n_lines > 250_000) return error.InvalidScrollback;
        config.options.scrollback_lines = n_lines;
    } else if (std.ascii.eqlIgnoreCase(key, "trim_paste_trailing_newline")) {
        config.options.trim_paste_trailing_newline = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "multiline_paste_warn")) {
        config.options.multiline_paste_warn = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "right_click_paste")) {
        config.options.right_click_paste = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "ctrl_scroll_zoom")) {
        config.options.ctrl_scroll_zoom = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "mouse_hide_while_typing")) {
        config.options.mouse_hide_while_typing = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "private_history")) {
        config.options.private_history = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "show_hints")) {
        config.options.show_hints = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "copy_on_select")) {
        config.options.copy_on_select = try parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "session.panes") or std.ascii.eqlIgnoreCase(key, "panes")) {
        const panes = std.fmt.parseInt(usize, value, 10) catch return error.InvalidSessionPanes;
        if (panes == 0 or panes > 6) return error.InvalidSessionPanes;
        config.session.panes = panes;
    } else if (std.ascii.eqlIgnoreCase(key, "session.orientation") or std.ascii.eqlIgnoreCase(key, "split.orientation")) {
        if (!std.ascii.eqlIgnoreCase(value, "vertical") and !std.ascii.eqlIgnoreCase(value, "horizontal")) {
            return error.InvalidSessionOrientation;
        }
        config.session.orientation = value;
    } else {
        return error.UnknownKey;
    }
}

// ---------------------------------------------------------------------------
// serialize
// ---------------------------------------------------------------------------

/// Write the config as desktop.conf text to `writer`.
/// The output is valid input for `parse()` — i.e. parse(serialize(c)) == c
/// for all field-comparable values (theme color overrides are not re-emitted
/// as color lines; the named theme is re-emitted so the round-trip preserves
/// the theme identity, not per-field overrides applied on top of the name).
pub fn serialize(config: Config, writer: anytype) !void {
    try writer.print("schema_version = {d}\n", .{config.schema_version});
    try writer.print("theme = {s}\n", .{config.selected_theme.id});
    try writer.print("font.family = {s}\n", .{config.font.family});
    try writer.print("font.size = {d}\n", .{config.font.size});
    try writer.print("show_status_bar = {s}\n", .{boolStr(config.options.show_status_bar)});
    try writer.print("smooth_scroll = {s}\n", .{boolStr(config.options.smooth_scroll)});
    try writer.print("bell = {s}\n", .{boolStr(config.options.bell)});
    try writer.print("scrollback.lines = {d}\n", .{config.options.scrollback_lines});
    try writer.print("trim_paste_trailing_newline = {s}\n", .{boolStr(config.options.trim_paste_trailing_newline)});
    try writer.print("multiline_paste_warn = {s}\n", .{boolStr(config.options.multiline_paste_warn)});
    try writer.print("right_click_paste = {s}\n", .{boolStr(config.options.right_click_paste)});
    try writer.print("ctrl_scroll_zoom = {s}\n", .{boolStr(config.options.ctrl_scroll_zoom)});
    try writer.print("mouse_hide_while_typing = {s}\n", .{boolStr(config.options.mouse_hide_while_typing)});
    try writer.print("private_history = {s}\n", .{boolStr(config.options.private_history)});
    try writer.print("show_hints = {s}\n", .{boolStr(config.options.show_hints)});
    try writer.print("copy_on_select = {s}\n", .{boolStr(config.options.copy_on_select)});
    if (config.profile.shell_path.len > 0) {
        try writer.print("profile.shell = {s}\n", .{config.profile.shell_path});
    }
    if (config.profile.startup_directory.len > 0) {
        try writer.print("profile.cwd = {s}\n", .{config.profile.startup_directory});
    }
    try writer.print("profile.term = {s}\n", .{config.profile.term});
    for (config.profile.env_entries[0..config.profile.env_count]) |entry| {
        try writer.print("profile.env = {s}={s}\n", .{ entry.name, entry.value });
    }
    try writer.print("agentd.autostart = {s}\n", .{boolStr(config.profile.agentd_autostart)});
    if (config.profile.agentd_socket.len > 0) {
        try writer.print("agentd.socket = {s}\n", .{config.profile.agentd_socket});
    }
    try writer.print("session.panes = {d}\n", .{config.session.panes});
    try writer.print("session.orientation = {s}\n", .{config.session.orientation});
}

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

// ---------------------------------------------------------------------------
// validate
// ---------------------------------------------------------------------------

/// Check that all fields of `config` are within acceptable bounds.
/// Returns an error if any field is invalid; returns void on success.
pub fn validate(config: Config) ValidationError!void {
    if (config.schema_version == 0) return error.InvalidSchemaVersion;
    if (config.options.scrollback_lines == 0) return error.ZeroScrollback;
    if (config.options.scrollback_lines > 250_000) return error.ScrollbackTooLarge;
    if (config.font.size < 6) return error.FontSizeTooSmall;
    if (config.font.size > 72) return error.FontSizeTooLarge;
    if (config.session.panes == 0) return error.ZeroPanes;
    if (config.session.panes > 6) return error.TooManyPanes;
    if (!std.ascii.eqlIgnoreCase(config.session.orientation, "vertical") and
        !std.ascii.eqlIgnoreCase(config.session.orientation, "horizontal"))
    {
        return error.InvalidOrientation;
    }
    // shell_path emptiness is intentional for "use system default" — not an error.
    _ = config.profile.shell_path;
}

// ---------------------------------------------------------------------------
// migrate
// ---------------------------------------------------------------------------

/// Upgrade a config parsed from an older (or unversioned) file to the current
/// schema.  Missing/zero fields receive their defaults; existing values are
/// kept.  Returns the migrated Config with schema_version set to
/// `current_schema_version`.
pub fn migrate(old: Config) Config {
    var c = old;

    // Version 0 / unversioned: schema_version was not written.  Default all
    // newly-added fields that were absent in that generation.
    if (c.schema_version == 0) {
        // profile.term was added in v1; if empty, restore default.
        if (c.profile.term.len == 0) {
            c.profile.term = Config.defaults().profile.term;
        }
        // agentd fields were added in v1.
        // (already zero-initialized by the defaults path)
        c.schema_version = current_schema_version;
    }

    // Future version bumps: add `if (c.schema_version < N)` blocks here.

    c.schema_version = current_schema_version;
    return c;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
        \\theme = catppuccin mocha
        \\font.family = "JetBrains Mono"
        \\font.size = 16
        \\show_status_bar = off
        \\smooth_scroll = yes
        \\bell = true
        \\scrollback.lines = 50000
        \\profile.shell = "C:\Tools\ziggyzag.exe"
        \\profile.cwd = "C:\dev"
        \\profile.term = xterm-256color
        \\session.panes = 3
        \\session.orientation = horizontal
        \\
    );

    try std.testing.expectEqualStrings("Catppuccin Mocha", parsed.selected_theme.name);
    try std.testing.expectEqualStrings("JetBrains Mono", parsed.font.family);
    try std.testing.expectEqual(@as(u8, 16), parsed.font.size);
    try std.testing.expect(!parsed.options.show_status_bar);
    try std.testing.expect(parsed.options.smooth_scroll);
    try std.testing.expect(parsed.options.bell);
    try std.testing.expectEqual(@as(usize, 50_000), parsed.options.scrollback_lines);
    try std.testing.expectEqualStrings("C:\\Tools\\ziggyzag.exe", parsed.profile.shell_path);
    try std.testing.expectEqualStrings("C:\\dev", parsed.profile.startup_directory);
    try std.testing.expectEqualStrings("xterm-256color", parsed.profile.term);
    try std.testing.expectEqual(@as(usize, 3), parsed.session.panes);
    try std.testing.expectEqualStrings("horizontal", parsed.session.orientation);
}

test "parses theme color overrides" {
    const parsed = try parse(
        \\theme = ember
        \\theme.background = #010203
        \\theme.foreground = 0a0b0c
        \\theme.cursor = #111213
        \\theme.accent = #212223
        \\theme.panel = #313233
        \\theme.muted = #414243
    );

    try std.testing.expectEqualStrings("Ember", parsed.selected_theme.name);
    try std.testing.expect(parsed.selected_theme.background.eql(theme.Color.rgb(1, 2, 3)));
    try std.testing.expect(parsed.selected_theme.foreground.eql(theme.Color.rgb(0x0a, 0x0b, 0x0c)));
    try std.testing.expect(parsed.selected_theme.cursor.eql(theme.Color.rgb(0x11, 0x12, 0x13)));
    try std.testing.expect(parsed.selected_theme.accent.eql(theme.Color.rgb(0x21, 0x22, 0x23)));
    try std.testing.expect(parsed.selected_theme.panel.eql(theme.Color.rgb(0x31, 0x32, 0x33)));
    try std.testing.expect(parsed.selected_theme.muted.eql(theme.Color.rgb(0x41, 0x42, 0x43)));
}

test "rejects unknown keys and invalid values" {
    try std.testing.expectError(error.UnknownKey, parse("window.opacity=90\n"));
    try std.testing.expectError(error.UnknownTheme, parse("theme=neon\n"));
    try std.testing.expectError(error.InvalidFontSize, parse("font.size=3\n"));
    try std.testing.expectError(error.InvalidBoolean, parse("bell=maybe\n"));
    try std.testing.expectError(error.InvalidScrollback, parse("scrollback=999999999\n"));
    try std.testing.expectError(error.InvalidSessionPanes, parse("session.panes=7\n"));
    try std.testing.expectError(error.InvalidSessionOrientation, parse("session.orientation=diagonal\n"));
}

test "serialize round-trips config" {
    // Build a non-default config by parsing a config string.
    const original = try parse(
        \\theme = dracula
        \\font.family = Fira Code
        \\font.size = 18
        \\show_status_bar = false
        \\smooth_scroll = false
        \\bell = true
        \\scrollback.lines = 20000
        \\profile.shell = /usr/bin/zsh
        \\profile.cwd = /home/user
        \\profile.term = xterm-256color
        \\agentd.autostart = true
        \\session.panes = 2
        \\session.orientation = horizontal
        \\
    );

    // Serialize to a buffer.
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try serialize(original, &aw.writer);
    const serialized = aw.written();

    // Parse the serialized text and compare relevant fields.
    const round_tripped = try parse(serialized);

    try std.testing.expectEqualStrings(original.selected_theme.id, round_tripped.selected_theme.id);
    try std.testing.expectEqualStrings(original.font.family, round_tripped.font.family);
    try std.testing.expectEqual(original.font.size, round_tripped.font.size);
    try std.testing.expectEqual(original.options.show_status_bar, round_tripped.options.show_status_bar);
    try std.testing.expectEqual(original.options.smooth_scroll, round_tripped.options.smooth_scroll);
    try std.testing.expectEqual(original.options.bell, round_tripped.options.bell);
    try std.testing.expectEqual(original.options.scrollback_lines, round_tripped.options.scrollback_lines);
    try std.testing.expectEqualStrings(original.profile.shell_path, round_tripped.profile.shell_path);
    try std.testing.expectEqualStrings(original.profile.startup_directory, round_tripped.profile.startup_directory);
    try std.testing.expectEqualStrings(original.profile.term, round_tripped.profile.term);
    try std.testing.expectEqual(original.profile.agentd_autostart, round_tripped.profile.agentd_autostart);
    try std.testing.expectEqual(original.session.panes, round_tripped.session.panes);
    try std.testing.expectEqualStrings(original.session.orientation, round_tripped.session.orientation);
    try std.testing.expectEqual(original.schema_version, round_tripped.schema_version);
}

test "serialize round-trips env entries" {
    const original = try parse(
        \\profile.env = FOO=bar
        \\profile.env = MY_VAR=hello world
        \\
    );
    try std.testing.expectEqual(@as(usize, 2), original.profile.env_count);

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try serialize(original, &aw.writer);
    const serialized = aw.written();

    const round_tripped = try parse(serialized);
    try std.testing.expectEqual(@as(usize, 2), round_tripped.profile.env_count);
    try std.testing.expectEqualStrings("FOO", round_tripped.profile.env_entries[0].name);
    try std.testing.expectEqualStrings("bar", round_tripped.profile.env_entries[0].value);
    try std.testing.expectEqualStrings("MY_VAR", round_tripped.profile.env_entries[1].name);
    try std.testing.expectEqualStrings("hello world", round_tripped.profile.env_entries[1].value);
}

test "validate accepts valid config" {
    try validate(Config.defaults());
}

test "validate rejects zero scrollback" {
    var c = Config.defaults();
    c.options.scrollback_lines = 0;
    try std.testing.expectError(error.ZeroScrollback, validate(c));
}

test "validate rejects oversized scrollback" {
    var c = Config.defaults();
    c.options.scrollback_lines = 300_000;
    try std.testing.expectError(error.ScrollbackTooLarge, validate(c));
}

test "validate rejects font size out of range" {
    var c = Config.defaults();
    c.font.size = 5;
    try std.testing.expectError(error.FontSizeTooSmall, validate(c));
    c.font.size = 73;
    try std.testing.expectError(error.FontSizeTooLarge, validate(c));
}

test "validate rejects bad pane count" {
    var c = Config.defaults();
    c.session.panes = 0;
    try std.testing.expectError(error.ZeroPanes, validate(c));
    c.session.panes = 7;
    try std.testing.expectError(error.TooManyPanes, validate(c));
}

test "validate rejects invalid orientation" {
    var c = Config.defaults();
    c.session.orientation = "diagonal";
    try std.testing.expectError(error.InvalidOrientation, validate(c));
}

test "profile parses agentd and env fields" {
    const parsed = try parse(
        \\agentd.autostart = true
        \\agentd.socket = /tmp/agentd.sock
        \\profile.env = EDITOR=vim
        \\profile.env = PAGER=less
        \\
    );
    try std.testing.expect(parsed.profile.agentd_autostart);
    try std.testing.expectEqualStrings("/tmp/agentd.sock", parsed.profile.agentd_socket);
    try std.testing.expectEqual(@as(usize, 2), parsed.profile.env_count);
    try std.testing.expectEqualStrings("EDITOR", parsed.profile.env_entries[0].name);
    try std.testing.expectEqualStrings("vim", parsed.profile.env_entries[0].value);
    try std.testing.expectEqualStrings("PAGER", parsed.profile.env_entries[1].name);
    try std.testing.expectEqualStrings("less", parsed.profile.env_entries[1].value);
}

test "profile rejects malformed env entry" {
    try std.testing.expectError(error.InvalidEnvEntry, parse("profile.env = NOVALUE\n"));
    try std.testing.expectError(error.InvalidEnvEntry, parse("profile.env = =value\n"));
}

test "migrate upgrades schema version 0 to current" {
    // Simulate a v0 config: schema_version not present (defaults to current),
    // so we manually create one with version 0 and empty term to mimic a
    // pre-v1 parse.
    var old = Config.defaults();
    old.schema_version = 0;
    old.profile.term = ""; // was absent in hypothetical pre-v1 files

    const migrated = migrate(old);

    try std.testing.expectEqual(current_schema_version, migrated.schema_version);
    // Missing term should have been restored to the default.
    try std.testing.expectEqualStrings("xterm-256color", migrated.profile.term);
}

test "migrate preserves existing values" {
    var old = Config.defaults();
    old.schema_version = 0;
    old.font.family = "Comic Sans";
    old.profile.term = "vt100"; // non-empty: must be preserved

    const migrated = migrate(old);

    try std.testing.expectEqual(current_schema_version, migrated.schema_version);
    try std.testing.expectEqualStrings("Comic Sans", migrated.font.family);
    try std.testing.expectEqualStrings("vt100", migrated.profile.term);
}

test "schema_version field parses and serializes" {
    const parsed = try parse("schema_version = 1\ntheme = ziggy\n");
    try std.testing.expectEqual(@as(u32, 1), parsed.schema_version);

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try serialize(parsed, &aw.writer);
    const text = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "schema_version = 1") != null);
}
