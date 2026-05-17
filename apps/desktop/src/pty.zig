const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const posix = @import("posix_pty.zig");

/// Set of backends this module knows how to dispatch to. The Wave 2 selector
/// (`preferredBackend` + `backendName`) still uses the broad
/// {windows_conpty, posix_pty, unavailable} labels under the hood for
/// `main.zig`'s welcome banner; the Wave 3 `Pty` interface refines those to
/// the four concrete implementations listed here.
pub const Backend = enum {
    conpty_windows,
    native_posix,
    script_posix,
    direct_posix,
    unavailable,
};

pub fn isPosixPtyTarget(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd => true,
        else => false,
    };
}

/// Comptime selection of the most capable backend for the build target.
/// Today POSIX hosts ship the `script(1)` fallback; once `native_posix` lands
/// (Wave 3 native window host) this returns `.native_posix` instead.
pub fn currentBackend() Backend {
    return switch (builtin.os.tag) {
        .windows => .conpty_windows,
        .linux, .macos, .freebsd, .netbsd, .openbsd => .script_posix,
        else => .unavailable,
    };
}

/// Legacy alias retained so `main.zig`'s banner keeps working unchanged.
pub fn preferredBackend() Backend {
    return currentBackend();
}

pub fn backendName(backend: Backend) []const u8 {
    return switch (backend) {
        .conpty_windows => "Windows ConPTY",
        .native_posix => "POSIX native PTY",
        .script_posix => "POSIX script(1) PTY",
        .direct_posix => "POSIX direct stdio",
        .unavailable => "unavailable",
    };
}

// ---------------------------------------------------------------------------
// Wave 3 Pty interface
// ---------------------------------------------------------------------------

/// Platform-abstracting PTY handle. Concrete backends populate the function
/// pointers and supply an opaque self pointer; consumers never have to switch
/// on `builtin.os.tag` directly.
pub const Pty = struct {
    ctx: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit_fn: *const fn (ctx: ?*anyopaque) void,
        read_fn: *const fn (ctx: ?*anyopaque, buf: []u8) anyerror!usize,
        write_fn: *const fn (ctx: ?*anyopaque, bytes: []const u8) anyerror!usize,
        resize_fn: *const fn (ctx: ?*anyopaque, cols: u16, rows: u16) anyerror!void,
        wait_fn: *const fn (ctx: ?*anyopaque) anyerror!std.process.Child.Term,
    };

    pub const SpawnOptions = struct {
        allocator: Allocator,
        io: std.Io,
        env_map: *std.process.Environ.Map,
        argv: []const []const u8,
        cwd: ?[]const u8 = null,
        cols: u16 = 80,
        rows: u16 = 24,
    };

    /// Spawn a child process attached to a PTY using the build target's
    /// preferred backend. Returns `error.NotImplemented` on platforms where
    /// no backend is wired yet (Wave 3 work).
    pub fn spawn(
        allocator: Allocator,
        io: std.Io,
        env_map: *std.process.Environ.Map,
        argv: []const []const u8,
        cwd: ?[]const u8,
        cols: u16,
        rows: u16,
    ) !Pty {
        const opts: SpawnOptions = .{
            .allocator = allocator,
            .io = io,
            .env_map = env_map,
            .argv = argv,
            .cwd = cwd,
            .cols = cols,
            .rows = rows,
        };

        return switch (currentBackend()) {
            .conpty_windows => spawnConPty(opts),
            .native_posix => spawnNativePosix(opts),
            .script_posix => spawnScriptPosix(opts),
            .direct_posix => spawnDirectPosix(opts),
            .unavailable => error.NotImplemented,
        };
    }

    pub fn deinit(self: Pty) void {
        self.vtable.deinit_fn(self.ctx);
    }

    /// Non-blocking read. Returns `0` when no data is currently available;
    /// surfaces `error.EndOfStream` only when the underlying handle has been
    /// fully closed and drained.
    pub fn read(self: Pty, buf: []u8) !usize {
        return self.vtable.read_fn(self.ctx, buf);
    }

    pub fn write(self: Pty, bytes: []const u8) !usize {
        return self.vtable.write_fn(self.ctx, bytes);
    }

    pub fn resize(self: Pty, cols: u16, rows: u16) !void {
        return self.vtable.resize_fn(self.ctx, cols, rows);
    }

    pub fn wait(self: Pty) !std.process.Child.Term {
        return self.vtable.wait_fn(self.ctx);
    }
};

