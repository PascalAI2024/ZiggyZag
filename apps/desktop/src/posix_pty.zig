const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const linux = std.os.linux;
const native_os = builtin.os.tag;

// Linux and macOS are the supported POSIX targets. The BSD-specific code
// paths below are retained but inert: the BSDs are not built, linked, or
// tested, so `supported` excludes them.
pub const supported = switch (native_os) {
    .linux, .macos => true,
    else => false,
};

pub const Fd = if (supported) posix.fd_t else i32;
pub const Pid = if (supported) posix.pid_t else i32;
pub const invalid_fd: Fd = -1;

const uses_libc_pty = switch (native_os) {
    .macos, .freebsd, .netbsd, .openbsd => true,
    else => false,
};

const empty_environment = [_:null]?[*:0]const u8{};

pub const Size = struct {
    rows: u16 = 24,
    cols: u16 = 80,

    pub fn isValid(self: Size) bool {
        return self.rows > 0 and self.cols > 0;
    }
};

pub const Pair = struct {
    master_fd: Fd = invalid_fd,
    slave_fd: Fd = invalid_fd,

    pub fn close(self: *Pair) void {
        self.closeSlave();
        closeFd(self.master_fd);
        self.master_fd = invalid_fd;
    }

    pub fn closeSlave(self: *Pair) void {
        closeFd(self.slave_fd);
        self.slave_fd = invalid_fd;
    }
};

pub const Session = struct {
    master_fd: Fd = invalid_fd,
    child_pid: Pid,

    pub fn closeMaster(self: *Session) void {
        closeFd(self.master_fd);
        self.master_fd = invalid_fd;
    }

    pub fn resize(self: Session, size: Size) Error!void {
        try setWindowSize(self.master_fd, size);
    }
};

pub const PollFd = if (supported) posix.pollfd else void;

pub const PollEvent = struct {
    pub const input = if (supported) posix.POLL.IN else 0;
    pub const output = if (supported) posix.POLL.OUT else 0;
    pub const error_or_hangup = if (supported) posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL else 0;
};

pub const SpawnOptions = struct {
    shell_path: ?[*:0]const u8 = null,
    argv: ?[*:null]const ?[*:0]const u8 = null,
    /// Null means an explicit empty environment. Pass an envp block when the
    /// child shell should inherit or receive specific variables.
    envp: ?[*:null]const ?[*:0]const u8 = null,
    size: Size = .{},
    /// Optional working directory for the child process. Null means inherit
    /// the parent's cwd. Must be a NUL-terminated path.
    cwd: ?[*:0]const u8 = null,
};

pub const Error = posix.OpenError || std.fmt.BufPrintError || error{
    UnsupportedOperatingSystem,
    InvalidSize,
    InvalidPtyName,
    InvalidFileDescriptor,
    ForkFailed,
    ProcessNotFound,
    WouldBlock,
    BrokenPipe,
    InputOutput,
    PermissionDenied,
    SystemResources,
    Unexpected,
};

pub fn defaultShellPath() [*:0]const u8 {
    return "/bin/sh";
}

pub fn defaultEnvp() [*:null]const ?[*:0]const u8 {
    return &empty_environment;
}

pub fn openPair(size: Size) Error!Pair {
    if (!supported) return error.UnsupportedOperatingSystem;
    if (!size.isValid()) return error.InvalidSize;

    return switch (native_os) {
        .linux => openLinuxPair(size),
        .macos, .freebsd, .netbsd, .openbsd => openLibcPair(size),
        else => error.UnsupportedOperatingSystem,
    };
}

pub fn setWindowSize(fd: Fd, size: Size) Error!void {
    if (!supported) return error.UnsupportedOperatingSystem;
    if (!size.isValid()) return error.InvalidSize;
    if (!isOpenFd(fd)) return error.InvalidFileDescriptor;

    var ws = posix.winsize{
        .row = size.rows,
        .col = size.cols,
        .xpixel = 0,
        .ypixel = 0,
    };

    switch (native_os) {
        .linux => try linuxIoctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&ws)),
        .macos => try libcIoctlPtr(fd, darwinTtyIoctl.set_window_size, &ws),
        .freebsd, .netbsd, .openbsd => try libcIoctlPtr(fd, bsdTtyIoctl.set_window_size, &ws),
        else => return error.UnsupportedOperatingSystem,
    }
}

