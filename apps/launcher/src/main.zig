const std = @import("std");
const builtin = @import("builtin");
const desktop = @import("desktop");

pub fn main(init_data: std.process.Init) !void {
    if (builtin.os.tag == .windows) {
        try desktop.windows_app.run(init_data);
        return;
    }
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        try desktop.posix_app.run(init_data);
        return;
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init_data.io, &stdout_buffer);
    defer stdout.interface.flush() catch {};

    try stdout.interface.writeAll(
        \\ZiggyZag
        \\
        \\This platform does not have a launcher entry point yet.
        \\
    );
}

test "launcher imports desktop modules" {
    _ = desktop.integration;
    _ = desktop.config;
    _ = desktop.pty;
    _ = desktop.terminal;
    _ = desktop.theme;
}
