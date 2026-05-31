const builtin = @import("builtin");

pub const integration = @import("integration.zig");
pub const config = @import("config.zig");
pub const pty = @import("pty.zig");
pub const terminal = @import("terminal.zig");
pub const theme = @import("theme.zig");
pub const posix_app = if (builtin.os.tag == .linux or builtin.os.tag == .macos) @import("posix_app.zig") else struct {};
pub const windows_app = if (builtin.os.tag == .windows) @import("windows_app.zig") else struct {};

test {
    _ = integration;
    _ = config;
    _ = pty;
    _ = terminal;
    _ = theme;
    _ = posix_app;
    _ = windows_app;
}