pub fn queryWindowSize(fd: Fd) Error!?Size {
    if (!supported) return error.UnsupportedOperatingSystem;
    if (!isOpenFd(fd)) return error.InvalidFileDescriptor;

    var ws = posix.winsize{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    switch (native_os) {
        .linux => try linuxIoctl(fd, linux.T.IOCGWINSZ, @intFromPtr(&ws)),
        .macos => try libcIoctlPtr(fd, darwinTtyIoctl.get_window_size, &ws),
        .freebsd, .netbsd, .openbsd => try libcIoctlPtr(fd, bsdTtyIoctl.get_window_size, &ws),
        else => return error.UnsupportedOperatingSystem,
    }

    const size = Size{ .rows = ws.row, .cols = ws.col };
    if (!size.isValid()) return null;
    return size;
}

pub fn spawnShell(options: SpawnOptions) Error!Session {
    if (!supported) return error.UnsupportedOperatingSystem;

    const shell = options.shell_path orelse defaultShellPath();
    const default_argv = [_:null]?[*:0]const u8{shell};
    const argv = options.argv orelse &default_argv;
    const envp = options.envp orelse defaultEnvp();

    var pair = try openPair(options.size);
    errdefer pair.close();

    const pid = try forkProcess();
    if (pid == 0) {
        childExec(pair, shell, argv, envp, options.cwd);
    }

    pair.closeSlave();
    return .{
        .master_fd = pair.master_fd,
        .child_pid = pid,
    };
}

pub fn readFd(fd: Fd, buffer: []u8) Error!usize {
    if (!supported) return error.UnsupportedOperatingSystem;
    if (!isOpenFd(fd)) return error.InvalidFileDescriptor;
    if (buffer.len == 0) return 0;

    while (true) {
        switch (native_os) {
            .linux => {
                const rc = linux.read(fd, buffer.ptr, buffer.len);
                switch (posix.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    else => |err| return errnoToError(err),
                }
            },
            .macos, .freebsd, .netbsd, .openbsd => {
                const rc = std.c.read(fd, buffer.ptr, buffer.len);
                switch (std.c.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    else => |err| return errnoToError(err),
                }
            },
            else => return error.UnsupportedOperatingSystem,
        }
    }
}

pub fn writeAll(fd: Fd, bytes: []const u8) Error!void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const written = try writeFd(fd, remaining);
        if (written == 0) return error.Unexpected;
        remaining = remaining[written..];
    }
}

pub fn poll(fds: []PollFd, timeout_ms: i32) Error!usize {
    if (!supported) return error.UnsupportedOperatingSystem;
    return posix.poll(fds, timeout_ms) catch |err| switch (err) {
        error.SystemResources => error.SystemResources,
        else => error.Unexpected,
    };
}

pub fn waitNoHang(pid: Pid) Error!?std.process.Child.Term {
    if (!supported) return error.UnsupportedOperatingSystem;

    switch (native_os) {
        .linux => if (!builtin.link_libc) {
            var status: u32 = 0;
            while (true) {
                const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
                switch (posix.errno(rc)) {
                    .SUCCESS => {
                        if (rc == 0) return null;
                        return statusToTerm(status);
                    },
                    .INTR => continue,
                    else => |err| return errnoToError(err),
                }
            }
        },
        else => {},
    }

    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, posix.W.NOHANG);
        switch (std.c.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return null;
                return statusToTerm(@bitCast(status));
            },
            .INTR => continue,
            else => |err| return errnoToError(err),
        }
    }
}

