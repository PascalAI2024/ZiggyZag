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
    // Linux and macOS are the supported POSIX targets. The BSDs share the
    // libc PTY code path but are not built, linked, or tested, so they are
    // not advertised as supported.
    return switch (os_tag) {
        .linux, .macos => true,
        else => false,
    };
}

/// Comptime selection of the most capable backend for the build target.
pub fn currentBackend() Backend {
    return switch (builtin.os.tag) {
        .windows => .conpty_windows,
        .linux, .macos => .native_posix,
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
// Windows ConPTY backend
// ---------------------------------------------------------------------------
//
// Design rationale (Step 0, 2026-05-17):
//
// The reader thread stays in windows_app.zig because it mixes OS I/O with
// app-specific concerns: integration.Parser state, app.mutex, grid.feed,
// handleEvents, and PostMessageW(WM_APP_OUTPUT_READY).  Only the OS-level
// PeekNamedPipe/ReadFile call is PTY-shaped; the rest is app behavior.  The
// vtable's read_fn is non-blocking consumer-pulled (returns 0 on empty) which
// lets the Sleep(16) poll interval stay app-side where it belongs.
//
// ConPtyCtx owns: HPCON, input pipe (app writes → child reads),
// output pipe (child writes → app reads), PROCESS_INFORMATION.
// The per-pane reader thread and its join remain app-owned (windows_app.zig).

// Conditionally compile the Windows backend only on Windows targets.  On
// non-Windows hosts pty.zig is imported for its tests; the ConPTY struct
// and extern declarations must not appear because the types (HANDLE, HPCON,
// win.PROCESS.INFORMATION) either don't exist or import paths differ.
const conpty = if (builtin.os.tag == .windows) struct {
    const win = std.os.windows;

    // --- Win32 types ---------------------------------------------------------
    const BOOL = i32;
    const DWORD = u32;
    const HANDLE = win.HANDLE;
    const HPCON = HANDLE;
    const LPVOID = ?*anyopaque;
    const LPCVOID = ?*const anyopaque;
    const WCHAR = u16;
    const LPWSTR = [*:0]WCHAR;
    const LPCWSTR = [*:0]const WCHAR;

    const COORD = extern struct { X: i16, Y: i16 };

    // ConPTY / process creation flags -----------------------------------------
    const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
    /// Required so CreateProcessW interprets the env block as UTF-16, not ANSI.
    /// Diagnosed 2026-05-17 — see docs/reviews/2026-05-17-windows-debug.md.
    const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
    /// CREATE_NO_WINDOW must NOT appear here.  It forces the child to allocate
    /// its own conhost instead of attaching to our pseudoconsole, silently
    /// breaking the I/O bridge.  Diagnosed and fixed 2026-05-17.
    /// See docs/reviews/2026-05-17-windows-debug.md.
    const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
    const WAIT_TIMEOUT: DWORD = 0x00000102;
    const WAIT_OBJECT_0: DWORD = 0x00000000;
    const INFINITE: DWORD = 0xFFFFFFFF;
    const CHILD_SHUTDOWN_GRACE_MS: DWORD = 750;
    const CHILD_SHUTDOWN_KILL_GRACE_MS: DWORD = 250;

    // STARTUPINFOEXW ----------------------------------------------------------
    const STARTUPINFOEXW = extern struct {
        StartupInfo: win.STARTUPINFOW,
        lpAttributeList: LPVOID,
    };

    // --- Win32 externs -------------------------------------------------------
    extern "kernel32" fn CreatePipe(read_pipe: *HANDLE, write_pipe: *HANDLE, attrs: ?*win.SECURITY_ATTRIBUTES, size: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadFile(file: HANDLE, buffer: LPVOID, bytes_to_read: DWORD, bytes_read: *DWORD, overlapped: LPVOID) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(file: HANDLE, buffer: LPCVOID, bytes_to_write: DWORD, bytes_written: *DWORD, overlapped: LPVOID) callconv(.winapi) BOOL;
    extern "kernel32" fn PeekNamedPipe(file: HANDLE, buffer: LPVOID, buffer_size: DWORD, bytes_read: ?*DWORD, total_available: ?*DWORD, bytes_left_this_message: ?*DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn GetExitCodeProcess(handle: HANDLE, exit_code: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn TerminateProcess(handle: HANDLE, exit_code: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn CreatePseudoConsole(size: COORD, input: HANDLE, output: HANDLE, flags: DWORD, pseudoconsole: *HPCON) callconv(.winapi) i32;
    extern "kernel32" fn ResizePseudoConsole(pseudoconsole: HPCON, size: COORD) callconv(.winapi) i32;
    extern "kernel32" fn ClosePseudoConsole(pseudoconsole: HPCON) callconv(.winapi) void;
    extern "kernel32" fn InitializeProcThreadAttributeList(list: LPVOID, count: DWORD, flags: DWORD, size: *usize) callconv(.winapi) BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(list: LPVOID, flags: DWORD, attribute: usize, value: LPVOID, size: usize, previous: LPVOID, return_size: ?*usize) callconv(.winapi) BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(list: LPVOID) callconv(.winapi) void;
    extern "kernel32" fn CreateProcessW(app_name: ?LPCWSTR, command_line: ?LPWSTR, proc_attrs: ?*win.SECURITY_ATTRIBUTES, thread_attrs: ?*win.SECURITY_ATTRIBUTES, inherit_handles: BOOL, flags: DWORD, environment: ?[*:0]const WCHAR, cwd: ?LPCWSTR, startup_info: *win.STARTUPINFOW, process_info: *win.PROCESS.INFORMATION) callconv(.winapi) BOOL;

    fn failed(hr: i32) bool {
        return hr < 0;
    }

    // --- Context struct ------------------------------------------------------

    /// Heap-allocated context owned by the Pty vtable.  Freed in deinit_fn.
    pub const ConPtyCtx = struct {
        /// Write end of the input pipe: app → ConPTY → child stdin.
        input_write: HANDLE,
        /// Read end of the output pipe: child stdout → ConPTY → app.
        output_read: HANDLE,
        /// The pseudoconsole handle.
        pseudoconsole: HPCON,
        /// Child process and thread handles.
        process_info: win.PROCESS.INFORMATION,
        allocator: Allocator,
    };

    // --- VTable functions ----------------------------------------------------

    pub fn deinit_fn(ctx: ?*anyopaque) void {
        const self: *ConPtyCtx = @ptrCast(@alignCast(ctx.?));
        // Close the input write handle so the child's stdin sees EOF.
        _ = CloseHandle(self.input_write);
        // Close the pseudoconsole — signals the child's conhost to exit.
        ClosePseudoConsole(self.pseudoconsole);
        // Grace-period wait; terminate if the child hasn't exited.
        if (WaitForSingleObject(self.process_info.hProcess, CHILD_SHUTDOWN_GRACE_MS) == WAIT_TIMEOUT) {
            _ = TerminateProcess(self.process_info.hProcess, 0);
            _ = WaitForSingleObject(self.process_info.hProcess, CHILD_SHUTDOWN_KILL_GRACE_MS);
        }
        _ = CloseHandle(self.process_info.hThread);
        _ = CloseHandle(self.process_info.hProcess);
        // Close the output read handle after the child has exited so the
        // reader thread (app-side) sees EOF and exits cleanly.  The reader
        // thread join happens in windows_app.shutdownPane after deinit returns.
        _ = CloseHandle(self.output_read);
        self.allocator.destroy(self);
    }

    /// Non-blocking read.  Returns 0 when no bytes are currently available;
    /// returns error.EndOfStream when the output pipe has been broken/closed.
    pub fn read_fn(ctx: ?*anyopaque, buf: []u8) anyerror!usize {
        const self: *ConPtyCtx = @ptrCast(@alignCast(ctx.?));
        var available: DWORD = 0;
        if (PeekNamedPipe(self.output_read, null, 0, null, &available, null) == 0) return error.EndOfStream;
        if (available == 0) return 0;
        var bytes_read: DWORD = 0;
        const requested: DWORD = @intCast(@min(buf.len, available));
        if (ReadFile(self.output_read, buf.ptr, requested, &bytes_read, null) == 0 or bytes_read == 0) return error.EndOfStream;
        return @intCast(bytes_read);
    }

    pub fn write_fn(ctx: ?*anyopaque, bytes: []const u8) anyerror!usize {
        const self: *ConPtyCtx = @ptrCast(@alignCast(ctx.?));
        var written: DWORD = 0;
        if (WriteFile(self.input_write, bytes.ptr, @intCast(bytes.len), &written, null) == 0) return error.BrokenPipe;
        return @intCast(written);
    }

    pub fn resize_fn(ctx: ?*anyopaque, cols: u16, rows: u16) anyerror!void {
        const self: *ConPtyCtx = @ptrCast(@alignCast(ctx.?));
        // Clamp dimensions to ConPTY practical limits (same as the inline
        // ResizePseudoConsole call in the previous windows_app.zig:1623).
        const coord = COORD{
            .X = @intCast(@min(cols, 300)),
            .Y = @intCast(@min(rows, 120)),
        };
        _ = ResizePseudoConsole(self.pseudoconsole, coord);
    }

    /// Blocking wait for the child process to exit.  Returns the exit term.
    pub fn wait_fn(ctx: ?*anyopaque) anyerror!std.process.Child.Term {
        const self: *ConPtyCtx = @ptrCast(@alignCast(ctx.?));
        _ = WaitForSingleObject(self.process_info.hProcess, INFINITE);
        var exit_code: DWORD = 0;
        _ = GetExitCodeProcess(self.process_info.hProcess, &exit_code);
        return .{ .exited = @truncate(exit_code) };
    }

    const vtable: Pty.VTable = .{
        .deinit_fn = deinit_fn,
        .read_fn = read_fn,
        .write_fn = write_fn,
        .resize_fn = resize_fn,
        .wait_fn = wait_fn,
    };

    // --- spawnConPty ---------------------------------------------------------

    pub fn spawn(opts: Pty.SpawnOptions) !Pty {
        const allocator = opts.allocator;

        // Resolve the command line.  argv[0] is the executable; for Step 0
        // the caller always passes a single-element argv (the shell path).
        // We utf8→utf16 it directly rather than implementing full Win32
        // quoting, which is correct for the single-path case and keeps the
        // behaviour identical to the inline startPtyForPane that preceded
        // this function.
        if (opts.argv.len == 0) return error.EmptyArgv;
        const command_line = try std.unicode.utf8ToUtf16LeAllocZ(allocator, opts.argv[0]);
        defer allocator.free(command_line);

        // Resolve cwd (utf8 → utf16).
        const cwd_w: ?[:0]u16 = if (opts.cwd) |cwd| try std.unicode.utf8ToUtf16LeAllocZ(allocator, cwd) else null;
        defer if (cwd_w) |cw| allocator.free(cw);

        // Build the UTF-16 environment block.  The caller is responsible for
        // setting ZIGGYZAG_* keys in opts.env_map before calling spawn.
        const env_block = try opts.env_map.createWindowsBlock(allocator, .{});
        defer env_block.deinit(allocator);

        // Create the two anonymous pipes:
        //   pty_input_read  → handed to CreatePseudoConsole as the input source.
        //   app_input_write → app writes keystrokes here.
        //   app_output_read → app reads terminal output here.
        //   pty_output_write → handed to CreatePseudoConsole as the output sink.
        var pty_input_read: HANDLE = undefined;
        var app_input_write: HANDLE = undefined;
        if (CreatePipe(&pty_input_read, &app_input_write, null, 0) == 0) return error.CreateInputPipeFailed;
        errdefer _ = CloseHandle(pty_input_read);
        errdefer _ = CloseHandle(app_input_write);

        var app_output_read: HANDLE = undefined;
        var pty_output_write: HANDLE = undefined;
        if (CreatePipe(&app_output_read, &pty_output_write, null, 0) == 0) return error.CreateOutputPipeFailed;
        errdefer _ = CloseHandle(app_output_read);
        errdefer _ = CloseHandle(pty_output_write);

        // CreatePseudoConsole: wires pty_input_read and pty_output_write into
        // the headless conhost that backs the pseudoconsole.
        var hpc: HPCON = undefined;
        const size = COORD{
            .X = @intCast(@min(opts.cols, 300)),
            .Y = @intCast(@min(opts.rows, 120)),
        };
        if (failed(CreatePseudoConsole(size, pty_input_read, pty_output_write, 0, &hpc))) return error.CreatePseudoConsoleFailed;
        errdefer ClosePseudoConsole(hpc);

        // Build the process-thread attribute list with PSEUDOCONSOLE.
        //
        // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE takes the HPCON *value* as
        // lpValue, NOT a pointer-to-HPCON.  The MS "Creating a Pseudoconsole"
        // PrepareStartupInformation sample and Windows Terminal's
        // ConptyConnection both pass `hpc` directly.  The prior `&hpc_value`
        // form stalled the handshake.  Canonical form verified 2026-05-17.
        // See docs/reviews/2026-05-17-windows-debug.md.
        var attr_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        const attr_list = try allocator.alloc(u8, attr_size);
        defer allocator.free(attr_list);
        if (InitializeProcThreadAttributeList(attr_list.ptr, 1, 0, &attr_size) == 0) return error.InitializeAttributeListFailed;
        defer DeleteProcThreadAttributeList(attr_list.ptr);
        if (UpdateProcThreadAttribute(attr_list.ptr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, @ptrCast(hpc), @sizeOf(HPCON), null, null) == 0) {
            return error.UpdateAttributeListFailed;
        }

        var startup: STARTUPINFOEXW = std.mem.zeroes(STARTUPINFOEXW);
        startup.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        startup.lpAttributeList = attr_list.ptr;

        var process_info: win.PROCESS.INFORMATION = undefined;
        if (CreateProcessW(
            null,
            command_line.ptr,
            null,
            null,
            0,
            // CREATE_NO_WINDOW must NOT be set here.  It is a console-allocation
            // flag incompatible with PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: the
            // child allocates its own hidden conhost and our pseudoconsole bridge
            // produces no I/O, even though CreateProcessW returns success.  The
            // pseudoconsole already runs the child headless; no window appears.
            // Diagnosed and fixed 2026-05-17.
            // See docs/reviews/2026-05-17-windows-debug.md.
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
            env_block.view().ptr,
            if (cwd_w) |cw| cw.ptr else null,
            &startup.StartupInfo,
            &process_info,
        ) == 0) return error.CreateProcessFailed;
        errdefer {
            if (WaitForSingleObject(process_info.hProcess, CHILD_SHUTDOWN_GRACE_MS) == WAIT_TIMEOUT) {
                _ = TerminateProcess(process_info.hProcess, 0);
                _ = WaitForSingleObject(process_info.hProcess, CHILD_SHUTDOWN_KILL_GRACE_MS);
            }
            _ = CloseHandle(process_info.hThread);
            _ = CloseHandle(process_info.hProcess);
        }

        // Close the pipe ends that belong to the pseudoconsole side — the
        // HPCON has duplicated them internally; keeping our copies open would
        // prevent EOF detection on the app_output_read side.
        _ = CloseHandle(pty_input_read);
        _ = CloseHandle(pty_output_write);

        const ctx = try allocator.create(ConPtyCtx);
        ctx.* = .{
            .input_write = app_input_write,
            .output_read = app_output_read,
            .pseudoconsole = hpc,
            .process_info = process_info,
            .allocator = allocator,
        };
        return Pty{ .ctx = ctx, .vtable = &vtable };
    }
} else struct {
    // On non-Windows targets this namespace is empty; spawnConPty is never
    // called (currentBackend() never returns .conpty_windows), but the
    // compiler still needs the symbol to exist.
    pub const ConPtyCtx = void;
};

fn spawnConPty(opts: Pty.SpawnOptions) !Pty {
    if (builtin.os.tag != .windows) return error.NotImplemented;
    return conpty.spawn(opts);
}

// ---------------------------------------------------------------------------
// POSIX native backend (Wave 3)
// ---------------------------------------------------------------------------
//
// Design notes (vtable contract vs ConPty):
//
// read_fn — non-blocking, matching ConPty semantics exactly:
//   return 0   : no data currently available (ConPty: PeekNamedPipe avail==0)
//   return N>0 : N bytes written into buf
//   EndOfStream: fd closed / child exited (ConPty: PeekNamedPipe fails or
//                ReadFile returns 0 bytes)
//   Implementation: master_fd is set O_NONBLOCK after openPair; readFd's
//   WouldBlock → 0, InputOutput (Linux EIO on slave close) → EndOfStream,
//   return-0 from readFd (macOS on slave close) → EndOfStream.
//
// write_fn — delegates to posix_pty.writeAll; returns bytes.len on success.
//
// resize_fn — delegates to Session.resize (setWindowSize via TIOCSWINSZ).
//
// wait_fn — blocking: spins waitNoHang with a 10 ms nanosleep per iteration,
//   consistent with ConPty's INFINITE WaitForSingleObject.
//
// deinit_fn — closes master fd, then reaps child via waitNoHang loop.
//
// argv/envp ownership: C-style sentinel arrays are allocated from
// opts.allocator in the parent; freed immediately after spawnShell returns
// (fork has already duplicated the address space; the child exec'd).

const native_posix = if (builtin.os.tag != .windows) struct {
    /// Heap-allocated context owned by the Pty vtable.  Freed in deinit_fn.
    pub const NativePosixCtx = struct {
        session: posix.Session,
        allocator: Allocator,
    };

    // Set O_NONBLOCK on an fd using posix.system.fcntl, following the
    // canonical std pattern from std/Io/Threaded.zig.
    fn setNonBlock(fd: posix.Fd) !void {
        const sys = std.posix.system;
        const p = std.posix;
        // GETFL: pass 0 as arg; result is the current flags as usize.
        var flags: usize = fl: {
            while (true) {
                const rc = sys.fcntl(fd, p.F.GETFL, @as(usize, 0));
                switch (p.errno(rc)) {
                    .SUCCESS => break :fl @intCast(rc),
                    .INTR => continue,
                    else => return error.Unexpected,
                }
            }
        };
        flags |= @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
        while (true) {
            switch (p.errno(sys.fcntl(fd, p.F.SETFL, flags))) {
                .SUCCESS => return,
                .INTR => continue,
                else => return error.Unexpected,
            }
        }
    }

    // Sleep ~10 ms without libc dependency.
    // Mirrors posix_pty.zig's linux/libc split: linux syscall path for Linux
    // (project does NOT link libc on Linux), std.c path for macOS/BSD.
    fn sleepShort() void {
        switch (builtin.os.tag) {
            .linux => {
                const ts = std.os.linux.timespec{ .sec = 0, .nsec = 10_000_000 };
                _ = std.os.linux.nanosleep(&ts, null);
            },
            .macos, .freebsd, .netbsd, .openbsd => {
                const ts = std.c.timespec{ .sec = 0, .nsec = 10_000_000 };
                _ = std.c.nanosleep(&ts, null);
            },
            else => {},
        }
    }

    pub fn deinit_fn(ctx: ?*anyopaque) void {
        const self: *NativePosixCtx = @ptrCast(@alignCast(ctx.?));
        // Close the master side — signals the child via SIGHUP.
        self.session.closeMaster();
        // Reap the child so it does not become a zombie.
        while (true) {
            const term = posix.waitNoHang(self.session.child_pid) catch break;
            if (term != null) break;
            sleepShort();
        }
        self.allocator.destroy(self);
    }

    /// Non-blocking read.  Returns 0 when no data is available;
    /// returns error.EndOfStream when the master fd has been closed/drained.
    pub fn read_fn(ctx: ?*anyopaque, buf: []u8) anyerror!usize {
        const self: *NativePosixCtx = @ptrCast(@alignCast(ctx.?));
        const n = posix.readFd(self.session.master_fd, buf) catch |err| switch (err) {
            // On Linux, read(master) returns EIO when the slave side is closed.
            // Map to EndOfStream to match ConPty's broken-pipe behaviour.
            error.InputOutput => return error.EndOfStream,
            // O_NONBLOCK: no data ready right now — return 0 (matches ConPty
            // PeekNamedPipe avail==0 path).
            error.WouldBlock => return 0,
            else => return err,
        };
        // On macOS, read(master) returns 0 bytes when the slave side closes.
        if (n == 0) return error.EndOfStream;
        return n;
    }

    pub fn write_fn(ctx: ?*anyopaque, bytes: []const u8) anyerror!usize {
        const self: *NativePosixCtx = @ptrCast(@alignCast(ctx.?));
        try posix.writeAll(self.session.master_fd, bytes);
        return bytes.len;
    }

    pub fn resize_fn(ctx: ?*anyopaque, cols: u16, rows: u16) anyerror!void {
        const self: *NativePosixCtx = @ptrCast(@alignCast(ctx.?));
        try self.session.resize(.{ .cols = cols, .rows = rows });
    }

    /// Blocking wait for the child to exit.  Spins waitNoHang + 10 ms sleep.
    pub fn wait_fn(ctx: ?*anyopaque) anyerror!std.process.Child.Term {
        const self: *NativePosixCtx = @ptrCast(@alignCast(ctx.?));
        while (true) {
            if (try posix.waitNoHang(self.session.child_pid)) |term| return term;
            sleepShort();
        }
    }

    const vtable: Pty.VTable = .{
        .deinit_fn = deinit_fn,
        .read_fn = read_fn,
        .write_fn = write_fn,
        .resize_fn = resize_fn,
        .wait_fn = wait_fn,
    };

    pub fn spawn(opts: Pty.SpawnOptions) !Pty {
        if (opts.argv.len == 0) return error.EmptyArgv;

        const allocator = opts.allocator;

        // --- Build NUL-terminated C argv array ---
        // Each opts.argv element is a []const u8 Zig slice — not NUL-terminated.
        // dupeZ allocates a NUL-terminated copy of each string so execve reads
        // correct boundaries.  All copies are freed in the parent after fork.
        const c_argv = try allocator.allocSentinel(?[*:0]const u8, opts.argv.len, null);
        @memset(c_argv, null); // ensure defer is safe if dupeZ fails mid-loop
        defer {
            for (c_argv) |entry| {
                if (entry) |p| allocator.free(std.mem.span(p));
            }
            allocator.free(c_argv);
        }
        for (opts.argv, 0..) |arg, i| {
            const z = try allocator.dupeZ(u8, arg);
            c_argv[i] = z.ptr;
        }
        // argv[0] is the shell path (same sentinel-terminated copy).
        const shell_z: [*:0]const u8 = c_argv[0].?;

        // --- Build C envp array from opts.env_map ---
        const env_block = try opts.env_map.createPosixBlock(allocator, .{});
        defer env_block.deinit(allocator);
        // env_block.slice is [:null]const ?[*:0]const u8; reinterpret as
        // the sentinel-pointer type that posix_pty.SpawnOptions.envp expects.
        const c_envp: [*:null]const ?[*:0]const u8 = env_block.slice.ptr;

        // --- Build NUL-terminated cwd if provided ---
        const cwd_z: ?[:0]u8 = if (opts.cwd) |cwd|
            try allocator.dupeZ(u8, cwd)
        else
            null;
        defer if (cwd_z) |cz| allocator.free(cz);

        // --- Spawn the shell ---
        const session = try posix.spawnShell(.{
            .shell_path = shell_z,
            .argv = @ptrCast(c_argv.ptr),
            .envp = c_envp,
            .size = .{ .cols = opts.cols, .rows = opts.rows },
            .cwd = if (cwd_z) |cz| cz.ptr else null,
        });

        // Set master_fd non-blocking so read_fn returns 0 when no data is
        // available, matching ConPty's PeekNamedPipe non-blocking contract.
        setNonBlock(session.master_fd) catch {};

        const ctx = try allocator.create(NativePosixCtx);
        ctx.* = .{
            .session = session,
            .allocator = allocator,
        };
        return Pty{ .ctx = ctx, .vtable = &vtable };
    }
} else struct {
    // On Windows this namespace is empty; spawnNativePosix is never called
    // (currentBackend() never returns .native_posix on Windows).
    pub const NativePosixCtx = void;
};

fn spawnNativePosix(opts: Pty.SpawnOptions) !Pty {
    // On Windows targets spawnNativePosix is a stub — the Windows ConPTY
    // backend handles all PTY operations there.  The wired implementation
    // lives in the `native_posix` namespace above and is compiled only for
    // non-Windows targets.
    //
    // NOTE: The unit test "posix backend stubs return NotImplemented" asserts
    // this returns error.NotImplemented when run on the Windows host, which
    // is correct.  POSIX runtime behaviour (real fork/execve over /dev/ptmx,
    // O_NONBLOCK semantics, EIO-on-EOF) can only be validated on Linux/macOS
    // by the user.
    if (builtin.os.tag == .windows) return error.NotImplemented;
    return native_posix.spawn(opts);
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
    try std.testing.expect(!isPosixPtyTarget(.freebsd));
    try std.testing.expect(!isPosixPtyTarget(.netbsd));
    try std.testing.expect(!isPosixPtyTarget(.openbsd));
    try std.testing.expect(!isPosixPtyTarget(.windows));
}

test "currentBackend resolves per OS tag" {
    const backend = currentBackend();
    switch (builtin.os.tag) {
        .windows => try std.testing.expectEqual(Backend.conpty_windows, backend),
        .linux, .macos => {
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

test "posix backend stubs return NotImplemented" {
    // spawnConPty is now a real implementation on Windows; only the POSIX
    // stubs are guaranteed to return NotImplemented on all platforms.
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

    // `spawnNativePosix` only returns NotImplemented on Windows; on POSIX it
    // delegates to the real fork/execve implementation, whose runtime behaviour
    // cannot be validated in CI. `spawnScriptPosix`/`spawnDirectPosix` remain
    // genuine stubs that return NotImplemented on every platform.
    if (builtin.os.tag == .windows) {
        try std.testing.expectError(error.NotImplemented, spawnNativePosix(opts));
    }
    try std.testing.expectError(error.NotImplemented, spawnScriptPosix(opts));
    try std.testing.expectError(error.NotImplemented, spawnDirectPosix(opts));
}
