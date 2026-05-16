const std = @import("std");
const builtin = @import("builtin");

pub const posix = @import("posix_pty.zig");

pub const Backend = enum {
    windows_conpty,
    posix_pty,
    unavailable,
};

pub fn isPosixPtyTarget(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd => true,
        else => false,
    };
}

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

test "posix target helper matches preferred backend coverage" {
    try @import("std").testing.expect(isPosixPtyTarget(.linux));
    try @import("std").testing.expect(isPosixPtyTarget(.macos));
    try @import("std").testing.expect(isPosixPtyTarget(.freebsd));
    try @import("std").testing.expect(isPosixPtyTarget(.netbsd));
    try @import("std").testing.expect(isPosixPtyTarget(.openbsd));
    try @import("std").testing.expect(!isPosixPtyTarget(.windows));
}