fn openLinuxPair(size: Size) Error!Pair {
    const master = try posix.openatZ(posix.AT.FDCWD, "/dev/ptmx", openFlags(), 0);
    errdefer closeFd(master);

    var unlock: c_int = 0;
    try linuxIoctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock));

    var number: c_uint = 0;
    try linuxIoctl(master, linux.T.IOCGPTN, @intFromPtr(&number));

    var slave_path_buf: [64]u8 = undefined;
    const slave_path = try std.fmt.bufPrintZ(&slave_path_buf, "/dev/pts/{d}", .{number});
    const slave = try posix.openatZ(posix.AT.FDCWD, slave_path.ptr, openFlags(), 0);
    errdefer closeFd(slave);

    try setWindowSize(master, size);
    return .{ .master_fd = master, .slave_fd = slave };
}

fn openLibcPair(size: Size) Error!Pair {
    const master = libcPty.posix_openpt(openFlagsBits(openFlags()));
    if (master < 0) return errnoError();
    errdefer closeFd(master);

    if (libcPty.grantpt(master) < 0) return errnoError();
    if (libcPty.unlockpt(master) < 0) return errnoError();

    const slave_name = libcPty.ptsname(master) orelse return error.InvalidPtyName;
    const slave = try posix.openatZ(posix.AT.FDCWD, slave_name, openFlags(), 0);
    errdefer closeFd(slave);

    try setWindowSize(master, size);
    return .{ .master_fd = master, .slave_fd = slave };
}

fn childExec(
    pair: Pair,
    shell: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: ?[*:0]const u8,
) noreturn {
    closeFd(pair.master_fd);

    if (setsidProcess()) |_| {} else |_| childExit(127);
    if (setControllingTty(pair.slave_fd)) |_| {} else |_| childExit(127);

    // Change working directory in the child before exec, so the shell starts
    // in the requested directory.  On failure the child exits with status 127,
    // consistent with the other setup steps above.
    if (cwd) |dir| chdirProcess(dir) catch childExit(127);

    dupTo(pair.slave_fd, 0) catch childExit(127);
    dupTo(pair.slave_fd, 1) catch childExit(127);
    dupTo(pair.slave_fd, 2) catch childExit(127);
    if (pair.slave_fd > 2) closeFd(pair.slave_fd);

    execProcess(shell, argv, envp);
    childExit(127);
}

fn openFlags() posix.O {
    return .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
    };
}

fn openFlagsBits(flags: posix.O) c_int {
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(posix.O));
    return @intCast(@as(Bits, @bitCast(flags)));
}

fn closeFd(fd: Fd) void {
    if (!supported) return;
    if (!isOpenFd(fd)) return;
    switch (native_os) {
        .linux => _ = linux.close(fd),
        .macos, .freebsd, .netbsd, .openbsd => _ = std.c.close(fd),
        else => {},
    }
}

fn writeFd(fd: Fd, bytes: []const u8) Error!usize {
    if (!supported) return error.UnsupportedOperatingSystem;
    if (!isOpenFd(fd)) return error.InvalidFileDescriptor;
    if (bytes.len == 0) return 0;

    while (true) {
        switch (native_os) {
            .linux => {
                const rc = linux.write(fd, bytes.ptr, bytes.len);
                switch (posix.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    else => |err| return errnoToError(err),
                }
            },
            .macos, .freebsd, .netbsd, .openbsd => {
                const rc = std.c.write(fd, bytes.ptr, bytes.len);
                switch (std.c.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    else => |err| return errnoToError(err),
                }
            },
            else => return error.UnsupportedOperatingSystem,
        }
    }
}

fn isOpenFd(fd: Fd) bool {
    return fd >= 0;
}

fn forkProcess() Error!Pid {
    switch (native_os) {
        .linux => {
            const rc = linux.fork();
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .AGAIN => return error.ForkFailed,
                else => |err| return errnoToError(err),
            }
        },
        .macos, .freebsd, .netbsd, .openbsd => {
            const rc = std.c.fork();
            switch (std.c.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .AGAIN => return error.ForkFailed,
                else => |err| return errnoToError(err),
            }
        },
        else => return error.UnsupportedOperatingSystem,
    }
}

