const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);
    var stdout = std.Io.File.stdout().writer(init.io, &.{});

    while (true) {
        try stdout.interface.print("$ ", .{});

        const command = try stdin.interface.takeDelimiter('\n');
        const command_text = std.mem.trimEnd(u8, command orelse break, "\r");

        if (std.mem.eql(u8, command_text, "exit")) {
            break;
        } else if (std.mem.eql(u8, command_text, "echo")) {
            try stdout.interface.print("\n", .{});
        } else if (std.mem.startsWith(u8, command_text, "echo ")) {
            try stdout.interface.print("{s}\n", .{command_text[5..]});
        } else {
            try stdout.interface.print("{s}: command not found\n", .{command_text});
        }
    }
}
