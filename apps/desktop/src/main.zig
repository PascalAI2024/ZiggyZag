const std = @import("std");
const builtin = @import("builtin");
const desktop = @import("lib.zig");

pub fn main(init_data: std.process.Init) !void {
    if (builtin.os.tag == .windows) {
        try desktop.windows_app.run(init_data);
        return;
    }

    var stdout = std.Io.File.stdout().writer(init_data.io, &.{});
    const selected_theme = desktop.theme.ziggy;
    const backend = desktop.pty.preferredBackend();

    try stdout.interface.print(
        \\ZiggyZag Desktop
        \\
        \\All-Zig terminal host foundation
        \\- PTY backend target: {s}
        \\- Theme: {s}
        \\- Terminal grid core: ready
        \\- OSC 777 integration parser: ready
        \\
        \\Next step: connect {s} to a native window and PTY process.
        \\
    , .{
        desktop.pty.backendName(backend),
        selected_theme.name,
        desktop.pty.backendName(backend),
    });
}