fn setsidProcess() Error!Pid {
    switch (native_os) {
        .linux => {
            const rc = linux.setsid();
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                else => |err| return errnoToError(err),
            }
        },
        .macos, .freebsd, .netbsd, .openbsd => {
            const rc = std.c.setsid();
            switch (std.c.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                else => |err| return errnoToError(err),
            }
        },
        else => return error.UnsupportedOperatingSystem,
    }
}

fn setControllingTty(fd: Fd) Error!void {
    switch (native_os) {
        .linux => try linuxIoctl(fd, linux.T.IOCSCTTY, 0),
        .macos => try libcIoctlInt(fd, darwinTtyIoctl.set_controlling_tty, 0),
        .freebsd, .netbsd, .openbsd => try libcIoctlInt(fd, bsdTtyIoctl.set_controlling_tty, 0),
        else => return error.UnsupportedOperatingSystem,
    }
}

fn dupTo(old_fd: Fd, new_fd: Fd) Error!void {
    switch (native_os) {
        .linux => {
            const rc = linux.dup2(old_fd, new_fd);
            switch (posix.errno(rc)) {
                .SUCCESS => return,
                else => |err| return errnoToError(err),
            }
        },
        .macos, .freebsd, .netbsd, .openbsd => {
            const rc = std.c.dup2(old_fd, new_fd);
            switch (std.c.errno(rc)) {
                .SUCCESS => return,
                else => |err| return errnoToError(err),
            }
        },
        else => return error.UnsupportedOperatingSystem,
    }
}

fn chdirProcess(path: [*:0]const u8) Error!void {
    switch (native_os) {
        .linux => {
            const rc = linux.chdir(path);
            switch (posix.errno(rc)) {
                .SUCCESS => {},
                else => |err| return errnoToError(err),
            }
        },
        .macos, .freebsd, .netbsd, .openbsd => {
            const rc = std.c.chdir(path);
            switch (std.c.errno(rc)) {
                .SUCCESS => {},
                else => |err| return errnoToError(err),
            }
        },
        else => return error.UnsupportedOperatingSystem,
    }
}

fn execProcess(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) void {
    switch (native_os) {
        .linux => _ = linux.execve(path, argv, envp),
        .macos, .freebsd, .netbsd, .openbsd => _ = std.c.execve(path, argv, envp),
        else => {},
    }
}

fn childExit(status: u8) noreturn {
    switch (native_os) {
        .linux => linux.exit(status),
        .macos, .freebsd, .netbsd, .openbsd => std.c._exit(status),
        else => unreachable,
    }
}

fn linuxIoctl(fd: Fd, request: u32, arg: usize) Error!void {
    const rc = linux.ioctl(fd, request, arg);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return errnoToError(err),
    }
}

fn libcIoctlPtr(fd: Fd, request: c_int, arg: *anyopaque) Error!void {
    const rc = std.c.ioctl(fd, request, arg);
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        else => |err| return errnoToError(err),
    }
}

fn libcIoctlInt(fd: Fd, request: c_int, arg: c_int) Error!void {
    const rc = std.c.ioctl(fd, request, arg);
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        else => |err| return errnoToError(err),
    }
}

fn errnoError() Error {
    return errnoToError(@as(std.c.E, @enumFromInt(std.c._errno().*)));
}

fn errnoToError(err: anytype) Error {
    return switch (err) {
        .SUCCESS => error.Unexpected,
        .ACCES, .PERM => error.PermissionDenied,
        .BADF => error.InvalidFileDescriptor,
        .AGAIN => error.WouldBlock,
        .PIPE => error.BrokenPipe,
        .IO => error.InputOutput,
        .CHILD, .SRCH => error.ProcessNotFound,
        .MFILE, .NFILE, .NOMEM, .NOBUFS => error.SystemResources,
        else => error.Unexpected,
    };
}

const darwinTtyIoctl = struct {
    const get_window_size: c_int = @bitCast(@as(c_uint, 0x40087468));
    const set_window_size: c_int = @bitCast(@as(c_uint, 0x80087467));
    const set_controlling_tty: c_int = 0x20007461;
};

