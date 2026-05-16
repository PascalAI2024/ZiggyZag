const std = @import("std");
const desktop_config = @import("config.zig");
const integration = @import("integration.zig");
const terminal = @import("terminal.zig");
const theme = @import("theme.zig");

const Allocator = std.mem.Allocator;
const win = std.os.windows;

const BOOL = i32;
const BYTE = u8;
const DWORD = u32;
const UINT = u32;
const WORD = u16;
const WCHAR = u16;
const LONG = i32;
const LPARAM = isize;
const WPARAM = usize;
const LRESULT = isize;
const HRESULT = i32;
const COLORREF = u32;
const HANDLE = win.HANDLE;
const HWND = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const HFONT = ?*anyopaque;
const HGDIOBJ = ?*anyopaque;
const HDC = ?*anyopaque;
const HMENU = ?*anyopaque;
const HGLOBAL = ?*anyopaque;
const HPCON = HANDLE;
const LPVOID = ?*anyopaque;
const LPCVOID = ?*const anyopaque;
const LPWSTR = [*:0]WCHAR;
const LPCWSTR = [*:0]const WCHAR;

const WM_DESTROY = 0x0002;
const WM_PAINT = 0x000F;
const WM_SIZE = 0x0005;
const WM_CHAR = 0x0102;
const WM_KEYDOWN = 0x0100;
const WM_SETFOCUS = 0x0007;
const WM_KILLFOCUS = 0x0008;
const WM_CLOSE = 0x0010;
const WM_MOUSEWHEEL = 0x020A;
const VK_C = 0x43;
const VK_T = 0x54;
const VK_V = 0x56;
const VK_INSERT = 0x2D;
const VK_CONTROL = 0x11;
const VK_SHIFT = 0x10;
const VK_OEM_COMMA = 0xBC;
const VK_LEFT = 0x25;
const VK_UP = 0x26;
const VK_RIGHT = 0x27;
const VK_DOWN = 0x28;
const VK_HOME = 0x24;
const VK_END = 0x23;
const VK_DELETE = 0x2E;
const VK_PRIOR = 0x21;
const VK_NEXT = 0x22;
const CS_HREDRAW = 0x0002;
const CS_VREDRAW = 0x0001;
const CW_USEDEFAULT = -2147483648;
const WS_OVERLAPPEDWINDOW = 0x00CF0000;
const WS_VISIBLE = 0x10000000;
const SW_SHOW = 5;
const COLOR_WINDOW = 5;
const IDC_IBEAM = 32513;
const IDI_APPLICATION = 32512;
const TRANSPARENT = 1;
const OPAQUE = 2;
const FW_NORMAL = 400;
const DEFAULT_CHARSET = 1;
const OUT_DEFAULT_PRECIS = 0;
const CLIP_DEFAULT_PRECIS = 0;
const CLEARTYPE_QUALITY = 5;
const FIXED_PITCH = 1;
const FF_MODERN = 48;
const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
const CREATE_NO_WINDOW: DWORD = 0x08000000;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const CF_UNICODETEXT = 13;
const GMEM_MOVEABLE = 0x0002;
const WHEEL_DELTA = 120;
const MAX_PASTE_BYTES = 64 * 1024;
const WAIT_TIMEOUT: DWORD = 0x00000102;
const CHILD_SHUTDOWN_GRACE_MS: DWORD = 750;
const CHILD_SHUTDOWN_KILL_GRACE_MS: DWORD = 250;

const COORD = extern struct {
    X: i16,
    Y: i16,
};

const RECT = extern struct {
    left: LONG,
    top: LONG,
    right: LONG,
    bottom: LONG,
};

const POINT = extern struct {
    x: LONG,
    y: LONG,
};

const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]BYTE,
};

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: HICON,
};

const TEXTMETRICW = extern struct {
    tmHeight: LONG,
    tmAscent: LONG,
    tmDescent: LONG,
    tmInternalLeading: LONG,
    tmExternalLeading: LONG,
    tmAveCharWidth: LONG,
    tmMaxCharWidth: LONG,
    tmWeight: LONG,
    tmOverhang: LONG,
    tmDigitizedAspectX: LONG,
    tmDigitizedAspectY: LONG,
    tmFirstChar: WCHAR,
    tmLastChar: WCHAR,
    tmDefaultChar: WCHAR,
    tmBreakChar: WCHAR,
    tmItalic: BYTE,
    tmUnderlined: BYTE,
    tmStruckOut: BYTE,
    tmPitchAndFamily: BYTE,
    tmCharSet: BYTE,
};

const STARTUPINFOEXW = extern struct {
    StartupInfo: win.STARTUPINFOW,
    lpAttributeList: LPVOID,
};

