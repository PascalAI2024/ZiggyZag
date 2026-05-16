const builtin = @import("builtin");

pub const integration = @import("integration.zig");
pub const config = @import("config.zig");
pub const pty = @import("pty.zig");
pub const terminal = @import("terminal.zig");
pub const theme = @import("theme.zig");
pub const windows_app = if (builtin.os.tag == .windows) @import("windows_app.zig") else struct {};

test {
    _ = integration;
    _ = config;
    _ = pty;
    _ = terminal;
    _ = theme;
    _ = windows_app;
}