const bsdTtyIoctl = struct {
    const get_window_size: c_int = @bitCast(@as(c_uint, 0x40087468));
    const set_window_size: c_int = @bitCast(@as(c_uint, 0x80087467));
    const set_controlling_tty: c_int = 0x20007461;
};

fn statusToTerm(status: u32) std.process.Child.Term {
    return if (posix.W.IFEXITED(status))
        .{ .exited = posix.W.EXITSTATUS(status) }
    else if (posix.W.IFSIGNALED(status))
        .{ .signal = posix.W.TERMSIG(status) }
    else if (posix.W.IFSTOPPED(status))
        .{ .stopped = posix.W.STOPSIG(status) }
    else
        .{ .unknown = status };
}

const libcPty = if (uses_libc_pty) struct {
    extern "c" fn posix_openpt(flags: c_int) c_int;
    extern "c" fn grantpt(fd: c_int) c_int;
    extern "c" fn unlockpt(fd: c_int) c_int;
    extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
} else struct {
    fn posix_openpt(flags: c_int) c_int {
        _ = flags;
        unreachable;
    }

    fn grantpt(fd: c_int) c_int {
        _ = fd;
        unreachable;
    }

    fn unlockpt(fd: c_int) c_int {
        _ = fd;
        unreachable;
    }

    fn ptsname(fd: c_int) ?[*:0]u8 {
        _ = fd;
        unreachable;
    }
};

test "size validation is strict enough for terminal layout" {
    try std.testing.expect((Size{}).isValid());
    try std.testing.expect(!(Size{ .rows = 0, .cols = 80 }).isValid());
    try std.testing.expect(!(Size{ .rows = 24, .cols = 0 }).isValid());
}

test "default shell path is a stable absolute fallback" {
    try std.testing.expectEqualStrings("/bin/sh", std.mem.sliceTo(defaultShellPath(), 0));
}

test "default envp is explicit and empty" {
    const envp = defaultEnvp();
    try std.testing.expect(envp[0] == null);
}

test "unsupported targets fail explicitly" {
    if (supported) return error.SkipZigTest;

    try std.testing.expectError(error.UnsupportedOperatingSystem, openPair(.{}));
    try std.testing.expectError(error.UnsupportedOperatingSystem, setWindowSize(invalid_fd, .{}));
    try std.testing.expectError(error.UnsupportedOperatingSystem, spawnShell(.{}));
}

test "close helpers invalidate descriptors before reuse" {
    if (!supported) return error.SkipZigTest;

    var pair = Pair{};
    pair.closeSlave();
    try std.testing.expectEqual(invalid_fd, pair.slave_fd);
    pair.close();
    try std.testing.expectEqual(invalid_fd, pair.master_fd);
    try std.testing.expectEqual(invalid_fd, pair.slave_fd);

    var session = Session{ .child_pid = 0 };
    session.closeMaster();
    try std.testing.expectEqual(invalid_fd, session.master_fd);
}

test "window size rejects invalid descriptors before ioctl" {
    if (!supported) return error.SkipZigTest;

    try std.testing.expectError(error.InvalidFileDescriptor, setWindowSize(invalid_fd, .{}));
    try std.testing.expectError(error.InvalidFileDescriptor, queryWindowSize(invalid_fd));
}

test "open flag bit conversion keeps read-write intent" {
    if (!supported) return error.SkipZigTest;

    const flags = openFlags();
    try std.testing.expect(flags.NOCTTY);
    try std.testing.expect(flags.CLOEXEC);
    try std.testing.expect(flags.ACCMODE == .RDWR);
    try std.testing.expect(openFlagsBits(flags) != 0);
}

test "wait status maps common POSIX outcomes" {
    if (!supported) return error.SkipZigTest;

    try std.testing.expectEqual(@as(u8, 7), statusToTerm(7 << 8).exited);
    try std.testing.expectEqual(posix.SIG.INT, statusToTerm(@intFromEnum(posix.SIG.INT)).signal);
}

test "public API declarations compile on POSIX targets" {
    if (!supported) return error.SkipZigTest;

    comptime std.testing.refAllDecls(@This());
}