extern "kernel32" fn CreatePipe(read_pipe: *HANDLE, write_pipe: *HANDLE, attrs: ?*win.SECURITY_ATTRIBUTES, size: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(file: HANDLE, buffer: LPVOID, bytes_to_read: DWORD, bytes_read: *DWORD, overlapped: LPVOID) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(file: HANDLE, buffer: LPCVOID, bytes_to_write: DWORD, bytes_written: *DWORD, overlapped: LPVOID) callconv(.winapi) BOOL;
extern "kernel32" fn PeekNamedPipe(file: HANDLE, buffer: LPVOID, buffer_size: DWORD, bytes_read: ?*DWORD, total_available: ?*DWORD, bytes_left_this_message: ?*DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(milliseconds: DWORD) callconv(.winapi) void;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) HGLOBAL;
extern "kernel32" fn GlobalLock(memory: HGLOBAL) callconv(.winapi) LPVOID;
extern "kernel32" fn GlobalUnlock(memory: HGLOBAL) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalFree(memory: HGLOBAL) callconv(.winapi) HGLOBAL;
extern "kernel32" fn SetEnvironmentVariableW(name: LPCWSTR, value: ?LPCWSTR) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn TerminateProcess(handle: HANDLE, exit_code: UINT) callconv(.winapi) BOOL;
extern "kernel32" fn CreatePseudoConsole(size: COORD, input: HANDLE, output: HANDLE, flags: DWORD, pseudoconsole: *HPCON) callconv(.winapi) HRESULT;
extern "kernel32" fn ResizePseudoConsole(pseudoconsole: HPCON, size: COORD) callconv(.winapi) HRESULT;
extern "kernel32" fn ClosePseudoConsole(pseudoconsole: HPCON) callconv(.winapi) void;
extern "kernel32" fn InitializeProcThreadAttributeList(list: LPVOID, count: DWORD, flags: DWORD, size: *usize) callconv(.winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(list: LPVOID, flags: DWORD, attribute: usize, value: LPVOID, size: usize, previous: LPVOID, return_size: ?*usize) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(list: LPVOID) callconv(.winapi) void;
extern "kernel32" fn CreateProcessW(app_name: ?LPCWSTR, command_line: ?LPWSTR, proc_attrs: ?*win.SECURITY_ATTRIBUTES, thread_attrs: ?*win.SECURITY_ATTRIBUTES, inherit_handles: BOOL, flags: DWORD, environment: ?[*:0]const WCHAR, cwd: ?LPCWSTR, startup_info: *win.STARTUPINFOW, process_info: *win.PROCESS.INFORMATION) callconv(.winapi) BOOL;

extern "user32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) HINSTANCE;
extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) WORD;
extern "user32" fn CreateWindowExW(ex_style: DWORD, class_name: LPCWSTR, window_name: LPCWSTR, style: DWORD, x: i32, y: i32, width: i32, height: i32, parent: HWND, menu: HMENU, instance: HINSTANCE, param: LPVOID) callconv(.winapi) HWND;
extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(hwnd: HWND, cmd_show: i32) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetMessageW(msg: *MSG, hwnd: HWND, min: UINT, max: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(exit_code: i32) callconv(.winapi) void;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(instance: HINSTANCE, cursor_name: LPCWSTR) callconv(.winapi) HCURSOR;
extern "user32" fn LoadIconW(instance: HINSTANCE, icon_name: LPCWSTR) callconv(.winapi) HICON;
extern "user32" fn BeginPaint(hwnd: HWND, paint: *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(hwnd: HWND, paint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn InvalidateRect(hwnd: HWND, rect: ?*const RECT, erase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn SetWindowTextW(hwnd: HWND, text: LPCWSTR) callconv(.winapi) BOOL;
extern "user32" fn CreateCaret(hwnd: HWND, bitmap: HGDIOBJ, width: i32, height: i32) callconv(.winapi) BOOL;
extern "user32" fn SetCaretPos(x: i32, y: i32) callconv(.winapi) BOOL;
extern "user32" fn ShowCaret(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn HideCaret(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DestroyCaret() callconv(.winapi) BOOL;
extern "user32" fn GetKeyState(virt_key: i32) callconv(.winapi) i16;
extern "user32" fn OpenClipboard(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn GetClipboardData(format: UINT) callconv(.winapi) HGLOBAL;
extern "user32" fn SetClipboardData(format: UINT, memory: HGLOBAL) callconv(.winapi) HGLOBAL;

extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(.winapi) HBRUSH;
extern "gdi32" fn DeleteObject(object: HGDIOBJ) callconv(.winapi) BOOL;
extern "gdi32" fn FillRect(dc: HDC, rect: *const RECT, brush: HBRUSH) callconv(.winapi) i32;
extern "gdi32" fn CreateFontW(height: i32, width: i32, escapement: i32, orientation: i32, weight: i32, italic: DWORD, underline: DWORD, strikeout: DWORD, charset: DWORD, out_precision: DWORD, clip_precision: DWORD, quality: DWORD, pitch_and_family: DWORD, face: LPCWSTR) callconv(.winapi) HFONT;
extern "gdi32" fn SelectObject(dc: HDC, object: HGDIOBJ) callconv(.winapi) HGDIOBJ;
extern "gdi32" fn SetTextColor(dc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
extern "gdi32" fn SetBkColor(dc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
extern "gdi32" fn SetBkMode(dc: HDC, mode: i32) callconv(.winapi) i32;
extern "gdi32" fn TextOutW(dc: HDC, x: i32, y: i32, text: [*]const WCHAR, count: i32) callconv(.winapi) BOOL;
extern "gdi32" fn GetTextMetricsW(dc: HDC, metrics: *TEXTMETRICW) callconv(.winapi) BOOL;

var global_app: ?*App = null;

const Status = struct {
    ready: bool = false,
    cwd: [260]u8 = undefined,
    cwd_len: usize = 0,
    last_status: ?u8 = null,
    last_duration_ms: ?i64 = null,
    commands: usize = 0,

    fn setCwd(self: *Status, cwd: []const u8) void {
        const len = @min(cwd.len, self.cwd.len);
        @memcpy(self.cwd[0..len], cwd[0..len]);
        self.cwd_len = len;
    }

    fn cwdSlice(self: *const Status) []const u8 {
        return self.cwd[0..self.cwd_len];
    }
};

const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinLock) void {
        while (!self.state.tryLock()) {}
    }

    fn unlock(self: *SpinLock) void {
        self.state.unlock();
    }
};

const App = struct {
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    hwnd: HWND = null,
    grid: terminal.Grid,
    mutex: SpinLock = .{},
    config: desktop_config.Config = .{},
    config_buffer: ?[]u8 = null,
    config_path: [320]u8 = undefined,
    config_path_len: usize = 0,
    config_error: [128]u8 = undefined,
    config_error_len: usize = 0,
    selected_theme: theme.Theme = theme.ziggy,
    font: HFONT = null,
    bg_brush: HBRUSH = null,
    panel_brush: HBRUSH = null,
    cursor_brush: HBRUSH = null,
    char_width: i32 = 9,
    char_height: i32 = 18,
    status_height: i32 = 28,
    input_write: ?HANDLE = null,
    output_read: ?HANDLE = null,
    pseudoconsole: ?HPCON = null,
    process_info: ?win.PROCESS.INFORMATION = null,
    status: Status = .{},
    scroll_offset: usize = 0,
    wheel_remainder: i32 = 0,
    startup_error: [96]u8 = undefined,
    startup_error_len: usize = 0,
    focused: bool = false,
    settings_open: bool = false,
    running: bool = true,

    fn init(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map) !App {
        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .grid = try terminal.Grid.init(allocator, 100, 32),
        };
    }

    fn loadDesktopConfig(self: *App) void {
        const path = self.desktopConfigPathAlloc() catch |err| {
            self.setConfigError(err);
            return;
        };
        defer self.allocator.free(path);
        self.setConfigPath(path);

        const file = if (std.fs.path.isAbsolute(path))
            std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => return,
                else => {
                    self.setConfigError(err);
                    return;
                },
            }
        else
            std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => return,
                else => {
                    self.setConfigError(err);
                    return;
                },
            };
        defer file.close(self.io);

        var read_buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(self.io, &read_buffer);
        const contents = reader.interface.allocRemaining(self.allocator, .limited(64 * 1024)) catch |err| {
            self.setConfigError(err);
            return;
        };
        errdefer self.allocator.free(contents);

        const parsed = desktop_config.parse(contents) catch |err| {
            self.setConfigError(err);
            self.allocator.free(contents);
            return;
        };

        if (self.config_buffer) |old| self.allocator.free(old);
        self.config_buffer = contents;
        self.config = parsed;
        self.selected_theme = parsed.selected_theme;
        self.status_height = if (parsed.options.show_status_bar) 28 else 0;
    }

    fn desktopConfigPathAlloc(self: *App) ![]u8 {
        if (self.env.get("ZIGGYZAG_DESKTOP_CONFIG")) |path| return try self.allocator.dupe(u8, path);
        if (self.env.get("APPDATA")) |appdata| return try std.fs.path.join(self.allocator, &.{ appdata, "ZiggyZag", "desktop.conf" });
        const home = self.env.get("HOME") orelse self.env.get("USERPROFILE") orelse ".";
        return try std.fs.path.join(self.allocator, &.{ home, ".config", "ziggyzag", "desktop.conf" });
    }

    fn deinit(self: *App) void {
        self.shutdownPty();
        if (self.font) |font| _ = DeleteObject(@ptrCast(font));
        if (self.bg_brush) |brush| _ = DeleteObject(@ptrCast(brush));
        if (self.panel_brush) |brush| _ = DeleteObject(@ptrCast(brush));
        if (self.cursor_brush) |brush| _ = DeleteObject(@ptrCast(brush));
        if (self.config_buffer) |buffer| self.allocator.free(buffer);
        self.grid.deinit();
    }

    fn setConfigPath(self: *App, path: []const u8) void {
        const len = @min(path.len, self.config_path.len);
        @memcpy(self.config_path[0..len], path[0..len]);
        self.config_path_len = len;
    }

    fn configPathSlice(self: *const App) []const u8 {
        return self.config_path[0..self.config_path_len];
    }

    fn setConfigError(self: *App, err: anyerror) void {
        const name = @errorName(err);
        const len = @min(name.len, self.config_error.len);
        @memcpy(self.config_error[0..len], name[0..len]);
        self.config_error_len = len;
    }

    fn configErrorSlice(self: *const App) []const u8 {
        return self.config_error[0..self.config_error_len];
    }

    fn setupGdi(self: *App) !void {
        self.rebuildThemeBrushes();
        const font_name = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, self.config.font.family);
        defer self.allocator.free(font_name);
        const font_height = -@as(i32, @intCast(self.config.font.size + 2));
        self.font = CreateFontW(
            font_height,
            0,
            0,
            0,
            FW_NORMAL,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            FIXED_PITCH | FF_MODERN,
            font_name.ptr,
        );
    }

    fn rebuildThemeBrushes(self: *App) void {
        if (self.bg_brush) |brush| _ = DeleteObject(@ptrCast(brush));
        if (self.panel_brush) |brush| _ = DeleteObject(@ptrCast(brush));
        if (self.cursor_brush) |brush| _ = DeleteObject(@ptrCast(brush));
        self.bg_brush = CreateSolidBrush(toColorRef(self.selected_theme.background));
        self.panel_brush = CreateSolidBrush(toColorRef(self.selected_theme.panel));
        self.cursor_brush = CreateSolidBrush(toColorRef(self.selected_theme.cursor));
    }

    fn startPty(self: *App) !void {
        const shell_path = try self.resolveShellPath();
        defer self.allocator.free(shell_path);

        var pty_input_read: HANDLE = undefined;
        var app_input_write: HANDLE = undefined;
        var app_output_read: HANDLE = undefined;
        var pty_output_write: HANDLE = undefined;

        if (CreatePipe(&pty_input_read, &app_input_write, null, 0) == 0) return error.CreateInputPipeFailed;
        errdefer _ = CloseHandle(pty_input_read);
        errdefer _ = CloseHandle(app_input_write);
        if (CreatePipe(&app_output_read, &pty_output_write, null, 0) == 0) return error.CreateOutputPipeFailed;
        errdefer _ = CloseHandle(app_output_read);
        errdefer _ = CloseHandle(pty_output_write);

        var hpc: HPCON = undefined;
        const size = COORD{ .X = @intCast(@min(self.grid.width, 300)), .Y = @intCast(@min(self.grid.height, 120)) };
        if (failed(CreatePseudoConsole(size, pty_input_read, pty_output_write, 0, &hpc))) return error.CreatePseudoConsoleFailed;
        self.pseudoconsole = hpc;
        errdefer {
            ClosePseudoConsole(hpc);
            self.pseudoconsole = null;
        }

        const command_line = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, shell_path);
        defer self.allocator.free(command_line);
        const cwd = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd);
        const cwd_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, cwd);
        defer self.allocator.free(cwd_w);

        _ = SetEnvironmentVariableW(wideLiteral("ZIGGYZAG_APP"), wideLiteral("1"));
        _ = SetEnvironmentVariableW(wideLiteral("ZIGGYZAG_INTEGRATION"), wideLiteral("1"));
        _ = SetEnvironmentVariableW(wideLiteral("TERM"), wideLiteral("xterm-256color"));

        var attr_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        const attr_list = try self.allocator.alloc(u8, attr_size);
        defer self.allocator.free(attr_list);
        if (InitializeProcThreadAttributeList(attr_list.ptr, 1, 0, &attr_size) == 0) return error.InitializeAttributeListFailed;
        defer DeleteProcThreadAttributeList(attr_list.ptr);
        var hpc_value = hpc;
        if (UpdateProcThreadAttribute(attr_list.ptr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, @ptrCast(&hpc_value), @sizeOf(HPCON), null, null) == 0) {
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
            EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW,
            null,
            cwd_w.ptr,
            &startup.StartupInfo,
            &process_info,
        ) == 0) return error.CreateProcessFailed;

        _ = CloseHandle(pty_input_read);
        _ = CloseHandle(pty_output_write);
        self.input_write = app_input_write;
        self.output_read = app_output_read;
        self.process_info = process_info;

        const thread = try std.Thread.spawn(.{}, readLoop, .{self});
        thread.detach();
    }

    fn resolveShellPath(self: *App) ![]u8 {
        if (self.env.get("ZIGGYZAG_SHELL_PATH")) |path| return try self.allocator.dupe(u8, path);

        const exe_dir = std.process.executableDirPathAlloc(self.io, self.allocator) catch null;
        if (exe_dir) |dir| {
            defer self.allocator.free(dir);
            if (try self.existingJoined(&.{ dir, "bin", "ziggyzag.exe" })) |path| return path;
            if (try self.existingJoined(&.{ dir, "ziggyzag.exe" })) |path| return path;
        }

        const candidates = [_][]const u8{
            "zig-out/bin/ziggyzag.exe",
            "ziggyzag.exe",
        };
        for (candidates) |candidate| {
            std.Io.Dir.cwd().access(self.io, candidate, .{}) catch continue;
            return try self.allocator.dupe(u8, candidate);
        }
        return error.ShellBinaryNotFound;
    }

    fn existingJoined(self: *App, parts: []const []const u8) !?[]u8 {
        const candidate = try std.fs.path.join(self.allocator, parts);
        errdefer self.allocator.free(candidate);
        if (std.fs.path.isAbsolute(candidate)) {
            std.Io.Dir.accessAbsolute(self.io, candidate, .{}) catch {
                self.allocator.free(candidate);
                return null;
            };
            return candidate;
        }
        std.Io.Dir.cwd().access(self.io, candidate, .{}) catch {
            self.allocator.free(candidate);
            return null;
        };
        return candidate;
    }

    fn shutdownPty(self: *App) void {
        self.running = false;
        if (self.input_write) |handle| {
            _ = CloseHandle(handle);
            self.input_write = null;
        }
        if (self.output_read) |handle| {
            _ = CloseHandle(handle);
            self.output_read = null;
        }
        if (self.pseudoconsole) |hpc| {
            ClosePseudoConsole(hpc);
            self.pseudoconsole = null;
        }
        if (self.process_info) |info| {
            if (WaitForSingleObject(info.hProcess, CHILD_SHUTDOWN_GRACE_MS) == WAIT_TIMEOUT) {
                _ = TerminateProcess(info.hProcess, 0);
                _ = WaitForSingleObject(info.hProcess, CHILD_SHUTDOWN_KILL_GRACE_MS);
            }
            _ = CloseHandle(info.hThread);
            _ = CloseHandle(info.hProcess);
            self.process_info = null;
        }
    }

    fn writeInput(self: *App, bytes: []const u8) void {
        const handle = self.input_write orelse return;
        var written: DWORD = 0;
        _ = WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null);
    }

    fn visibleTextAlloc(self: *App) ![]u8 {
        if (self.scroll_offset > 0) {
            var lines: std.ArrayList([]u8) = .empty;
            defer lines.deinit(self.allocator);

            const history_len = self.grid.historyLen();
            const height = self.grid.height;
            const history_start = if (history_len > height + self.scroll_offset) history_len - height - self.scroll_offset else 0;
            var row: usize = 0;
            while (row < height and history_start + row < history_len) : (row += 1) {
                const line = try self.grid.historyLineTextAlloc(self.allocator, history_start + row);
                lines.append(self.allocator, line) catch |err| {
                    self.allocator.free(line);
                    return err;
                };
            }

            defer {
                for (lines.items) |line| self.allocator.free(line);
            }

            var last = lines.items.len;
            while (last > 0 and lines.items[last - 1].len == 0) : (last -= 1) {}

            var total: usize = 0;
            for (lines.items[0..last], 0..) |line, index| {
                total += line.len;
                if (index + 1 < last) total += 2;
            }

            const text = try self.allocator.alloc(u8, total);
            var offset: usize = 0;
            for (lines.items[0..last], 0..) |line, index| {
                @memcpy(text[offset .. offset + line.len], line);
                offset += line.len;
                if (index + 1 < last) {
                    text[offset] = '\r';
                    text[offset + 1] = '\n';
                    offset += 2;
                }
            }
            return text;
        }

        return self.grid.visibleTextAlloc(self.allocator);
    }

    fn copyVisibleText(self: *App, hwnd: HWND) void {
        self.mutex.lock();
        const text = self.visibleTextAlloc() catch {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();
        defer self.allocator.free(text);
        if (text.len == 0) return;
        setClipboardText(hwnd, self.allocator, text) catch return;
    }

    fn pasteClipboardText(self: *App, hwnd: HWND) void {
        const text = getClipboardText(hwnd, self.allocator) catch return;
        defer self.allocator.free(text);

        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(self.allocator);
        var index: usize = 0;
        while (index < text.len) : (index += 1) {
            if (text[index] == '\r') {
                if (index + 1 < text.len and text[index + 1] == '\n') index += 1;
                normalized.append(self.allocator, '\n') catch return;
            } else {
                if (text[index] != 0) normalized.append(self.allocator, text[index]) catch return;
            }
            if (normalized.items.len >= MAX_PASTE_BYTES) break;
        }
        if (normalized.items.len == 0) return;
        self.resetScroll();
        self.writeInput(normalized.items);
    }

    fn resetScroll(self: *App) void {
        self.scroll_offset = 0;
        self.wheel_remainder = 0;
    }

    fn clampScroll(self: *App) void {
        const history_len = self.grid.historyLen();
        if (self.scroll_offset > history_len) self.scroll_offset = history_len;
        if (self.scroll_offset == 0) self.wheel_remainder = 0;
    }

    fn scrollBy(self: *App, lines: i32) void {
        if (lines > 0) {
            const amount: usize = @intCast(lines);
            self.scroll_offset = @min(self.scroll_offset + amount, self.grid.historyLen());
        } else if (lines < 0) {
            const amount: usize = @intCast(-lines);
            self.scroll_offset = if (amount >= self.scroll_offset) 0 else self.scroll_offset - amount;
        }
        self.clampScroll();
    }

    fn handleMouseWheel(self: *App, hwnd: HWND, wparam: WPARAM) void {
        const delta = mouseWheelDelta(wparam);
        self.wheel_remainder += delta;
        const lines = @divTrunc(self.wheel_remainder, WHEEL_DELTA) * 3;
        self.wheel_remainder = @rem(self.wheel_remainder, WHEEL_DELTA);
        if (lines != 0) {
            self.mutex.lock();
            self.scrollBy(lines);
            self.mutex.unlock();
            self.updateCaret(hwnd);
            _ = InvalidateRect(hwnd, null, 0);
        }
    }

    fn resizeForClient(self: *App, rect: RECT) void {
        const width_px = @max(rect.right - rect.left, 1);
        const height_px = @max(rect.bottom - rect.top - self.status_height, self.char_height);
        const cols: usize = @intCast(@max(@divTrunc(width_px, @max(self.char_width, 1)), 20));
        const rows: usize = @intCast(@max(@divTrunc(height_px, @max(self.char_height, 1)), 5));

        self.mutex.lock();
        defer self.mutex.unlock();
        self.grid.resize(cols, rows) catch return;
        self.resetScroll();
        if (self.pseudoconsole) |hpc| {
            _ = ResizePseudoConsole(hpc, .{ .X = @intCast(@min(cols, 300)), .Y = @intCast(@min(rows, 120)) });
        }
    }

    fn setStartupError(self: *App, err: anyerror) void {
        const name = @errorName(err);
        const len = @min(name.len, self.startup_error.len);
        @memcpy(self.startup_error[0..len], name[0..len]);
        self.startup_error_len = len;
    }

    fn paint(self: *App, hdc: HDC, rect: RECT) void {
        _ = FillRect(hdc, &rect, self.bg_brush);
        if (self.font) |font| _ = SelectObject(hdc, @ptrCast(font));
        _ = SetBkMode(hdc, TRANSPARENT);
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.foreground));

        var metrics: TEXTMETRICW = undefined;
        if (GetTextMetricsW(hdc, &metrics) != 0) {
            self.char_width = @max(metrics.tmAveCharWidth, 6);
            self.char_height = @max(metrics.tmHeight + metrics.tmExternalLeading, 12);
        }

        self.mutex.lock();
        const width = self.grid.width;
        const height = self.grid.height;
        const cursor_x = self.grid.cursor_x;
        const cursor_y = self.grid.cursor_y;
        self.clampScroll();
        const scroll_offset = self.scroll_offset;
        const history_len = self.grid.historyLen();
        const history_start = if (history_len > height + scroll_offset) history_len - height - scroll_offset else 0;
        var row: usize = 0;
        while (row < height) : (row += 1) {
            const y = 8 + @as(i32, @intCast(row)) * self.char_height;
            if (y >= rect.bottom - self.status_height) break;
            if (scroll_offset > 0) {
                const history_index = history_start + row;
                if (history_index < history_len) {
                    const line = self.grid.history.items[history_index];
                    self.paintCellRun(hdc, line.cells[0..@min(line.width, width)], y);
                }
            } else {
                const line = self.grid.cells[row * width .. (row + 1) * width];
                self.paintCellRun(hdc, line, y);
            }
        }
        const status = self.status;
        const focused = self.focused;
        const startup_error_len = self.startup_error_len;
        var startup_error: [96]u8 = undefined;
        if (startup_error_len > 0) @memcpy(startup_error[0..startup_error_len], self.startup_error[0..startup_error_len]);
        self.mutex.unlock();

        const terminal_bottom = rect.bottom - self.status_height;
        if (scroll_offset == 0 and focused) {
            var caret_rect = RECT{
                .left = 10 + @as(i32, @intCast(cursor_x)) * self.char_width,
                .top = 8 + @as(i32, @intCast(cursor_y)) * self.char_height,
                .right = 10 + @as(i32, @intCast(cursor_x + 1)) * self.char_width,
                .bottom = 8 + @as(i32, @intCast(cursor_y + 1)) * self.char_height,
            };
            if (caret_rect.top < terminal_bottom) {
                caret_rect.bottom = @min(caret_rect.bottom, terminal_bottom);
                _ = FillRect(hdc, &caret_rect, self.cursor_brush);
            }
        }

        if (startup_error_len > 0) {
            self.paintStartupMessage(hdc, rect, startup_error[0..startup_error_len]);
        }
        self.paintScrollIndicator(hdc, rect, scroll_offset, history_len);
        if (self.status_height > 0) self.paintStatus(hdc, rect, status, scroll_offset, history_len);
        if (self.settings_open) self.paintSettingsOverlay(hdc, rect);
    }

    fn paintCellRun(self: *App, hdc: HDC, cells: []const terminal.Cell, y: i32) void {
        const end = visibleCellEnd(cells);
        var col: usize = 0;
        while (col < end) {
            const style = cells[col].style;
            var run_end = col + 1;
            while (run_end < end and styleEql(style, cells[run_end].style)) : (run_end += 1) {}

            const background = styleBackground(self.selected_theme, style);
            var run_rect = RECT{
                .left = 10 + @as(i32, @intCast(col)) * self.char_width,
                .top = y,
                .right = 10 + @as(i32, @intCast(run_end)) * self.char_width,
                .bottom = y + self.char_height,
            };
            const run_brush = CreateSolidBrush(toColorRef(background));
            if (run_brush) |brush| {
                _ = FillRect(hdc, &run_rect, brush);
                _ = DeleteObject(@ptrCast(brush));
            }

            _ = SetTextColor(hdc, toColorRef(styleForeground(self.selected_theme, style)));
            _ = SetBkMode(hdc, TRANSPARENT);

            var offset = col;
            while (offset < run_end) {
                var wide: [512]WCHAR = undefined;
                const chunk = @min(run_end - offset, wide.len);
                var index: usize = 0;
                while (index < chunk) : (index += 1) {
                    wide[index] = cells[offset + index].ch;
                }
                _ = TextOutW(
                    hdc,
                    10 + @as(i32, @intCast(offset)) * self.char_width,
                    y,
                    &wide,
                    @intCast(chunk),
                );
                offset += chunk;
            }
            col = run_end;
        }
        _ = SetBkMode(hdc, TRANSPARENT);
    }

    fn paintStartupMessage(self: *App, hdc: HDC, rect: RECT, error_name: []const u8) void {
        const x = 20;
        const terminal_bottom = rect.bottom - self.status_height;
        const block_height = self.char_height * 3 + 16;
        const preferred_y = @max(@divTrunc(rect.bottom - rect.top, 3), 48);
        const max_y = @max(12, terminal_bottom - block_height - 10);
        var y: i32 = @min(preferred_y, max_y);
        const max_width = @max(rect.right - x - 16, 20);
        _ = SetBkMode(hdc, TRANSPARENT);
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.accent));
        drawUtf8TextFitted(hdc, x, y, "ZiggyZag shell is not running", max_width, self.char_width);
        y += self.char_height + 8;
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.foreground));
        if (y < terminal_bottom) drawUtf8TextFitted(hdc, x, y, "Build it with `zig build`, or set ZIGGYZAG_SHELL_PATH to a shell executable.", max_width, self.char_width);
        y += self.char_height + 4;
        var detail: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&detail, "Startup error: {s}", .{error_name}) catch "Startup error";
        if (y < terminal_bottom) drawUtf8TextFitted(hdc, x, y, text, max_width, self.char_width);
    }

    fn paintScrollIndicator(self: *App, hdc: HDC, rect: RECT, scroll_offset: usize, history_len: usize) void {
        if (history_len == 0) return;
        const top = rect.top + 8;
        const bottom = rect.bottom - self.status_height - 8;
        const track_height = bottom - top;
        if (track_height < 32) return;

        var track = RECT{ .left = rect.right - 7, .top = top, .right = rect.right - 4, .bottom = bottom };
        const track_brush = CreateSolidBrush(toColorRef(scaleColor(self.selected_theme.muted, 55)));
        if (track_brush) |brush| {
            _ = FillRect(hdc, &track, brush);
            _ = DeleteObject(@ptrCast(brush));
        }

        const thumb_height = @max(@divTrunc(track_height, 5), 24);
        const usable = @max(track_height - thumb_height, 1);
        const safe_history: i32 = @intCast(@min(history_len, @as(usize, 100000)));
        const safe_offset: i32 = @intCast(@min(scroll_offset, @as(usize, 100000)));
        const travel = if (safe_history == 0) 0 else @divTrunc(usable * safe_offset, safe_history);
        var thumb = RECT{
            .left = rect.right - 9,
            .top = bottom - thumb_height - travel,
            .right = rect.right - 2,
            .bottom = bottom - travel,
        };
        const thumb_brush = CreateSolidBrush(toColorRef(if (scroll_offset > 0) self.selected_theme.accent else self.selected_theme.cursor));
        if (thumb_brush) |brush| {
            _ = FillRect(hdc, &thumb, brush);
            _ = DeleteObject(@ptrCast(brush));
        }
    }

    fn paintStatus(self: *App, hdc: HDC, rect: RECT, status: Status, scroll_offset: usize, history_len: usize) void {
        var panel = RECT{ .left = rect.left, .top = rect.bottom - self.status_height, .right = rect.right, .bottom = rect.bottom };
        _ = FillRect(hdc, &panel, self.panel_brush);
        _ = SetBkMode(hdc, TRANSPARENT);
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.accent));
        var status_text: [512]u8 = undefined;
        var duration_text: [64]u8 = undefined;
        const cwd = if (status.cwd_len > 0) status.cwdSlice() else "starting shell";
        const duration = if (status.last_duration_ms) |ms| std.fmt.bufPrint(&duration_text, "{d}ms", .{ms}) catch "n/a" else "n/a";
        const wide_layout = rect.right - rect.left > 920;
        const shortcuts = "Ctrl+C int | Ctrl+Shift+C copy | Ctrl+V paste | Ctrl+, settings | Ctrl+Shift+T theme";
        const text = if (wide_layout)
            (std.fmt.bufPrint(&status_text, "ZiggyZag  |  {s}  |  commands:{d}  |  status:{s}  |  last:{s}{s}  |  {s}", .{
                cwd,
                status.commands,
                if (status.last_status) |value| statusName(value) else "waiting",
                duration,
                if (scroll_offset > 0) "  |  scrollback" else if (history_len > 0) "  |  history ready" else "",
                shortcuts,
            }) catch "ZiggyZag")
        else
            (std.fmt.bufPrint(&status_text, "ZiggyZag  |  status:{s}  |  {s}{s}", .{
                if (status.last_status) |value| statusName(value) else "waiting",
                "Ctrl+Shift+C copy | Ctrl+V paste",
                if (scroll_offset > 0) "  |  scrollback" else "",
            }) catch "ZiggyZag");
        drawUtf8TextFitted(hdc, 10, rect.bottom - self.status_height + 7, text, rect.right - rect.left - 20, self.char_width);
    }

    fn paintSettingsOverlay(self: *App, hdc: HDC, rect: RECT) void {
        const available_width = @max(rect.right - rect.left - 48, 280);
        const panel_width = @min(available_width, 760);
        const left = rect.right - panel_width - 24;
        const top: i32 = 24;
        const bottom_limit = rect.bottom - self.status_height - 12;
        const desired_height = self.char_height * 18 + 48;
        const bottom = @min(bottom_limit, top + desired_height);
        if (bottom <= top + self.char_height * 4) return;

        var panel = RECT{ .left = left, .top = top, .right = rect.right - 24, .bottom = bottom };
        _ = FillRect(hdc, &panel, self.panel_brush);
        var accent_line = RECT{ .left = panel.left, .top = panel.top, .right = panel.right, .bottom = panel.top + 3 };
        const accent_brush = CreateSolidBrush(toColorRef(self.selected_theme.accent));
        if (accent_brush) |brush| {
            _ = FillRect(hdc, &accent_line, brush);
            _ = DeleteObject(@ptrCast(brush));
        }

        _ = SetBkMode(hdc, TRANSPARENT);
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.foreground));
        const text_x = panel.left + 14;
        var y = panel.top + 14;
        const max_width = panel.right - text_x - 14;

        drawUtf8TextFitted(hdc, text_x, y, "Settings", max_width, self.char_width);
        y += self.char_height + 8;

        var line: [512]u8 = undefined;
        const theme_text = std.fmt.bufPrint(&line, "Theme: {s}  ({s})", .{ self.selected_theme.name, self.selected_theme.id }) catch "Theme";
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.accent));
        drawUtf8TextFitted(hdc, text_x, y, theme_text, max_width, self.char_width);
        y += self.char_height + 4;

        _ = SetTextColor(hdc, toColorRef(self.selected_theme.foreground));
        const font_text = std.fmt.bufPrint(&line, "Font: {s} {d}px", .{ self.config.font.family, self.config.font.size }) catch "Font";
        drawUtf8TextFitted(hdc, text_x, y, font_text, max_width, self.char_width);
        y += self.char_height + 4;

        const status_text = std.fmt.bufPrint(&line, "Status bar: {s}    Bell: {s}    Smooth scroll: {s}", .{
            if (self.config.options.show_status_bar) "on" else "off",
            if (self.config.options.bell) "on" else "off",
            if (self.config.options.smooth_scroll) "on" else "off",
        }) catch "Status";
        drawUtf8TextFitted(hdc, text_x, y, status_text, max_width, self.char_width);
        y += self.char_height + 4;

        const path = if (self.config_path_len > 0) self.configPathSlice() else "%APPDATA%\\ZiggyZag\\desktop.conf";
        const config_text = std.fmt.bufPrint(&line, "Config: {s}", .{path}) catch "Config";
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.muted));
        drawUtf8TextFitted(hdc, text_x, y, config_text, max_width, self.char_width);
        y += self.char_height + 4;

        if (self.config_error_len > 0) {
            const error_text = std.fmt.bufPrint(&line, "Config error: {s}", .{self.configErrorSlice()}) catch "Config error";
            _ = SetTextColor(hdc, toColorRef(self.selected_theme.ansi[1]));
            drawUtf8TextFitted(hdc, text_x, y, error_text, max_width, self.char_width);
            y += self.char_height + 6;
        } else {
            y += 6;
        }

        _ = SetTextColor(hdc, toColorRef(self.selected_theme.foreground));
        drawUtf8TextFitted(hdc, text_x, y, "Built-in themes", max_width, self.char_width);
        y += self.char_height + 6;

        const columns: i32 = if (panel_width > 560) 2 else 1;
        const column_width = @divTrunc(max_width, columns);
        var index: usize = 0;
        while (index < theme.themes.len) : (index += 1) {
            const col: i32 = @intCast(index % @as(usize, @intCast(columns)));
            const row: i32 = @intCast(index / @as(usize, @intCast(columns)));
            const option_x = text_x + col * column_width;
            const option_y = y + row * (self.char_height + 7);
            if (option_y + self.char_height >= bottom - self.char_height * 2) break;
            self.paintThemeOption(hdc, theme.themes[index], option_x, option_y, column_width - 10);
        }

        _ = SetTextColor(hdc, toColorRef(self.selected_theme.muted));
        drawUtf8TextFitted(hdc, text_x, bottom - self.char_height - 12, "Ctrl+Shift+T cycles theme. Ctrl+, toggles this panel. Edit desktop.conf to persist.", max_width, self.char_width);
    }

    fn paintThemeOption(self: *App, hdc: HDC, preset: theme.Theme, x: i32, y: i32, max_width: i32) void {
        const swatch_size = @max(@min(self.char_height - 3, 14), 8);
        var bg = RECT{ .left = x, .top = y + 2, .right = x + swatch_size, .bottom = y + 2 + swatch_size };
        var accent = RECT{ .left = x + swatch_size + 3, .top = y + 2, .right = x + swatch_size * 2 + 3, .bottom = y + 2 + swatch_size };

        const bg_brush = CreateSolidBrush(toColorRef(preset.background));
        if (bg_brush) |brush| {
            _ = FillRect(hdc, &bg, brush);
            _ = DeleteObject(@ptrCast(brush));
        }
        const accent_brush = CreateSolidBrush(toColorRef(preset.accent));
        if (accent_brush) |brush| {
            _ = FillRect(hdc, &accent, brush);
            _ = DeleteObject(@ptrCast(brush));
        }

        const is_current = std.mem.eql(u8, preset.id, self.selected_theme.id);
        _ = SetTextColor(hdc, toColorRef(if (is_current) self.selected_theme.accent else self.selected_theme.foreground));
        drawUtf8TextFitted(hdc, x + swatch_size * 2 + 10, y, preset.name, @max(max_width - swatch_size * 2 - 10, 20), self.char_width);
    }

    fn updateCaret(self: *App, hwnd: HWND) void {
        if (!self.focused) return;
        self.mutex.lock();
        const cursor_x = self.grid.cursor_x;
        const cursor_y = self.grid.cursor_y;
        const scroll_offset = self.scroll_offset;
        self.mutex.unlock();

        if (scroll_offset > 0) {
            _ = HideCaret(hwnd);
            return;
        }
        const x = 10 + @as(i32, @intCast(cursor_x)) * self.char_width;
        const y = @max(0, 8 + @as(i32, @intCast(cursor_y)) * self.char_height);
        _ = SetCaretPos(x, y);
        _ = ShowCaret(hwnd);
    }

    fn handleEvents(self: *App, events: []const integration.Event) void {
        for (events) |event| {
            switch (event.kind) {
                .session_ready => self.status.ready = true,
                .prompt_rendered => {
                    if (integration.jsonStringValue(event.payload, "cwd")) |cwd| self.status.setCwd(cwd);
                    if (integration.jsonIntValue(u8, event.payload, "last_status")) |value| self.status.last_status = value;
                    if (integration.jsonIntValue(i64, event.payload, "last_duration_ms")) |value| self.status.last_duration_ms = value;
                },
                .command_started => {
                    self.status.commands += 1;
                    if (integration.jsonStringValue(event.payload, "cwd")) |cwd| self.status.setCwd(cwd);
                },
                .command_finished => {
                    if (integration.jsonStringValue(event.payload, "cwd")) |cwd| self.status.setCwd(cwd);
                    if (integration.jsonIntValue(u8, event.payload, "status")) |value| self.status.last_status = value;
                    if (integration.jsonIntValue(i64, event.payload, "duration_ms")) |value| self.status.last_duration_ms = value;
                },
                .unknown => {},
            }
        }
    }

    fn updateTitle(self: *App) void {
        const hwnd = self.hwnd orelse return;
        var title: [512]u8 = undefined;
        const cwd = if (self.status.cwd_len > 0) self.status.cwdSlice() else "starting";
        const state = if (self.startup_error_len > 0) "needs setup" else if (!self.status.ready) "starting" else if (self.status.last_status) |value| statusName(value) else "ready";
        const text = std.fmt.bufPrint(&title, "ZiggyZag - {s} - {s}", .{ cwd, state }) catch "ZiggyZag";
        var wide: [512]WCHAR = undefined;
        const len = utf8ToWide(text, &wide);
        wide[len] = 0;
        _ = SetWindowTextW(hwnd, @ptrCast(&wide));
    }
};