// ---------------------------------------------------------------------------
// Windows backend stub
// ---------------------------------------------------------------------------

// TODO Wave 3: extract the ConPTY spawn/read/write/resize/wait machinery from
// `windows_app.zig` (see the HPCON/CreatePseudoConsole block near the top of
// that file). For now we keep the working implementation inline in the
// Windows app and only expose this stub so `Pty.spawn` has a target.
fn spawnConPty(opts: Pty.SpawnOptions) !Pty {
    _ = opts;
    return error.NotImplemented;
}

// ---------------------------------------------------------------------------
// POSIX backend stubs
// ---------------------------------------------------------------------------

// TODO Wave 3: wrap `posix_pty.spawnShell` + `relayPty` from `posix_app.zig`
// behind the Pty vtable. The native backend is the long-term target for the
// graphical host.
fn spawnNativePosix(opts: Pty.SpawnOptions) !Pty {
    _ = opts;
    return error.NotImplemented;
}

// TODO Wave 3: wrap the `script(1)` fallback path from
// `posix_app.zig::runWithScript` behind the Pty vtable.
fn spawnScriptPosix(opts: Pty.SpawnOptions) !Pty {
    _ = opts;
    return error.NotImplemented;
}

// TODO Wave 3: wrap the direct stdio path from `posix_app.zig::runDirect`
// behind the Pty vtable. This backend is used when the host has no PTY at
// all (CI, headless containers).
fn spawnDirectPosix(opts: Pty.SpawnOptions) !Pty {
    _ = opts;
    return error.NotImplemented;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "preferred backend is named" {
    const name = backendName(preferredBackend());
    try std.testing.expect(name.len > 0);
}

test "posix target helper matches preferred backend coverage" {
    try std.testing.expect(isPosixPtyTarget(.linux));
    try std.testing.expect(isPosixPtyTarget(.macos));
    try std.testing.expect(isPosixPtyTarget(.freebsd));
    try std.testing.expect(isPosixPtyTarget(.netbsd));
    try std.testing.expect(isPosixPtyTarget(.openbsd));
    try std.testing.expect(!isPosixPtyTarget(.windows));
}

test "currentBackend resolves per OS tag" {
    const backend = currentBackend();
    switch (builtin.os.tag) {
        .windows => try std.testing.expectEqual(Backend.conpty_windows, backend),
        .linux, .macos, .freebsd, .netbsd, .openbsd => {
            // Today the POSIX host ships through `script(1)`; once the native
            // PTY backend lands this branch will tighten to `.native_posix`.
            try std.testing.expect(backend == .script_posix or backend == .native_posix);
        },
        else => try std.testing.expectEqual(Backend.unavailable, backend),
    }
}

test "Pty interface size is reasonable" {
    try std.testing.expect(@sizeOf(Pty) < 256);
}

test "all backend stubs return NotImplemented" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    const opts: Pty.SpawnOptions = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .env_map = &env_map,
        .argv = &.{},
        .cwd = null,
        .cols = 80,
        .rows = 24,
    };

    try std.testing.expectError(error.NotImplemented, spawnConPty(opts));
    try std.testing.expectError(error.NotImplemented, spawnNativePosix(opts));
    try std.testing.expectError(error.NotImplemented, spawnScriptPosix(opts));
    try std.testing.expectError(error.NotImplemented, spawnDirectPosix(opts));
}
