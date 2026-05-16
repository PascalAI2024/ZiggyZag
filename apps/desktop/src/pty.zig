const builtin = @import("builtin");

pub const Backend = enum {
    windows_conpty,
    posix_pty,
    unavailable,
};

pub fn preferredBackend() Backend {
    return switch (builtin.os.tag) {
        .windows => .windows_conpty,
        .linux, .macos, .freebsd, .netbsd, .openbsd => .posix_pty,
        else => .unavailable,
    };
}

pub fn backendName(backend: Backend) []const u8 {
    return switch (backend) {
        .windows_conpty => "Windows ConPTY",
        .posix_pty => "POSIX PTY",
        .unavailable => "unavailable",
    };
}

test "preferred backend is named" {
    const name = backendName(preferredBackend());
    try @import("std").testing.expect(name.len > 0);
}