pub fn run(init_data: std.process.Init) !void {
    const allocator = init_data.gpa;
    var app = try allocator.create(App);
    app.* = try App.init(allocator, init_data.io, init_data.environ_map);
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    app.loadDesktopConfig();
    try app.setupGdi();
    global_app = app;
    defer global_app = null;

    const instance = GetModuleHandleW(null);
    const class_name = wideLiteral("ZiggyZagDesktopWindow");
    const wc = WNDCLASSEXW{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = CS_HREDRAW | CS_VREDRAW,
        .lpfnWndProc = windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = @ptrFromInt(COLOR_WINDOW + 1),
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (RegisterClassExW(&wc) == 0) return error.RegisterWindowClassFailed;

    const hwnd = CreateWindowExW(
        0,
        class_name,
        wideLiteral("ZiggyZag"),
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        1120,
        760,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    app.hwnd = hwnd;
    app.updateTitle();
    _ = ShowWindow(hwnd, SW_SHOW);
    _ = UpdateWindow(hwnd);

    var rect: RECT = undefined;
    if (GetClientRect(hwnd, &rect) != 0) app.resizeForClient(rect);
    app.startPty() catch |err| {
        app.mutex.lock();
        defer app.mutex.unlock();
        app.setStartupError(err);
        app.grid.feed("\x1b[2J");
        app.grid.feed("ZiggyZag shell could not start.\n");
        app.grid.feed("Run `zig build`, or set ZIGGYZAG_SHELL_PATH to a shell executable.\n");
        app.grid.feed("Error: ");
        app.grid.feed(@errorName(err));
        app.grid.feed("\n");
        app.updateTitle();
        _ = InvalidateRect(hwnd, null, 0);
    };

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

fn readLoop(app: *App) void {
    var buffer: [8192]u8 = undefined;
    while (app.running) {
        const handle = app.output_read orelse break;
        var available: DWORD = 0;
        if (PeekNamedPipe(handle, null, 0, null, &available, null) == 0) break;
        if (available == 0) {
            Sleep(16);
            continue;
        }

        var read: DWORD = 0;
        const requested: DWORD = @intCast(@min(buffer.len, available));
        if (ReadFile(handle, &buffer, requested, &read, null) == 0 or read == 0) break;

        var extracted = integration.extract(std.heap.page_allocator, buffer[0..read]) catch continue;
        defer extracted.deinit(std.heap.page_allocator);

        app.mutex.lock();
        app.resetScroll();
        app.grid.feed(extracted.display);
        app.handleEvents(extracted.events.items);
        app.updateTitle();
        app.mutex.unlock();

        if (app.hwnd) |hwnd| _ = InvalidateRect(hwnd, null, 0);
    }
}

fn windowProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const app = global_app orelse return DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        WM_CLOSE => {
            app.shutdownPty();
            _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_DESTROY => {
            app.shutdownPty();
            PostQuitMessage(0);
            return 0;
        },
        WM_SETFOCUS => {
            app.focused = true;
            _ = CreateCaret(hwnd, null, @max(app.char_width, 2), @max(app.char_height, 12));
            app.updateCaret(hwnd);
            _ = InvalidateRect(hwnd, null, 0);
            return 0;
        },
        WM_KILLFOCUS => {
            app.focused = false;
            _ = HideCaret(hwnd);
            _ = DestroyCaret();
            _ = InvalidateRect(hwnd, null, 0);
            return 0;
        },
        WM_SIZE => {
            var rect: RECT = undefined;
            if (GetClientRect(hwnd, &rect) != 0) app.resizeForClient(rect);
            app.updateCaret(hwnd);
            _ = InvalidateRect(hwnd, null, 0);
            return 0;
        },
        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            const hdc = BeginPaint(hwnd, &ps);
            var rect: RECT = undefined;
            _ = GetClientRect(hwnd, &rect);
            app.paint(hdc, rect);
            app.updateCaret(hwnd);
            _ = EndPaint(hwnd, &ps);
            return 0;
        },
        WM_MOUSEWHEEL => {
            app.handleMouseWheel(hwnd, wparam);
            return 0;
        },
        WM_CHAR => {
            handleChar(app, wparam);
            return 0;
        },
        WM_KEYDOWN => {
            if (handleKey(app, hwnd, wparam)) return 0;
        },
        else => {},
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn handleChar(app: *App, wparam: WPARAM) void {
    const char: u21 = @intCast(wparam);
    switch (char) {
        '\r' => app.writeInput("\n"),
        0x08 => app.writeInput(&.{0x7f}),
        0x03, 0x16 => {},
        else => {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(char, &buf) catch return;
            app.writeInput(buf[0..len]);
        },
    }
}

fn handleKey(app: *App, hwnd: HWND, wparam: WPARAM) bool {
    if (keyDown(VK_CONTROL) and wparam == VK_OEM_COMMA) {
        app.settings_open = !app.settings_open;
        _ = InvalidateRect(hwnd, null, 0);
        return true;
    }
    if (keyDown(VK_CONTROL) and keyDown(VK_SHIFT) and wparam == VK_T) {
        app.selected_theme = theme.next(app.selected_theme);
        app.config.selected_theme = app.selected_theme;
        app.rebuildThemeBrushes();
        _ = InvalidateRect(hwnd, null, 0);
        return true;
    }
    if (keyDown(VK_CONTROL) and keyDown(VK_SHIFT) and wparam == VK_C) {
        app.copyVisibleText(hwnd);
        return true;
    }
    if (keyDown(VK_CONTROL) and wparam == VK_C) {
        app.writeInput(&.{0x03});
        return true;
    }
    if ((keyDown(VK_CONTROL) and wparam == VK_V) or (keyDown(VK_SHIFT) and wparam == VK_INSERT)) {
        app.pasteClipboardText(hwnd);
        return true;
    }

    switch (wparam) {
        VK_UP => app.writeInput("\x1b[A"),
        VK_DOWN => app.writeInput("\x1b[B"),
        VK_RIGHT => app.writeInput("\x1b[C"),
        VK_LEFT => app.writeInput("\x1b[D"),
        VK_HOME => app.writeInput("\x1b[H"),
        VK_END => app.writeInput("\x1b[F"),
        VK_DELETE => app.writeInput("\x1b[3~"),
        VK_PRIOR => app.writeInput("\x1b[5~"),
        VK_NEXT => app.writeInput("\x1b[6~"),
        else => return false,
    }
    return true;
}

fn keyDown(virt_key: i32) bool {
    return (@as(u16, @bitCast(GetKeyState(virt_key))) & 0x8000) != 0;
}

fn mouseWheelDelta(wparam: WPARAM) i32 {
    const high_word: u16 = @intCast((wparam >> 16) & 0xffff);
    return @as(i32, @as(i16, @bitCast(high_word)));
}

fn getClipboardText(hwnd: HWND, allocator: Allocator) ![]u8 {
    if (OpenClipboard(hwnd) == 0) return error.OpenClipboardFailed;
    defer _ = CloseClipboard();

    const memory = GetClipboardData(CF_UNICODETEXT) orelse return error.ClipboardTextUnavailable;
    const locked = GlobalLock(memory) orelse return error.LockClipboardFailed;
    defer _ = GlobalUnlock(memory);

    const wide: [*:0]const WCHAR = @ptrCast(@alignCast(locked));
    var len: usize = 0;
    while (wide[len] != 0) : (len += 1) {}
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..len]);
}

fn setClipboardText(hwnd: HWND, allocator: Allocator, text: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
    defer allocator.free(wide);

    const bytes = (wide.len + 1) * @sizeOf(WCHAR);
    const memory = GlobalAlloc(GMEM_MOVEABLE, bytes) orelse return error.AllocClipboardFailed;
    var owns_memory = true;
    defer {
        if (owns_memory) _ = GlobalFree(memory);
    }

    const locked = GlobalLock(memory) orelse return error.LockClipboardFailed;
    const dest: [*]WCHAR = @ptrCast(@alignCast(locked));
    @memcpy(dest[0..wide.len], wide);
    dest[wide.len] = 0;
    _ = GlobalUnlock(memory);

    if (OpenClipboard(hwnd) == 0) return error.OpenClipboardFailed;
    defer _ = CloseClipboard();
    if (EmptyClipboard() == 0) return error.EmptyClipboardFailed;
    if (SetClipboardData(CF_UNICODETEXT, memory) == null) return error.SetClipboardFailed;
    owns_memory = false;
}

fn drawUtf8Text(hdc: HDC, x: i32, y: i32, text: []const u8) void {
    var wide: [512]WCHAR = undefined;
    const len = utf8ToWide(text, &wide);
    if (len > 0) _ = TextOutW(hdc, x, y, &wide, @intCast(len));
}

fn drawUtf8TextFitted(hdc: HDC, x: i32, y: i32, text: []const u8, max_width: i32, char_width: i32) void {
    if (max_width <= 0) return;
    const max_chars: usize = @intCast(@max(@divTrunc(max_width, @max(char_width, 1)), 1));
    if (text.len <= max_chars) {
        drawUtf8Text(hdc, x, y, text);
        return;
    }

    var clipped: [512]u8 = undefined;
    const limit = @min(max_chars, clipped.len);
    if (limit <= 3) {
        @memset(clipped[0..limit], '.');
        drawUtf8Text(hdc, x, y, clipped[0..limit]);
        return;
    }

    const prefix_len = @min(text.len, limit - 3);
    @memcpy(clipped[0..prefix_len], text[0..prefix_len]);
    @memcpy(clipped[prefix_len .. prefix_len + 3], "...");
    drawUtf8Text(hdc, x, y, clipped[0 .. prefix_len + 3]);
}

fn visibleCellEnd(cells: []const terminal.Cell) usize {
    var end = cells.len;
    while (end > 0) : (end -= 1) {
        const cell = cells[end - 1];
        if (cell.ch != ' ' or !styleIsDefault(cell.style)) break;
    }
    return end;
}

fn styleIsDefault(style: terminal.Style) bool {
    return !style.bold and !style.dim and style.fg == .default and style.bg == .default;
}

fn styleEql(left: terminal.Style, right: terminal.Style) bool {
    return left.bold == right.bold and
        left.dim == right.dim and
        left.fg == right.fg and
        left.bg == right.bg;
}

fn styleForeground(selected_theme: theme.Theme, style: terminal.Style) theme.Color {
    var color = terminalColor(selected_theme, style.fg) orelse selected_theme.foreground;
    if (style.dim) color = scaleColor(color, 65);
    if (style.bold and style.fg == .default) color = brightenColor(color);
    return color;
}

fn styleBackground(selected_theme: theme.Theme, style: terminal.Style) theme.Color {
    return terminalColor(selected_theme, style.bg) orelse selected_theme.background;
}

fn terminalColor(selected_theme: theme.Theme, color: terminal.Color) ?theme.Color {
    return switch (color) {
        .default => null,
        .black => selected_theme.ansi[0],
        .red => selected_theme.ansi[1],
        .green => selected_theme.ansi[2],
        .yellow => selected_theme.ansi[3],
        .blue => selected_theme.ansi[4],
        .magenta => selected_theme.ansi[5],
        .cyan => selected_theme.ansi[6],
        .white => selected_theme.ansi[7],
        .bright_black => selected_theme.ansi[8],
        .bright_red => selected_theme.ansi[9],
        .bright_green => selected_theme.ansi[10],
        .bright_yellow => selected_theme.ansi[11],
        .bright_blue => selected_theme.ansi[12],
        .bright_magenta => selected_theme.ansi[13],
        .bright_cyan => selected_theme.ansi[14],
        .bright_white => selected_theme.ansi[15],
    };
}

fn scaleColor(color: theme.Color, percent: u8) theme.Color {
    return theme.Color.rgb(
        @intCast(@divTrunc(@as(u16, color.r) * percent, 100)),
        @intCast(@divTrunc(@as(u16, color.g) * percent, 100)),
        @intCast(@divTrunc(@as(u16, color.b) * percent, 100)),
    );
}

fn brightenColor(color: theme.Color) theme.Color {
    return theme.Color.rgb(
        @intCast(@min(@as(u16, color.r) + 24, 255)),
        @intCast(@min(@as(u16, color.g) + 24, 255)),
        @intCast(@min(@as(u16, color.b) + 24, 255)),
    );
}

fn toColorRef(color: theme.Color) COLORREF {
    return @as(COLORREF, color.r) | (@as(COLORREF, color.g) << 8) | (@as(COLORREF, color.b) << 16);
}

fn failed(hr: HRESULT) bool {
    return hr < 0;
}

fn wideLiteral(comptime text: []const u8) LPCWSTR {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

fn utf8ToWide(text: []const u8, out: []WCHAR) usize {
    var written: usize = 0;
    var view = std.unicode.Utf8View.init(text) catch {
        for (text) |byte| {
            if (written >= out.len) break;
            out[written] = byte;
            written += 1;
        }
        return written;
    };
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0xffff) {
            if (written >= out.len) break;
            out[written] = @intCast(codepoint);
            written += 1;
        } else {
            if (written + 1 >= out.len) break;
            const value = codepoint - 0x10000;
            out[written] = @intCast(0xd800 + (value >> 10));
            out[written + 1] = @intCast(0xdc00 + (value & 0x3ff));
            written += 2;
        }
    }
    return written;
}

fn statusName(status: u8) []const u8 {
    return if (status == 0) "ok" else "failed";
}
