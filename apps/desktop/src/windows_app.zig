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
const WM_APP_OUTPUT_READY = 0x8000;
const VK_A = 0x41;
const VK_C = 0x43;
const VK_D = 0x44;
const VK_E = 0x45;
const VK_F = 0x46;
const VK_N = 0x4E;
const VK_O = 0x4F;
const VK_P = 0x50;
const VK_R = 0x52;
const VK_T = 0x54;
const VK_V = 0x56;
const VK_W = 0x57;
const VK_INSERT = 0x2D;
const VK_ESCAPE = 0x1B;
const VK_RETURN = 0x0D;
const VK_BACK = 0x08;
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
const AGENT_TRANSCRIPT_BYTES = 12 * 1024;
const AGENT_PENDING_WRITE_BYTES = 1024;
const WAIT_TIMEOUT: DWORD = 0x00000102;
const CHILD_SHUTDOWN_GRACE_MS: DWORD = 750;
const CHILD_SHUTDOWN_KILL_GRACE_MS: DWORD = 250;
const MAX_PANES = 6;
const MIN_PANE_COLS = 20;
const MIN_PANE_ROWS = 5;
const PANE_PAD_X: i32 = 10;
const PANE_PAD_Y: i32 = 8;

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

const PaneRect = RECT;

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
extern "user32" fn PostMessageW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
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
    project_kind: [32]u8 = undefined,
    project_kind_len: usize = 0,
    git_branch: [96]u8 = undefined,
    git_branch_len: usize = 0,
    git_staged: usize = 0,
    git_changed: usize = 0,
    git_untracked: usize = 0,
    git_conflicts: usize = 0,
    git_ahead: usize = 0,
    git_behind: usize = 0,
    last_status: ?u8 = null,
    last_duration_ms: ?i64 = null,
    commands: usize = 0,
    jobs: usize = 0,

    fn setCwd(self: *Status, cwd: []const u8) void {
        const len = @min(cwd.len, self.cwd.len);
        @memcpy(self.cwd[0..len], cwd[0..len]);
        self.cwd_len = len;
    }

    fn cwdSlice(self: *const Status) []const u8 {
        return self.cwd[0..self.cwd_len];
    }

    fn setProjectKind(self: *Status, project_kind: []const u8) void {
        const len = @min(project_kind.len, self.project_kind.len);
        @memcpy(self.project_kind[0..len], project_kind[0..len]);
        self.project_kind_len = len;
    }

    fn projectKindSlice(self: *const Status) []const u8 {
        return self.project_kind[0..self.project_kind_len];
    }

    fn setGitBranch(self: *Status, branch: []const u8) void {
        const len = @min(branch.len, self.git_branch.len);
        @memcpy(self.git_branch[0..len], branch[0..len]);
        self.git_branch_len = len;
    }

    fn gitBranchSlice(self: *const Status) []const u8 {
        return self.git_branch[0..self.git_branch_len];
    }

    fn gitDirtyCount(self: *const Status) usize {
        return self.git_staged + self.git_changed + self.git_untracked + self.git_conflicts;
    }

    fn clearPromptContext(self: *Status) void {
        self.project_kind_len = 0;
        self.git_branch_len = 0;
        self.git_staged = 0;
        self.git_changed = 0;
        self.git_untracked = 0;
        self.git_conflicts = 0;
        self.git_ahead = 0;
        self.git_behind = 0;
        self.jobs = 0;
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

const QuickItem = struct {
    text: [160]u8 = undefined,
    len: usize = 0,

    fn set(self: *QuickItem, value: []const u8) void {
        self.len = @min(value.len, self.text.len);
        @memcpy(self.text[0..self.len], value[0..self.len]);
    }

    fn slice(self: *const QuickItem) []const u8 {
        return self.text[0..self.len];
    }
};

const PaletteActionKind = enum {
    copy_visible,
    paste_clipboard,
    search_scrollback,
    quick_select,
    split_vertical,
    split_horizontal,
    focus_next_pane,
    close_pane,
    open_agent_panel,
    agent_health,
    agent_tools,
    agent_preview_write,
    agent_approve_write,
    toggle_settings,
    next_theme,
    reload_config,
    restart_shell,
    clear_scrollback,
    copy_cwd,
    copy_config_path,
    insert_agent_health,
};

const PaletteAction = struct {
    title: []const u8,
    detail: []const u8,
    kind: PaletteActionKind,
};

const palette_actions = [_]PaletteAction{
    .{ .title = "Copy visible text", .detail = "Copy current viewport or scrollback view", .kind = .copy_visible },
    .{ .title = "Paste clipboard", .detail = "Paste clipboard text into the active shell", .kind = .paste_clipboard },
    .{ .title = "Search scrollback", .detail = "Find text in visible output and bounded history", .kind = .search_scrollback },
    .{ .title = "Quick select", .detail = "Copy URLs, paths, issue keys, and hashes", .kind = .quick_select },
    .{ .title = "Split pane right", .detail = "Create a vertical split with a fresh shell", .kind = .split_vertical },
    .{ .title = "Split pane down", .detail = "Create a horizontal split with a fresh shell", .kind = .split_horizontal },
    .{ .title = "Focus next pane", .detail = "Move keyboard focus to the next terminal pane", .kind = .focus_next_pane },
    .{ .title = "Close pane", .detail = "Close the active pane and its shell", .kind = .close_pane },
    .{ .title = "AgentD panel", .detail = "Open the local AgentD sidecar transcript", .kind = .open_agent_panel },
    .{ .title = "AgentD health", .detail = "Ask AgentD for provider and runtime status", .kind = .agent_health },
    .{ .title = "AgentD tools", .detail = "List local tools, schemas, and approval policy", .kind = .agent_tools },
    .{ .title = "AgentD preview write", .detail = "Request a terminal.write host action preview", .kind = .agent_preview_write },
    .{ .title = "Approve AgentD write", .detail = "Write the pending AgentD preview into the active pane", .kind = .agent_approve_write },
    .{ .title = "Settings", .detail = "Toggle the settings and theme overlay", .kind = .toggle_settings },
    .{ .title = "Next theme", .detail = "Cycle through built-in terminal themes", .kind = .next_theme },
    .{ .title = "Reload config", .detail = "Reload desktop.conf and apply safe settings", .kind = .reload_config },
    .{ .title = "Restart shell", .detail = "Restart the current ZiggyZag PTY session", .kind = .restart_shell },
    .{ .title = "Clear scrollback", .detail = "Clear terminal history without clearing the screen", .kind = .clear_scrollback },
    .{ .title = "Copy current directory", .detail = "Copy shell integration cwd from the status bar", .kind = .copy_cwd },
    .{ .title = "Copy config path", .detail = "Copy the active desktop config path", .kind = .copy_config_path },
    .{ .title = "Insert AgentD health check", .detail = "Write a local AgentD JSON health command", .kind = .insert_agent_health },
};

const Overlay = enum {
    none,
    settings,
    command_palette,
    search,
    quick_select,
    agent,
};

const MouseModeSnapshot = struct {
    alternate_screen: bool,
    tracking: terminal.MouseTracking,
    encoding: terminal.MouseEncoding,
};

const SplitOrientation = enum {
    vertical,
    horizontal,
};

const Pane = struct {
    grid: terminal.Grid,
    input_write: ?HANDLE = null,
    output_read: ?HANDLE = null,
    pseudoconsole: ?HPCON = null,
    process_info: ?win.PROCESS.INFORMATION = null,
    reader_thread: ?std.Thread = null,
    status: Status = .{},
    scroll_offset: usize = 0,
    wheel_remainder: i32 = 0,
    startup_error: [96]u8 = undefined,
    startup_error_len: usize = 0,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn init(allocator: Allocator, width: usize, height: usize) !Pane {
        return .{
            .grid = try terminal.Grid.init(allocator, width, height),
        };
    }

    fn deinit(self: *Pane) void {
        self.grid.deinit();
    }

    fn setStartupError(self: *Pane, err: anyerror) void {
        const name = @errorName(err);
        const len = @min(name.len, self.startup_error.len);
        @memcpy(self.startup_error[0..len], name[0..len]);
        self.startup_error_len = len;
    }

    fn clearRuntimeState(self: *Pane) void {
        self.status = .{};
        self.scroll_offset = 0;
        self.wheel_remainder = 0;
        self.startup_error_len = 0;
    }
};

const App = struct {
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    hwnd: HWND = null,
    panes: [MAX_PANES]?*Pane = [_]?*Pane{null} ** MAX_PANES,
    active_pane: usize = 0,
    split_orientation: SplitOrientation = .vertical,
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
    focused: bool = false,
    overlay: Overlay = .none,
    palette_query: [128]u8 = undefined,
    palette_query_len: usize = 0,
    palette_selected: usize = 0,
    search_query: [128]u8 = undefined,
    search_query_len: usize = 0,
    search_match_label: [192]u8 = undefined,
    search_match_label_len: usize = 0,
    quick_items: [32]QuickItem = undefined,
    quick_item_count: usize = 0,
    quick_selected: usize = 0,
    agent_child: ?std.process.Child = null,
    agent_reader_thread: ?std.Thread = null,
    agent_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    agent_transcript: [AGENT_TRANSCRIPT_BYTES]u8 = undefined,
    agent_transcript_len: usize = 0,
    agent_next_id: u32 = 1,
    agent_pending_write: [AGENT_PENDING_WRITE_BYTES]u8 = undefined,
    agent_pending_write_len: usize = 0,

    fn init(allocator: Allocator, io: std.Io, env: *std.process.Environ.Map) !App {
        var app = App{
            .allocator = allocator,
            .io = io,
            .env = env,
        };
        errdefer app.deinit();
        app.panes[0] = try app.createPane(100, 32);
        app.active_pane = 0;
        return app;
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
        self.applyScrollbackLimit();
    }

    fn desktopConfigPathAlloc(self: *App) ![]u8 {
        if (self.env.get("ZIGGYZAG_DESKTOP_CONFIG")) |path| return try self.allocator.dupe(u8, path);
        if (self.env.get("APPDATA")) |appdata| return try std.fs.path.join(self.allocator, &.{ appdata, "ZiggyZag", "desktop.conf" });
        const home = self.env.get("HOME") orelse self.env.get("USERPROFILE") orelse ".";
        return try std.fs.path.join(self.allocator, &.{ home, ".config", "ziggyzag", "desktop.conf" });
    }

    fn deinit(self: *App) void {
        self.shutdownPty();
        self.shutdownAgentD();
        if (self.font) |font| _ = DeleteObject(@ptrCast(font));
        if (self.bg_brush) |brush| _ = DeleteObject(@ptrCast(brush));
        if (self.panel_brush) |brush| _ = DeleteObject(@ptrCast(brush));
        if (self.cursor_brush) |brush| _ = DeleteObject(@ptrCast(brush));
        if (self.config_buffer) |buffer| self.allocator.free(buffer);
        for (&self.panes) |*slot| {
            if (slot.*) |pane| {
                pane.deinit();
                self.allocator.destroy(pane);
                slot.* = null;
            }
        }
    }

    fn createPane(self: *App, width: usize, height: usize) !*Pane {
        const pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(pane);
        pane.* = try Pane.init(self.allocator, width, height);
        pane.grid.setMaxScrollback(self.config.options.scrollback_lines);
        return pane;
    }

    fn paneCount(self: *const App) usize {
        var count: usize = 0;
        for (self.panes) |pane| {
            if (pane != null) count += 1;
        }
        return count;
    }

    fn firstEmptyPaneSlot(self: *const App) ?usize {
        for (self.panes, 0..) |pane, index| {
            if (pane == null) return index;
        }
        return null;
    }

    fn activePane(self: *App) *Pane {
        if (self.active_pane >= self.panes.len or self.panes[self.active_pane] == null) {
            self.active_pane = self.firstLivePaneSlot() orelse 0;
        }
        return self.panes[self.active_pane].?;
    }

    fn firstLivePaneSlot(self: *const App) ?usize {
        for (self.panes, 0..) |pane, index| {
            if (pane != null) return index;
        }
        return null;
    }

    fn applyScrollbackLimit(self: *App) void {
        for (self.panes) |pane_or_null| {
            if (pane_or_null) |pane| pane.grid.setMaxScrollback(self.config.options.scrollback_lines);
        }
    }

    fn applyConfiguredSessionLayout(self: *App) void {
        self.split_orientation = if (std.ascii.eqlIgnoreCase(self.config.session.orientation, "horizontal")) .horizontal else .vertical;
        const target = @min(self.config.session.panes, self.panes.len);
        while (self.paneCount() < target) {
            const slot = self.firstEmptyPaneSlot() orelse break;
            const active = self.activePane();
            self.panes[slot] = self.createPane(active.grid.width, active.grid.height) catch break;
        }
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
        try self.startPtyForPane(self.activePane());
    }

    fn startPtyForPane(self: *App, pane: *Pane) !void {
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
        const size = COORD{ .X = @intCast(@min(pane.grid.width, 300)), .Y = @intCast(@min(pane.grid.height, 120)) };
        if (failed(CreatePseudoConsole(size, pty_input_read, pty_output_write, 0, &hpc))) return error.CreatePseudoConsoleFailed;
        pane.pseudoconsole = hpc;
        errdefer {
            ClosePseudoConsole(hpc);
            pane.pseudoconsole = null;
        }

        const command_line = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, shell_path);
        defer self.allocator.free(command_line);
        const cwd = if (self.config.profile.startup_directory.len > 0)
            try self.allocator.dupe(u8, self.config.profile.startup_directory)
        else
            try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd);
        const cwd_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, cwd);
        defer self.allocator.free(cwd_w);

        var child_env = try self.env.clone(self.allocator);
        defer child_env.deinit();
        try child_env.put("ZIGGYZAG_APP", "1");
        try child_env.put("ZIGGYZAG_INTEGRATION", "1");
        try child_env.put("TERM", if (self.config.profile.term.len > 0) self.config.profile.term else "xterm-256color");
        // Theme protocol v1: hand the active theme id to the shell so it can
        // colour its prompt accent to match the desktop palette. See
        // docs/THEME_PROTOCOL.md.
        try child_env.put("ZIGGYZAG_THEME", self.config.selected_theme.id);
        const env_block = try child_env.createWindowsBlock(self.allocator, .{});
        defer env_block.deinit(self.allocator);

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
            env_block.view().ptr,
            cwd_w.ptr,
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

        pane.running.store(true, .release);
        const thread = std.Thread.spawn(.{}, readLoop, .{ self, pane, app_output_read }) catch |err| {
            pane.running.store(false, .release);
            return err;
        };

        _ = CloseHandle(pty_input_read);
        _ = CloseHandle(pty_output_write);
        pane.input_write = app_input_write;
        pane.output_read = app_output_read;
        pane.process_info = process_info;
        pane.reader_thread = thread;
    }

    fn resolveShellPath(self: *App) ![]u8 {
        if (self.config.profile.shell_path.len > 0) return try self.allocator.dupe(u8, self.config.profile.shell_path);
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

    fn resolveAgentPath(self: *App) ![]u8 {
        if (self.env.get("ZIGGYZAG_AGENTD_PATH")) |path| return try self.allocator.dupe(u8, path);

        const exe_dir = std.process.executableDirPathAlloc(self.io, self.allocator) catch null;
        if (exe_dir) |dir| {
            defer self.allocator.free(dir);
            if (try self.existingJoined(&.{ dir, "bin", "ziggyzag-agentd.exe" })) |path| return path;
            if (try self.existingJoined(&.{ dir, "ziggyzag-agentd.exe" })) |path| return path;
        }

        const candidates = [_][]const u8{
            "zig-out/bin/ziggyzag-agentd.exe",
            "ziggyzag-agentd.exe",
        };
        for (candidates) |candidate| {
            std.Io.Dir.cwd().access(self.io, candidate, .{}) catch continue;
            return try self.allocator.dupe(u8, candidate);
        }
        return error.AgentBinaryNotFound;
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
        for (self.panes) |pane_or_null| {
            if (pane_or_null) |pane| self.shutdownPane(pane);
        }
    }

    fn shutdownPane(self: *App, pane: *Pane) void {
        _ = self;
        pane.running.store(false, .release);
        if (pane.input_write) |handle| {
            _ = CloseHandle(handle);
            pane.input_write = null;
        }
        if (pane.pseudoconsole) |hpc| {
            ClosePseudoConsole(hpc);
            pane.pseudoconsole = null;
        }
        if (pane.process_info) |info| {
            if (WaitForSingleObject(info.hProcess, CHILD_SHUTDOWN_GRACE_MS) == WAIT_TIMEOUT) {
                _ = TerminateProcess(info.hProcess, 0);
                _ = WaitForSingleObject(info.hProcess, CHILD_SHUTDOWN_KILL_GRACE_MS);
            }
            _ = CloseHandle(info.hThread);
            _ = CloseHandle(info.hProcess);
            pane.process_info = null;
        }
        if (pane.reader_thread) |thread| {
            thread.join();
            pane.reader_thread = null;
        }
        if (pane.output_read) |handle| {
            _ = CloseHandle(handle);
            pane.output_read = null;
        }
    }

    fn startAgentD(self: *App) !void {
        if (self.agent_child != null) return;
        const agent_path = try self.resolveAgentPath();
        defer self.allocator.free(agent_path);
        const argv = [_][]const u8{ agent_path, "--stdio" };
        var child = try std.process.spawn(self.io, .{
            .argv = &argv,
            .environ_map = self.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(self.io);

        var stdout_file = child.stdout.?;
        child.stdout = null;
        self.agent_running.store(true, .release);
        const thread = std.Thread.spawn(.{}, agentReadLoop, .{ self, stdout_file }) catch |err| {
            self.agent_running.store(false, .release);
            stdout_file.close(self.io);
            return err;
        };
        self.agent_child = child;
        self.agent_reader_thread = thread;
        self.appendAgentTranscript("agentd started\n");
    }

    fn shutdownAgentD(self: *App) void {
        self.agent_running.store(false, .release);
        if (self.agent_child) |*child| {
            if (child.stdin) |stdin_file| {
                var file = stdin_file;
                file.close(self.io);
                child.stdin = null;
            }
            child.kill(self.io);
            self.agent_child = null;
        }
        if (self.agent_reader_thread) |thread| {
            thread.join();
            self.agent_reader_thread = null;
        }
    }

    fn writeInput(self: *App, bytes: []const u8) void {
        const handle = self.activePane().input_write orelse return;
        var written: DWORD = 0;
        _ = WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null);
    }

    fn writeAgentLine(self: *App, line: []const u8) void {
        self.startAgentD() catch |err| {
            var text: [128]u8 = undefined;
            const message = std.fmt.bufPrint(&text, "agentd start failed: {s}\n", .{@errorName(err)}) catch "agentd start failed\n";
            self.appendAgentTranscript(message);
            return;
        };
        if (self.agent_child) |*child| {
            const stdin_file = child.stdin orelse return;
            var file = stdin_file;
            file.writeStreamingAll(self.io, line) catch {
                self.appendAgentTranscript("agentd write failed\n");
                return;
            };
        }
    }

    fn appendAgentTranscript(self: *App, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.appendAgentTranscriptLocked(text);
    }

    fn appendAgentTranscriptLocked(self: *App, text: []const u8) void {
        var incoming = text;
        if (incoming.len >= self.agent_transcript.len) {
            incoming = incoming[incoming.len - self.agent_transcript.len ..];
            @memcpy(self.agent_transcript[0..incoming.len], incoming);
            self.agent_transcript_len = incoming.len;
            return;
        }

        if (self.agent_transcript_len + incoming.len > self.agent_transcript.len) {
            const remove = self.agent_transcript_len + incoming.len - self.agent_transcript.len;
            const remaining = self.agent_transcript_len - remove;
            std.mem.copyForwards(u8, self.agent_transcript[0..remaining], self.agent_transcript[remove..self.agent_transcript_len]);
            self.agent_transcript_len = remaining;
        }
        @memcpy(self.agent_transcript[self.agent_transcript_len .. self.agent_transcript_len + incoming.len], incoming);
        self.agent_transcript_len += incoming.len;
    }

    fn nextAgentId(self: *App) u32 {
        const id = self.agent_next_id;
        self.agent_next_id +%= 1;
        if (self.agent_next_id == 0) self.agent_next_id = 1;
        return id;
    }

    fn openAgentPanel(self: *App) void {
        self.overlay = .agent;
        self.startAgentD() catch |err| {
            var text: [128]u8 = undefined;
            const message = std.fmt.bufPrint(&text, "agentd start failed: {s}\n", .{@errorName(err)}) catch "agentd start failed\n";
            self.appendAgentTranscript(message);
            return;
        };
    }

    fn requestAgentHealth(self: *App) void {
        self.openAgentPanel();
        const id = self.nextAgentId();
        var line: [96]u8 = undefined;
        const request = std.fmt.bufPrint(&line, "{{\"id\":{d},\"method\":\"agent/health\"}}\n", .{id}) catch return;
        self.appendAgentTranscript("> agent/health\n");
        self.writeAgentLine(request);
    }

    fn requestAgentTools(self: *App) void {
        self.openAgentPanel();
        const id = self.nextAgentId();
        var line: [96]u8 = undefined;
        const request = std.fmt.bufPrint(&line, "{{\"id\":{d},\"method\":\"tools/list\"}}\n", .{id}) catch return;
        self.appendAgentTranscript("> tools/list\n");
        self.writeAgentLine(request);
    }

    fn requestAgentWritePreview(self: *App) void {
        self.openAgentPanel();
        const text = "echo hello-from-agentd\n";
        const len = @min(text.len, self.agent_pending_write.len);
        @memcpy(self.agent_pending_write[0..len], text[0..len]);
        self.agent_pending_write_len = len;

        const id = self.nextAgentId();
        var line: [256]u8 = undefined;
        const request = std.fmt.bufPrint(
            &line,
            "{{\"id\":{d},\"method\":\"tools/call\",\"tool\":\"terminal.write\",\"text\":\"echo hello-from-agentd\\n\"}}\n",
            .{id},
        ) catch return;
        self.appendAgentTranscript("> terminal.write preview requested\n");
        self.writeAgentLine(request);
    }

    fn approveAgentWrite(self: *App) void {
        if (self.agent_pending_write_len == 0) return;
        self.writeInput(self.agent_pending_write[0..self.agent_pending_write_len]);
        self.agent_pending_write_len = 0;
        self.appendAgentTranscript("> approved pending terminal.write\n");
    }

    fn visibleTextAlloc(self: *App) ![]u8 {
        const pane = self.activePane();
        if (pane.scroll_offset > 0) {
            var lines: std.ArrayList([]u8) = .empty;
            defer lines.deinit(self.allocator);

            const history_len = pane.grid.historyLen();
            const height = pane.grid.height;
            const history_start = if (history_len > height + pane.scroll_offset) history_len - height - pane.scroll_offset else 0;
            var row: usize = 0;
            while (row < height and history_start + row < history_len) : (row += 1) {
                const line = try pane.grid.historyLineTextAlloc(self.allocator, history_start + row);
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

        return pane.grid.visibleTextAlloc(self.allocator);
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
        self.mutex.lock();
        const pane = self.activePane();
        const bracketed_paste = pane.grid.isBracketedPasteEnabled();
        self.resetPaneScroll(pane);
        self.mutex.unlock();
        if (bracketed_paste) {
            self.writeInput("\x1b[200~");
            self.writeInput(normalized.items);
            self.writeInput("\x1b[201~");
        } else {
            self.writeInput(normalized.items);
        }
    }

    fn appendOverlayChar(self: *App, char: u21) void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(char, &buf) catch return;
        switch (self.overlay) {
            .command_palette => appendBounded(self.palette_query[0..], &self.palette_query_len, buf[0..len]),
            .search => {
                appendBounded(self.search_query[0..], &self.search_query_len, buf[0..len]);
                self.updateSearchMatch();
            },
            else => {},
        }
    }

    fn overlayBackspace(self: *App) void {
        switch (self.overlay) {
            .command_palette => {
                if (self.palette_query_len > 0) self.palette_query_len -= 1;
            },
            .search => {
                if (self.search_query_len > 0) self.search_query_len -= 1;
                self.updateSearchMatch();
            },
            else => {},
        }
    }

    fn openPalette(self: *App) void {
        self.overlay = .command_palette;
        self.palette_query_len = 0;
        self.palette_selected = 0;
    }

    fn openSearch(self: *App) void {
        self.overlay = .search;
        self.search_query_len = 0;
        self.search_match_label_len = 0;
    }

    fn openQuickSelect(self: *App) void {
        self.populateQuickItems();
        self.quick_selected = 0;
        self.overlay = .quick_select;
    }

    fn closeOverlay(self: *App) void {
        self.overlay = .none;
    }

    fn overlayMove(self: *App, delta: i32) void {
        switch (self.overlay) {
            .command_palette => {
                const count = self.paletteMatchCount();
                if (count == 0) return;
                if (delta > 0) self.palette_selected = @min(self.palette_selected + 1, count - 1);
                if (delta < 0) self.palette_selected = if (self.palette_selected == 0) count - 1 else self.palette_selected - 1;
            },
            .quick_select => {
                if (self.quick_item_count == 0) return;
                if (delta > 0) self.quick_selected = @min(self.quick_selected + 1, self.quick_item_count - 1);
                if (delta < 0) self.quick_selected = if (self.quick_selected == 0) self.quick_item_count - 1 else self.quick_selected - 1;
            },
            else => {},
        }
    }

    fn acceptOverlay(self: *App, hwnd: HWND) void {
        switch (self.overlay) {
            .command_palette => {
                const action = self.paletteActionAt(self.palette_selected) orelse return;
                self.overlay = .none;
                self.dispatchAction(hwnd, action.kind);
            },
            .search => {},
            .quick_select => {
                if (self.quick_selected < self.quick_item_count) {
                    const item = self.quick_items[self.quick_selected].slice();
                    if (item.len > 0) setClipboardText(hwnd, self.allocator, item) catch {};
                }
                self.overlay = .none;
            },
            .agent => self.approveAgentWrite(),
            else => {},
        }
    }

    fn dispatchAction(self: *App, hwnd: HWND, kind: PaletteActionKind) void {
        switch (kind) {
            .copy_visible => self.copyVisibleText(hwnd),
            .paste_clipboard => self.pasteClipboardText(hwnd),
            .search_scrollback => self.openSearch(),
            .quick_select => self.openQuickSelect(),
            .split_vertical => self.splitPane(hwnd, .vertical),
            .split_horizontal => self.splitPane(hwnd, .horizontal),
            .focus_next_pane => self.focusNextPane(hwnd),
            .close_pane => self.closeActivePane(hwnd),
            .open_agent_panel => self.openAgentPanel(),
            .agent_health => self.requestAgentHealth(),
            .agent_tools => self.requestAgentTools(),
            .agent_preview_write => self.requestAgentWritePreview(),
            .agent_approve_write => self.approveAgentWrite(),
            .toggle_settings => self.overlay = if (self.overlay == .settings) .none else .settings,
            .next_theme => self.cycleTheme(),
            .reload_config => self.reloadDesktopConfig(hwnd),
            .restart_shell => self.restartShell(hwnd),
            .clear_scrollback => {
                self.mutex.lock();
                const pane = self.activePane();
                pane.grid.feed("\x1b[3J");
                self.resetPaneScroll(pane);
                self.mutex.unlock();
            },
            .copy_cwd => {
                const pane = self.activePane();
                if (pane.status.cwd_len > 0) setClipboardText(hwnd, self.allocator, pane.status.cwdSlice()) catch {};
            },
            .copy_config_path => if (self.config_path_len > 0) setClipboardText(hwnd, self.allocator, self.configPathSlice()) catch {},
            .insert_agent_health => self.writeInput("zig build run-agentd -- --stdio\n"),
        }
        _ = InvalidateRect(hwnd, null, 0);
    }

    fn cycleTheme(self: *App) void {
        self.selected_theme = theme.next(self.selected_theme);
        self.config.selected_theme = self.selected_theme;
        self.rebuildThemeBrushes();
    }

    fn reloadDesktopConfig(self: *App, hwnd: HWND) void {
        self.loadDesktopConfig();
        self.applyConfiguredSessionLayout();
        self.rebuildThemeBrushes();
        var rect: RECT = undefined;
        if (GetClientRect(hwnd, &rect) != 0) self.resizeForClient(rect);
        self.startConfiguredPanes(hwnd);
        _ = InvalidateRect(hwnd, null, 0);
    }

    fn restartShell(self: *App, hwnd: HWND) void {
        const pane = self.activePane();
        self.shutdownPane(pane);
        self.mutex.lock();
        pane.grid.feed("\x1b[2J\x1b[HRestarting ZiggyZag shell...\n");
        pane.clearRuntimeState();
        self.mutex.unlock();
        self.startPtyForPane(pane) catch |err| {
            self.mutex.lock();
            defer self.mutex.unlock();
            pane.setStartupError(err);
        };
        _ = InvalidateRect(hwnd, null, 0);
    }

    fn startConfiguredPanes(self: *App, hwnd: HWND) void {
        for (self.panes) |pane_or_null| {
            const pane = pane_or_null orelse continue;
            if (pane.process_info != null) continue;
            self.startPtyForPane(pane) catch |err| {
                self.mutex.lock();
                pane.setStartupError(err);
                pane.grid.feed("\x1b[2J");
                pane.grid.feed("ZiggyZag shell could not start.\n");
                pane.grid.feed("Run `zig build`, or set ZIGGYZAG_SHELL_PATH to a shell executable.\n");
                pane.grid.feed("Error: ");
                pane.grid.feed(@errorName(err));
                pane.grid.feed("\n");
                self.mutex.unlock();
            };
        }
        self.active_pane = self.firstLivePaneSlot() orelse 0;
        self.updateTitle();
        _ = InvalidateRect(hwnd, null, 0);
    }

    fn splitPane(self: *App, hwnd: HWND, orientation: SplitOrientation) void {
        const slot = self.firstEmptyPaneSlot() orelse return;
        const active = self.activePane();
        const pane = self.createPane(active.grid.width, active.grid.height) catch return;
        self.panes[slot] = pane;
        self.active_pane = slot;
        self.split_orientation = orientation;

        var rect: RECT = undefined;
        if (GetClientRect(hwnd, &rect) != 0) self.resizeForClient(rect);
        self.startPtyForPane(pane) catch |err| {
            self.mutex.lock();
            pane.setStartupError(err);
            pane.grid.feed("\x1b[2J\x1b[HNew pane shell could not start.\nError: ");
            pane.grid.feed(@errorName(err));
            pane.grid.feed("\n");
            self.mutex.unlock();
        };
        _ = InvalidateRect(hwnd, null, 0);
    }

    fn focusNextPane(self: *App, hwnd: HWND) void {
        var offset: usize = 1;
        while (offset <= self.panes.len) : (offset += 1) {
            const index = (self.active_pane + offset) % self.panes.len;
            if (self.panes[index] != null) {
                self.active_pane = index;
                self.updateCaret(hwnd);
                _ = InvalidateRect(hwnd, null, 0);
                return;
            }
        }
    }

    fn closeActivePane(self: *App, hwnd: HWND) void {
        if (self.paneCount() <= 1) return;
        const slot = self.active_pane;
        const pane = self.panes[slot] orelse return;
        self.shutdownPane(pane);
        pane.deinit();
        self.allocator.destroy(pane);
        self.panes[slot] = null;
        self.active_pane = self.nextPaneSlotAfter(slot) orelse 0;
        var rect: RECT = undefined;
        if (GetClientRect(hwnd, &rect) != 0) self.resizeForClient(rect);
        self.updateCaret(hwnd);
        _ = InvalidateRect(hwnd, null, 0);
    }

    fn nextPaneSlotAfter(self: *const App, slot: usize) ?usize {
        var offset: usize = 1;
        while (offset <= self.panes.len) : (offset += 1) {
            const index = (slot + self.panes.len - offset) % self.panes.len;
            if (self.panes[index] != null) return index;
        }
        return null;
    }

    fn paletteMatchCount(self: *const App) usize {
        var count: usize = 0;
        for (palette_actions) |action| {
            if (self.paletteActionMatches(action)) count += 1;
        }
        return count;
    }

    fn paletteActionAt(self: *const App, selected: usize) ?PaletteAction {
        var count: usize = 0;
        for (palette_actions) |action| {
            if (!self.paletteActionMatches(action)) continue;
            if (count == selected) return action;
            count += 1;
        }
        return null;
    }

    fn paletteActionMatches(self: *const App, action: PaletteAction) bool {
        const query = self.palette_query[0..self.palette_query_len];
        return query.len == 0 or containsIgnoreCase(action.title, query) or containsIgnoreCase(action.detail, query);
    }

    fn scrollbackTextAlloc(self: *App) ![]u8 {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(self.allocator);
        self.mutex.lock();
        defer self.mutex.unlock();
        const pane = self.activePane();

        for (pane.grid.history.items) |line| {
            try appendCellsText(self.allocator, &text, line.cells);
            try text.append(self.allocator, '\n');
        }
        var row: usize = 0;
        while (row < pane.grid.height) : (row += 1) {
            const line = pane.grid.cells[row * pane.grid.width .. (row + 1) * pane.grid.width];
            try appendCellsText(self.allocator, &text, line);
            if (row + 1 < pane.grid.height) try text.append(self.allocator, '\n');
        }
        return text.toOwnedSlice(self.allocator);
    }

    fn updateSearchMatch(self: *App) void {
        self.search_match_label_len = 0;
        const query = self.search_query[0..self.search_query_len];
        if (query.len == 0) return;
        const text = self.scrollbackTextAlloc() catch return;
        defer self.allocator.free(text);

        if (indexOfIgnoreCase(text, query)) |index| {
            const line_no = 1 + countByte(text[0..index], '\n');
            const label = std.fmt.bufPrint(
                self.search_match_label[0..],
                "Found at scrollback line {d}",
                .{line_no},
            ) catch return;
            self.search_match_label_len = label.len;
        } else {
            self.search_match_label_len = copyBounded(self.search_match_label[0..], "No match");
        }
    }

    fn populateQuickItems(self: *App) void {
        self.quick_item_count = 0;
        self.mutex.lock();
        const text = self.visibleTextAlloc() catch {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();
        defer self.allocator.free(text);
        var index: usize = 0;
        while (index < text.len and self.quick_item_count < self.quick_items.len) {
            while (index < text.len and isTokenSeparator(text[index])) : (index += 1) {}
            const start = index;
            while (index < text.len and !isTokenSeparator(text[index])) : (index += 1) {}
            const token = trimQuickToken(text[start..index]);
            if (isQuickToken(token) and !self.quickItemExists(token)) {
                self.quick_items[self.quick_item_count].set(token);
                self.quick_item_count += 1;
            }
        }
    }

    fn quickItemExists(self: *const App, token: []const u8) bool {
        var index: usize = 0;
        while (index < self.quick_item_count) : (index += 1) {
            if (std.mem.eql(u8, self.quick_items[index].slice(), token)) return true;
        }
        return false;
    }

    fn resetPaneScroll(self: *App, pane: *Pane) void {
        _ = self;
        pane.scroll_offset = 0;
        pane.wheel_remainder = 0;
    }

    fn resetScroll(self: *App) void {
        self.resetPaneScroll(self.activePane());
    }

    fn clampPaneScroll(self: *App, pane: *Pane) void {
        _ = self;
        const history_len = pane.grid.historyLen();
        if (pane.scroll_offset > history_len) pane.scroll_offset = history_len;
        if (pane.scroll_offset == 0) pane.wheel_remainder = 0;
    }

    fn scrollPaneBy(self: *App, pane: *Pane, lines: i32) void {
        if (lines > 0) {
            const amount: usize = @intCast(lines);
            pane.scroll_offset = @min(pane.scroll_offset + amount, pane.grid.historyLen());
        } else if (lines < 0) {
            const amount: usize = @intCast(-lines);
            pane.scroll_offset = if (amount >= pane.scroll_offset) 0 else pane.scroll_offset - amount;
        }
        self.clampPaneScroll(pane);
    }

    fn scrollBy(self: *App, lines: i32) void {
        self.scrollPaneBy(self.activePane(), lines);
    }

    fn handleMouseWheel(self: *App, hwnd: HWND, wparam: WPARAM) void {
        const delta = mouseWheelDelta(wparam);
        const mouse_mode = self.mouseModeSnapshot();
        if (mouse_mode.alternate_screen and mouse_mode.tracking != .disabled) {
            self.writeMouseWheel(delta, mouse_mode.encoding);
            return;
        }
        const pane = self.activePane();
        pane.wheel_remainder += delta;
        const lines = @divTrunc(pane.wheel_remainder, WHEEL_DELTA) * 3;
        pane.wheel_remainder = @rem(pane.wheel_remainder, WHEEL_DELTA);
        if (lines != 0) {
            self.mutex.lock();
            self.scrollPaneBy(pane, lines);
            self.mutex.unlock();
            self.updateCaret(hwnd);
            _ = InvalidateRect(hwnd, null, 0);
        }
    }

    fn writeMouseWheel(self: *App, delta: i32, encoding: terminal.MouseEncoding) void {
        const button: u8 = if (delta > 0) 64 else 65;
        if (encoding == .sgr) {
            var seq: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&seq, "\x1b[<{d};1;1M", .{button}) catch return;
            self.writeInput(text);
        } else {
            var seq = [_]u8{ 0x1b, '[', 'M', button + 32, 33, 33 };
            self.writeInput(&seq);
        }
    }

    fn mouseModeSnapshot(self: *App) MouseModeSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const pane = self.activePane();
        return .{
            .alternate_screen = pane.grid.isAlternateScreen(),
            .tracking = pane.grid.mouseTrackingMode(),
            .encoding = pane.grid.mouseEncodingMode(),
        };
    }

    fn applicationCursorEnabled(self: *App) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.activePane().grid.isApplicationCursorEnabled();
    }

    fn resizeForClient(self: *App, rect: RECT) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.panes, 0..) |pane_or_null, index| {
            const pane = pane_or_null orelse continue;
            const pane_rect = self.paneRectForSlot(rect, index);
            const width_px = @max(pane_rect.right - pane_rect.left - PANE_PAD_X * 2, self.char_width);
            const height_px = @max(pane_rect.bottom - pane_rect.top - PANE_PAD_Y, self.char_height);
            const cols: usize = @intCast(@max(@divTrunc(width_px, @max(self.char_width, 1)), MIN_PANE_COLS));
            const rows: usize = @intCast(@max(@divTrunc(height_px, @max(self.char_height, 1)), MIN_PANE_ROWS));
            pane.grid.resize(cols, rows) catch continue;
            self.resetPaneScroll(pane);
            if (pane.pseudoconsole) |hpc| {
                _ = ResizePseudoConsole(hpc, .{ .X = @intCast(@min(cols, 300)), .Y = @intCast(@min(rows, 120)) });
            }
        }
    }

    fn paneRectForSlot(self: *const App, rect: RECT, slot: usize) PaneRect {
        const count = @max(self.paneCount(), 1);
        const ordinal = self.paneOrdinal(slot) orelse 0;
        var area = RECT{
            .left = rect.left,
            .top = rect.top,
            .right = rect.right,
            .bottom = @max(rect.top + self.char_height, rect.bottom - self.status_height),
        };
        if (count <= 1) return area;
        if (self.split_orientation == .vertical) {
            const width = @max(area.right - area.left, 1);
            const left = area.left + @divTrunc(width * @as(i32, @intCast(ordinal)), @as(i32, @intCast(count)));
            const right = area.left + @divTrunc(width * @as(i32, @intCast(ordinal + 1)), @as(i32, @intCast(count)));
            area.left = left;
            area.right = @max(left + self.char_width * MIN_PANE_COLS, right);
            area.right = @min(area.right, rect.right);
        } else {
            const height = @max(area.bottom - area.top, 1);
            const top = area.top + @divTrunc(height * @as(i32, @intCast(ordinal)), @as(i32, @intCast(count)));
            const bottom = area.top + @divTrunc(height * @as(i32, @intCast(ordinal + 1)), @as(i32, @intCast(count)));
            area.top = top;
            area.bottom = @max(top + self.char_height * MIN_PANE_ROWS, bottom);
            area.bottom = @min(area.bottom, rect.bottom - self.status_height);
        }
        return area;
    }

    fn activePaneRect(self: *const App, rect: RECT) PaneRect {
        return self.paneRectForSlot(rect, self.active_pane);
    }

    fn paneOrdinal(self: *const App, slot: usize) ?usize {
        var ordinal: usize = 0;
        for (self.panes, 0..) |pane, index| {
            if (pane == null) continue;
            if (index == slot) return ordinal;
            ordinal += 1;
        }
        return null;
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
        for (self.panes, 0..) |pane_or_null, index| {
            const pane = pane_or_null orelse continue;
            self.paintPane(hdc, rect, pane, index);
        }
        const active = self.activePane();
        const status = active.status;
        const scroll_offset = active.scroll_offset;
        const history_len = active.grid.historyLen();
        self.mutex.unlock();

        if (self.status_height > 0) self.paintStatus(hdc, rect, status, scroll_offset, history_len);
        switch (self.overlay) {
            .settings => self.paintSettingsOverlay(hdc, rect),
            .command_palette => self.paintCommandPaletteOverlay(hdc, rect),
            .search => self.paintSearchOverlay(hdc, rect),
            .quick_select => self.paintQuickSelectOverlay(hdc, rect),
            .agent => self.paintAgentOverlay(hdc, rect),
            .none => {},
        }
    }

    fn paintPane(self: *App, hdc: HDC, client_rect: RECT, pane: *Pane, slot: usize) void {
        const pane_rect = self.paneRectForSlot(client_rect, slot);
        if (self.paneCount() > 1) {
            const is_active = slot == self.active_pane;
            const color = if (is_active) self.selected_theme.accent else scaleColor(self.selected_theme.muted, 65);
            const brush = CreateSolidBrush(toColorRef(color));
            if (brush) |b| {
                var top = RECT{ .left = pane_rect.left, .top = pane_rect.top, .right = pane_rect.right, .bottom = pane_rect.top + 2 };
                _ = FillRect(hdc, &top, b);
                if (pane_rect.left > client_rect.left) {
                    var left = RECT{ .left = pane_rect.left, .top = pane_rect.top, .right = pane_rect.left + 1, .bottom = pane_rect.bottom };
                    _ = FillRect(hdc, &left, b);
                }
                _ = DeleteObject(@ptrCast(b));
            }
        }

        const width = pane.grid.width;
        const height = pane.grid.height;
        self.clampPaneScroll(pane);
        const scroll_offset = pane.scroll_offset;
        const history_len = pane.grid.historyLen();
        const history_start = if (history_len > height + scroll_offset) history_len - height - scroll_offset else 0;
        const origin_x = pane_rect.left + PANE_PAD_X;
        var row: usize = 0;
        while (row < height) : (row += 1) {
            const y = pane_rect.top + PANE_PAD_Y + @as(i32, @intCast(row)) * self.char_height;
            if (y >= pane_rect.bottom) break;
            if (scroll_offset > 0) {
                const history_index = history_start + row;
                if (history_index < history_len) {
                    const line = pane.grid.history.items[history_index];
                    self.paintCellRun(hdc, origin_x, line.cells[0..@min(line.width, width)], y);
                }
            } else {
                const line = pane.grid.cells[row * width .. (row + 1) * width];
                self.paintCellRun(hdc, origin_x, line, y);
            }
        }

        if (scroll_offset == 0 and self.focused and slot == self.active_pane) {
            const cursor_x = pane.grid.cursor_x;
            const cursor_y = pane.grid.cursor_y;
            var caret_rect = RECT{
                .left = origin_x + @as(i32, @intCast(cursor_x)) * self.char_width,
                .top = pane_rect.top + PANE_PAD_Y + @as(i32, @intCast(cursor_y)) * self.char_height,
                .right = origin_x + @as(i32, @intCast(cursor_x + 1)) * self.char_width,
                .bottom = pane_rect.top + PANE_PAD_Y + @as(i32, @intCast(cursor_y + 1)) * self.char_height,
            };
            if (caret_rect.top < pane_rect.bottom) {
                caret_rect.bottom = @min(caret_rect.bottom, pane_rect.bottom);
                _ = FillRect(hdc, &caret_rect, self.cursor_brush);
            }
        }

        if (pane.startup_error_len > 0) {
            var startup_error: [96]u8 = undefined;
            @memcpy(startup_error[0..pane.startup_error_len], pane.startup_error[0..pane.startup_error_len]);
            self.paintStartupMessage(hdc, pane_rect, startup_error[0..pane.startup_error_len]);
        }
        self.paintScrollIndicator(hdc, pane_rect, scroll_offset, history_len);
    }

    fn paintCellRun(self: *App, hdc: HDC, origin_x: i32, cells: []const terminal.Cell, y: i32) void {
        const end = visibleCellEnd(cells);
        var col: usize = 0;
        while (col < end) {
            const style = cells[col].style;
            var run_end = col + 1;
            while (run_end < end and styleEql(style, cells[run_end].style)) : (run_end += 1) {}

            const background = styleBackground(self.selected_theme, style);
            var run_rect = RECT{
                .left = origin_x + @as(i32, @intCast(col)) * self.char_width,
                .top = y,
                .right = origin_x + @as(i32, @intCast(run_end)) * self.char_width,
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
                const cell = cells[offset];
                if (!cell.isContinuation()) {
                    var wide: [2]WCHAR = undefined;
                    const len = cellCodepointToWide(cell.codepoint, &wide);
                    if (len > 0) {
                        _ = TextOutW(
                            hdc,
                            origin_x + @as(i32, @intCast(offset)) * self.char_width,
                            y,
                            &wide,
                            @intCast(len),
                        );
                    }
                }
                offset += 1;
            }
            col = run_end;
        }
        _ = SetBkMode(hdc, TRANSPARENT);
    }

    fn paintStartupMessage(self: *App, hdc: HDC, rect: RECT, error_name: []const u8) void {
        const x = rect.left + 20;
        const terminal_bottom = rect.bottom;
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
        const bottom = rect.bottom - 8;
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
        var context_text: [192]u8 = undefined;
        const cwd = if (status.cwd_len > 0) status.cwdSlice() else "starting shell";
        const duration = if (status.last_duration_ms) |ms| std.fmt.bufPrint(&duration_text, "{d}ms", .{ms}) catch "n/a" else "n/a";
        const wide_layout = rect.right - rect.left > 920;
        const shortcuts = "Ctrl+Shift+D split | Ctrl+Shift+E down | Ctrl+Shift+N pane | Ctrl+Shift+W close";
        const context = statusContext(context_text[0..], status);
        const pane_count = self.paneCount();
        const active_display = (self.paneOrdinal(self.active_pane) orelse 0) + 1;
        const text = if (wide_layout)
            (std.fmt.bufPrint(&status_text, "ZiggyZag  |  pane:{d}/{d}  |  {s}{s}  |  commands:{d}  |  status:{s}  |  last:{s}{s}  |  {s}", .{
                active_display,
                pane_count,
                cwd,
                context,
                status.commands,
                if (status.last_status) |value| statusName(value) else "waiting",
                duration,
                if (scroll_offset > 0) "  |  scrollback" else if (history_len > 0) "  |  history ready" else "",
                shortcuts,
            }) catch "ZiggyZag")
        else
            (std.fmt.bufPrint(&status_text, "ZiggyZag  |  pane:{d}/{d}  |  status:{s}{s}  |  {s}{s}", .{
                active_display,
                pane_count,
                if (status.last_status) |value| statusName(value) else "waiting",
                shortGitContext(context_text[0..], status),
                "Ctrl+Shift+D split | Ctrl+Shift+N pane",
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
        drawUtf8TextFitted(hdc, text_x, bottom - self.char_height - 12, "Ctrl+Shift+T cycles theme. Ctrl+Shift+P opens palette. Edit desktop.conf to persist.", max_width, self.char_width);
    }

    fn paintCommandPaletteOverlay(self: *App, hdc: HDC, rect: RECT) void {
        const panel_width = @min(@max(rect.right - rect.left - 80, 360), 720);
        const left = @divTrunc(rect.right - rect.left - panel_width, 2);
        const top: i32 = 48;
        const bottom = @min(rect.bottom - self.status_height - 24, top + self.char_height * 16 + 44);
        if (bottom <= top + self.char_height * 5) return;
        var panel = RECT{ .left = left, .top = top, .right = left + panel_width, .bottom = bottom };
        _ = FillRect(hdc, &panel, self.panel_brush);

        const x = panel.left + 14;
        var y = panel.top + 12;
        const max_width = panel.right - x - 14;
        _ = SetBkMode(hdc, TRANSPARENT);
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.accent));
        drawUtf8TextFitted(hdc, x, y, "Command Palette", max_width, self.char_width);
        y += self.char_height + 8;

        var query_line: [180]u8 = undefined;
        const query_text = std.fmt.bufPrint(&query_line, "> {s}", .{self.palette_query[0..self.palette_query_len]}) catch "> ";
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.foreground));
        drawUtf8TextFitted(hdc, x, y, query_text, max_width, self.char_width);
        y += self.char_height + 8;

        var match_index: usize = 0;
        for (palette_actions) |action| {
            if (!self.paletteActionMatches(action)) continue;
            if (y + self.char_height >= bottom - self.char_height - 8) break;
            if (match_index == self.palette_selected) {
                var highlight = RECT{ .left = x - 6, .top = y - 2, .right = panel.right - 10, .bottom = y + self.char_height + 2 };
                const brush = CreateSolidBrush(toColorRef(scaleColor(self.selected_theme.accent, 35)));
                if (brush) |b| {
                    _ = FillRect(hdc, &highlight, b);
                    _ = DeleteObject(@ptrCast(b));
                }
            }
            _ = SetTextColor(hdc, toColorRef(if (match_index == self.palette_selected) self.selected_theme.accent else self.selected_theme.foreground));
            drawUtf8TextFitted(hdc, x, y, action.title, max_width, self.char_width);
            y += self.char_height;
            _ = SetTextColor(hdc, toColorRef(self.selected_theme.muted));
            drawUtf8TextFitted(hdc, x + 18, y, action.detail, max_width - 18, self.char_width);
            y += self.char_height + 4;
            match_index += 1;
        }

        _ = SetTextColor(hdc, toColorRef(self.selected_theme.muted));
        drawUtf8TextFitted(hdc, x, bottom - self.char_height - 8, "Enter runs. Escape closes. Ctrl+Shift+F search. Ctrl+Shift+O quick select.", max_width, self.char_width);
    }

    fn paintSearchOverlay(self: *App, hdc: HDC, rect: RECT) void {
        const panel_width = @min(@max(rect.right - rect.left - 80, 360), 680);
        const left = @divTrunc(rect.right - rect.left - panel_width, 2);
        const top = @max(rect.bottom - self.status_height - self.char_height * 6 - 32, 24);
        var panel = RECT{ .left = left, .top = top, .right = left + panel_width, .bottom = top + self.char_height * 5 + 26 };
        _ = FillRect(hdc, &panel, self.panel_brush);
        const x = panel.left + 14;
        var y = panel.top + 12;
        const max_width = panel.right - x - 14;

        _ = SetBkMode(hdc, TRANSPARENT);
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.accent));
        drawUtf8TextFitted(hdc, x, y, "Search Scrollback", max_width, self.char_width);
        y += self.char_height + 8;
        var query_line: [180]u8 = undefined;
        const query_text = std.fmt.bufPrint(&query_line, "/ {s}", .{self.search_query[0..self.search_query_len]}) catch "/ ";
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.foreground));
        drawUtf8TextFitted(hdc, x, y, query_text, max_width, self.char_width);
        y += self.char_height + 8;

        const result = if (self.search_match_label_len > 0) self.search_match_label[0..self.search_match_label_len] else "Type to search visible output and scrollback";
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.muted));
        drawUtf8TextFitted(hdc, x, y, result, max_width, self.char_width);
        y += self.char_height + 4;
        drawUtf8TextFitted(hdc, x, y, "Escape closes. Ctrl+Shift+C still copies the current viewport.", max_width, self.char_width);
    }

    fn paintQuickSelectOverlay(self: *App, hdc: HDC, rect: RECT) void {
        const panel_width = @min(@max(rect.right - rect.left - 80, 360), 720);
        const left = @divTrunc(rect.right - rect.left - panel_width, 2);
        const top: i32 = 48;
        const bottom = @min(rect.bottom - self.status_height - 24, top + self.char_height * 16 + 44);
        var panel = RECT{ .left = left, .top = top, .right = left + panel_width, .bottom = bottom };
        _ = FillRect(hdc, &panel, self.panel_brush);
        const x = panel.left + 14;
        var y = panel.top + 12;
        const max_width = panel.right - x - 14;

        _ = SetBkMode(hdc, TRANSPARENT);
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.accent));
        drawUtf8TextFitted(hdc, x, y, "Quick Select", max_width, self.char_width);
        y += self.char_height + 8;
        if (self.quick_item_count == 0) {
            _ = SetTextColor(hdc, toColorRef(self.selected_theme.muted));
            drawUtf8TextFitted(hdc, x, y, "No URLs, paths, hashes, or issue keys found in the current viewport.", max_width, self.char_width);
        } else {
            var index: usize = 0;
            while (index < self.quick_item_count and y + self.char_height < bottom - self.char_height - 8) : (index += 1) {
                if (index == self.quick_selected) {
                    var highlight = RECT{ .left = x - 6, .top = y - 2, .right = panel.right - 10, .bottom = y + self.char_height + 2 };
                    const brush = CreateSolidBrush(toColorRef(scaleColor(self.selected_theme.accent, 35)));
                    if (brush) |b| {
                        _ = FillRect(hdc, &highlight, b);
                        _ = DeleteObject(@ptrCast(b));
                    }
                }
                _ = SetTextColor(hdc, toColorRef(if (index == self.quick_selected) self.selected_theme.accent else self.selected_theme.foreground));
                drawUtf8TextFitted(hdc, x, y, self.quick_items[index].slice(), max_width, self.char_width);
                y += self.char_height + 4;
            }
        }

        _ = SetTextColor(hdc, toColorRef(self.selected_theme.muted));
        drawUtf8TextFitted(hdc, x, bottom - self.char_height - 8, "Enter copies selection. Escape closes.", max_width, self.char_width);
    }

    fn paintAgentOverlay(self: *App, hdc: HDC, rect: RECT) void {
        const panel_width = @min(@max(rect.right - rect.left - 80, 420), 860);
        const left = @divTrunc(rect.right - rect.left - panel_width, 2);
        const top: i32 = 42;
        const bottom = @min(rect.bottom - self.status_height - 24, top + self.char_height * 20 + 56);
        if (bottom <= top + self.char_height * 6) return;
        var panel = RECT{ .left = left, .top = top, .right = left + panel_width, .bottom = bottom };
        _ = FillRect(hdc, &panel, self.panel_brush);

        const x = panel.left + 14;
        var y = panel.top + 12;
        const max_width = panel.right - x - 14;
        _ = SetBkMode(hdc, TRANSPARENT);
        _ = SetTextColor(hdc, toColorRef(self.selected_theme.accent));
        drawUtf8TextFitted(hdc, x, y, "AgentD", max_width, self.char_width);
        y += self.char_height + 8;

        var snapshot: [AGENT_TRANSCRIPT_BYTES]u8 = undefined;
        self.mutex.lock();
        const transcript_len = self.agent_transcript_len;
        if (transcript_len > 0) @memcpy(snapshot[0..transcript_len], self.agent_transcript[0..transcript_len]);
        const pending_len = self.agent_pending_write_len;
        var pending: [AGENT_PENDING_WRITE_BYTES]u8 = undefined;
        if (pending_len > 0) @memcpy(pending[0..pending_len], self.agent_pending_write[0..pending_len]);
        self.mutex.unlock();

        _ = SetTextColor(hdc, toColorRef(self.selected_theme.muted));
        const status = if (self.agent_child != null) "running" else "stopped";
        var status_line: [192]u8 = undefined;
        const status_text = std.fmt.bufPrint(&status_line, "Sidecar: {s}  |  Palette: health, tools, preview write, approve write", .{status}) catch "Sidecar";
        drawUtf8TextFitted(hdc, x, y, status_text, max_width, self.char_width);
        y += self.char_height + 8;

        if (pending_len > 0) {
            _ = SetTextColor(hdc, toColorRef(self.selected_theme.accent));
            var pending_line: [256]u8 = undefined;
            const preview = std.fmt.bufPrint(&pending_line, "Pending write: {s}", .{pending[0..pending_len]}) catch "Pending write";
            drawUtf8TextFitted(hdc, x, y, preview, max_width, self.char_width);
            y += self.char_height + 6;
        }

        _ = SetTextColor(hdc, toColorRef(self.selected_theme.foreground));
        if (transcript_len == 0) {
            drawUtf8TextFitted(hdc, x, y, "Open the palette and run AgentD health or tools.", max_width, self.char_width);
        } else {
            var iter = std.mem.splitScalar(u8, snapshot[0..transcript_len], '\n');
            while (iter.next()) |line| {
                if (line.len == 0) continue;
                if (y + self.char_height >= bottom - self.char_height - 10) break;
                drawUtf8TextFitted(hdc, x, y, line, max_width, self.char_width);
                y += self.char_height + 2;
            }
        }

        _ = SetTextColor(hdc, toColorRef(self.selected_theme.muted));
        drawUtf8TextFitted(hdc, x, bottom - self.char_height - 8, "Enter approves pending write. Escape closes. Ctrl+Shift+A opens this panel.", max_width, self.char_width);
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
        var rect: RECT = undefined;
        if (GetClientRect(hwnd, &rect) == 0) return;

        self.mutex.lock();
        const pane = self.activePane();
        const cursor_x = pane.grid.cursor_x;
        const cursor_y = pane.grid.cursor_y;
        const scroll_offset = pane.scroll_offset;
        const pane_rect = self.activePaneRect(rect);
        self.mutex.unlock();

        if (scroll_offset > 0) {
            _ = HideCaret(hwnd);
            return;
        }
        const x = pane_rect.left + PANE_PAD_X + @as(i32, @intCast(cursor_x)) * self.char_width;
        const y = @max(0, pane_rect.top + PANE_PAD_Y + @as(i32, @intCast(cursor_y)) * self.char_height);
        _ = SetCaretPos(x, y);
        _ = ShowCaret(hwnd);
    }

    fn handleEvents(self: *App, pane: *Pane, events: []const integration.Event) void {
        _ = self;
        for (events) |event| {
            switch (event.kind) {
                .session_ready => pane.status.ready = true,
                .prompt_rendered => {
                    if (integration.jsonStringValue(event.payload, "cwd")) |cwd| pane.status.setCwd(cwd);
                    pane.status.clearPromptContext();
                    if (integration.jsonStringValue(event.payload, "project_kind")) |project_kind| pane.status.setProjectKind(project_kind);
                    if (integration.jsonStringValue(event.payload, "branch")) |branch| pane.status.setGitBranch(branch);
                    if (integration.jsonIntValue(u8, event.payload, "last_status")) |value| pane.status.last_status = value;
                    if (integration.jsonIntValue(i64, event.payload, "last_duration_ms")) |value| pane.status.last_duration_ms = value;
                    if (integration.jsonIntValue(usize, event.payload, "jobs")) |value| pane.status.jobs = value;
                    if (integration.jsonIntValue(usize, event.payload, "staged")) |value| pane.status.git_staged = value;
                    if (integration.jsonIntValue(usize, event.payload, "changed")) |value| pane.status.git_changed = value;
                    if (integration.jsonIntValue(usize, event.payload, "untracked")) |value| pane.status.git_untracked = value;
                    if (integration.jsonIntValue(usize, event.payload, "conflicts")) |value| pane.status.git_conflicts = value;
                    if (integration.jsonIntValue(usize, event.payload, "ahead")) |value| pane.status.git_ahead = value;
                    if (integration.jsonIntValue(usize, event.payload, "behind")) |value| pane.status.git_behind = value;
                },
                .command_started => {
                    pane.status.commands += 1;
                    if (integration.jsonStringValue(event.payload, "cwd")) |cwd| pane.status.setCwd(cwd);
                },
                .command_finished => {
                    if (integration.jsonStringValue(event.payload, "cwd")) |cwd| pane.status.setCwd(cwd);
                    if (integration.jsonIntValue(u8, event.payload, "status")) |value| pane.status.last_status = value;
                    if (integration.jsonIntValue(i64, event.payload, "duration_ms")) |value| pane.status.last_duration_ms = value;
                },
                .unknown => {},
            }
        }
    }

    fn updateTitle(self: *App) void {
        const hwnd = self.hwnd orelse return;
        const pane = self.activePane();
        var title: [512]u8 = undefined;
        const cwd = if (pane.status.cwd_len > 0) pane.status.cwdSlice() else "starting";
        const state = if (pane.startup_error_len > 0) "needs setup" else if (!pane.status.ready) "starting" else if (pane.status.last_status) |value| statusName(value) else "ready";
        const text = std.fmt.bufPrint(&title, "ZiggyZag - {s} - {s}", .{ cwd, state }) catch "ZiggyZag";
        var wide: [512]WCHAR = undefined;
        const len = utf8ToWide(text, &wide);
        wide[len] = 0;
        _ = SetWindowTextW(hwnd, @ptrCast(&wide));
    }

    fn requestUiRefresh(self: *App) void {
        const hwnd = self.hwnd orelse return;
        _ = PostMessageW(hwnd, WM_APP_OUTPUT_READY, 0, 0);
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
    app.applyConfiguredSessionLayout();
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
    app.startConfiguredPanes(hwnd);

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

fn readLoop(app: *App, pane: *Pane, output_read: HANDLE) void {
    var parser = integration.Parser.init(std.heap.page_allocator);
    defer parser.deinit();

    var buffer: [8192]u8 = undefined;
    while (pane.running.load(.acquire)) {
        var available: DWORD = 0;
        if (PeekNamedPipe(output_read, null, 0, null, &available, null) == 0) break;
        if (available == 0) {
            Sleep(16);
            continue;
        }

        var read: DWORD = 0;
        const requested: DWORD = @intCast(@min(buffer.len, available));
        if (ReadFile(output_read, &buffer, requested, &read, null) == 0 or read == 0) break;

        var extracted = parser.feed(buffer[0..read]) catch continue;
        defer extracted.deinit(std.heap.page_allocator);

        app.mutex.lock();
        app.resetPaneScroll(pane);
        pane.grid.feed(extracted.display);
        app.handleEvents(pane, extracted.events.items);
        app.mutex.unlock();

        app.requestUiRefresh();
    }

    var extracted = parser.flush() catch return;
    defer extracted.deinit(std.heap.page_allocator);
    if (extracted.display.len > 0 or extracted.events.items.len > 0) {
        app.mutex.lock();
        app.resetPaneScroll(pane);
        pane.grid.feed(extracted.display);
        app.handleEvents(pane, extracted.events.items);
        app.mutex.unlock();

        app.requestUiRefresh();
    }
}

fn agentReadLoop(app: *App, stdout_file: std.Io.File) void {
    var file = stdout_file;
    defer file.close(app.io);

    var buffer: [2048]u8 = undefined;
    var reader = file.readerStreaming(app.io, &buffer);
    while (app.agent_running.load(.acquire)) {
        const chunk = reader.interface.take(1) catch break;
        if (chunk.len == 0) break;
        app.appendAgentTranscript(chunk);
        if (chunk[0] == '\n') app.requestUiRefresh();
    }
    app.requestUiRefresh();
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
        WM_APP_OUTPUT_READY => {
            app.mutex.lock();
            app.updateTitle();
            app.mutex.unlock();
            _ = InvalidateRect(hwnd, null, 0);
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
    if (app.overlay == .command_palette or app.overlay == .search) {
        switch (char) {
            '\r', 0x1b, 0x08, 0x03, 0x16 => {},
            else => app.appendOverlayChar(char),
        }
        if (app.hwnd) |hwnd| _ = InvalidateRect(hwnd, null, 0);
        return;
    }

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
    if (app.overlay != .none and app.overlay != .settings) {
        switch (wparam) {
            VK_ESCAPE => {
                app.closeOverlay();
                _ = InvalidateRect(hwnd, null, 0);
                return true;
            },
            VK_RETURN => {
                app.acceptOverlay(hwnd);
                _ = InvalidateRect(hwnd, null, 0);
                return true;
            },
            VK_BACK => {
                app.overlayBackspace();
                _ = InvalidateRect(hwnd, null, 0);
                return true;
            },
            VK_UP => {
                app.overlayMove(-1);
                _ = InvalidateRect(hwnd, null, 0);
                return true;
            },
            VK_DOWN => {
                app.overlayMove(1);
                _ = InvalidateRect(hwnd, null, 0);
                return true;
            },
            else => {},
        }
    }

    if (keyDown(VK_CONTROL) and keyDown(VK_SHIFT) and wparam == VK_P) {
        app.openPalette();
        _ = InvalidateRect(hwnd, null, 0);
        return true;
    }
    if (keyDown(VK_CONTROL) and keyDown(VK_SHIFT) and wparam == VK_A) {
        app.dispatchAction(hwnd, .open_agent_panel);
        return true;
    }
    if (keyDown(VK_CONTROL) and keyDown(VK_SHIFT) and wparam == VK_F) {
        app.openSearch();
        _ = InvalidateRect(hwnd, null, 0);
        return true;
    }
    if (keyDown(VK_CONTROL) and keyDown(VK_SHIFT) and wparam == VK_D) {
        app.dispatchAction(hwnd, .split_vertical);
        return true;
    }
    if (keyDown(VK_CONTROL) and keyDown(VK_SHIFT) and wparam == VK_E) {
        app.dispatchAction(hwnd, .split_horizontal);
        return true;
    }
    if (keyDown(VK_CONTROL) and keyDown(VK_SHIFT) and wparam == VK_N) {
        app.dispatchAction(hwnd, .focus_next_pane);
        return true;
    }
    if (keyDown(VK_CONTROL) and keyDown(VK_SHIFT) and wparam == VK_W) {
        app.dispatchAction(hwnd, .close_pane);
        return true;
    }
    if (keyDown(VK_CONTROL) and keyDown(VK_SHIFT) and wparam == VK_O) {
        app.openQuickSelect();
        _ = InvalidateRect(hwnd, null, 0);
        return true;
    }
    if (keyDown(VK_CONTROL) and keyDown(VK_SHIFT) and wparam == VK_R) {
        app.dispatchAction(hwnd, .reload_config);
        return true;
    }
    if (keyDown(VK_CONTROL) and wparam == VK_OEM_COMMA) {
        app.dispatchAction(hwnd, .toggle_settings);
        _ = InvalidateRect(hwnd, null, 0);
        return true;
    }
    if (keyDown(VK_CONTROL) and keyDown(VK_SHIFT) and wparam == VK_T) {
        app.dispatchAction(hwnd, .next_theme);
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

    const application_cursor = app.applicationCursorEnabled();
    switch (wparam) {
        VK_UP => app.writeInput(if (application_cursor) "\x1bOA" else "\x1b[A"),
        VK_DOWN => app.writeInput(if (application_cursor) "\x1bOB" else "\x1b[B"),
        VK_RIGHT => app.writeInput(if (application_cursor) "\x1bOC" else "\x1b[C"),
        VK_LEFT => app.writeInput(if (application_cursor) "\x1bOD" else "\x1b[D"),
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
        if (cell.codepoint != ' ' or !styleIsDefault(cell.style)) break;
    }
    return end;
}

fn styleIsDefault(style: terminal.Style) bool {
    return std.meta.eql(style, terminal.Style{});
}

fn styleEql(left: terminal.Style, right: terminal.Style) bool {
    return std.meta.eql(left, right);
}

fn styleForeground(selected_theme: theme.Theme, style: terminal.Style) theme.Color {
    if (style.hidden) return selected_theme.background;
    const source = if (style.inverse) style.background() else style.foreground();
    const default = if (style.inverse) selected_theme.background else selected_theme.foreground;
    var color = terminalExtendedColor(selected_theme, source) orelse default;
    if (style.dim) color = scaleColor(color, 65);
    if (style.bold and style.fg == .default and style.fg_extended == null) color = brightenColor(color);
    return color;
}

fn styleBackground(selected_theme: theme.Theme, style: terminal.Style) theme.Color {
    const source = if (style.inverse) style.foreground() else style.background();
    const default = if (style.inverse) selected_theme.foreground else selected_theme.background;
    return terminalExtendedColor(selected_theme, source) orelse default;
}

fn terminalExtendedColor(selected_theme: theme.Theme, color: terminal.ExtendedColor) ?theme.Color {
    return switch (color) {
        .named => |named| terminalColor(selected_theme, named),
        .rgb => |rgb| theme.Color.rgb(rgb.r, rgb.g, rgb.b),
        .indexed => |index| indexedTerminalColor(selected_theme, index),
    };
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

fn indexedTerminalColor(selected_theme: theme.Theme, index: u8) theme.Color {
    if (index < 16) return selected_theme.ansi[@intCast(index)];
    if (index >= 232) {
        const level: u8 = @intCast(8 + @as(u16, index - 232) * 10);
        return theme.Color.rgb(level, level, level);
    }
    const cube_index = index - 16;
    const r = colorCubeComponent(cube_index / 36);
    const g = colorCubeComponent((cube_index / 6) % 6);
    const b = colorCubeComponent(cube_index % 6);
    return theme.Color.rgb(r, g, b);
}

fn colorCubeComponent(value: u8) u8 {
    return if (value == 0) 0 else @intCast(55 + @as(u16, value) * 40);
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

fn cellCodepointToWide(codepoint: u21, out: []WCHAR) usize {
    if (codepoint <= 0xffff) {
        if (out.len == 0) return 0;
        out[0] = @intCast(codepoint);
        return 1;
    }
    if (out.len < 2) return 0;
    const value = codepoint - 0x10000;
    out[0] = @intCast(0xd800 + (value >> 10));
    out[1] = @intCast(0xdc00 + (value & 0x3ff));
    return 2;
}

fn statusName(status: u8) []const u8 {
    return if (status == 0) "ok" else "failed";
}

fn statusContext(buffer: []u8, status: Status) []const u8 {
    var index: usize = 0;
    if (status.project_kind_len > 0) {
        appendFmtBounded(buffer, &index, "  |  project:{s}", .{status.projectKindSlice()});
    }
    if (status.git_branch_len > 0) {
        appendFmtBounded(buffer, &index, "  |  git:{s}", .{status.gitBranchSlice()});
        appendGitCounts(buffer, &index, status);
    }
    if (status.jobs > 0) {
        appendFmtBounded(buffer, &index, "  |  jobs:{d}", .{status.jobs});
    }
    return buffer[0..index];
}

fn shortGitContext(buffer: []u8, status: Status) []const u8 {
    var index: usize = 0;
    if (status.git_branch_len > 0) {
        appendFmtBounded(buffer, &index, "  |  git:{s}", .{status.gitBranchSlice()});
        if (status.gitDirtyCount() > 0) appendFmtBounded(buffer, &index, "*", .{});
        if (status.git_ahead > 0) appendFmtBounded(buffer, &index, " >{d}", .{status.git_ahead});
        if (status.git_behind > 0) appendFmtBounded(buffer, &index, " <{d}", .{status.git_behind});
    }
    return buffer[0..index];
}

fn appendGitCounts(buffer: []u8, index: *usize, status: Status) void {
    if (status.git_staged > 0) appendFmtBounded(buffer, index, " +{d}", .{status.git_staged});
    if (status.git_changed > 0) appendFmtBounded(buffer, index, " ~{d}", .{status.git_changed});
    if (status.git_untracked > 0) appendFmtBounded(buffer, index, " ?{d}", .{status.git_untracked});
    if (status.git_conflicts > 0) appendFmtBounded(buffer, index, " !{d}", .{status.git_conflicts});
    if (status.git_ahead > 0) appendFmtBounded(buffer, index, " >{d}", .{status.git_ahead});
    if (status.git_behind > 0) appendFmtBounded(buffer, index, " <{d}", .{status.git_behind});
}

fn appendFmtBounded(buffer: []u8, index: *usize, comptime fmt: []const u8, args: anytype) void {
    if (index.* >= buffer.len) return;
    const written = std.fmt.bufPrint(buffer[index.*..], fmt, args) catch |err| switch (err) {
        error.NoSpaceLeft => {
            index.* = buffer.len;
            return;
        },
    };
    index.* += written.len;
}

fn appendBounded(buffer: []u8, index: *usize, value: []const u8) void {
    if (index.* >= buffer.len) return;
    const len = @min(value.len, buffer.len - index.*);
    @memcpy(buffer[index.* .. index.* + len], value[0..len]);
    index.* += len;
}

fn copyBounded(buffer: []u8, value: []const u8) usize {
    const len = @min(buffer.len, value.len);
    @memcpy(buffer[0..len], value[0..len]);
    return len;
}

fn appendCellsText(allocator: Allocator, out: *std.ArrayList(u8), cells: []const terminal.Cell) !void {
    const end = visibleCellEnd(cells);
    const text = try terminal.cellsTextAlloc(allocator, cells[0..end]);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCase(haystack, needle) != null;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        var matched = true;
        var offset: usize = 0;
        while (offset < needle.len) : (offset += 1) {
            if (std.ascii.toLower(haystack[index + offset]) != std.ascii.toLower(needle[offset])) {
                matched = false;
                break;
            }
        }
        if (matched) return index;
    }
    return null;
}

fn countByte(bytes: []const u8, byte: u8) usize {
    var count: usize = 0;
    for (bytes) |candidate| {
        if (candidate == byte) count += 1;
    }
    return count;
}

fn isTokenSeparator(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == '"' or byte == '\'' or byte == '<' or byte == '>' or byte == '[' or byte == ']';
}

fn trimQuickToken(token: []const u8) []const u8 {
    return std.mem.trim(u8, token, " \t\r\n.,;:(){}");
}

fn isQuickToken(token: []const u8) bool {
    if (token.len < 4) return false;
    if (std.mem.startsWith(u8, token, "http://") or std.mem.startsWith(u8, token, "https://")) return true;
    if (std.mem.indexOfScalar(u8, token, '\\') != null or std.mem.indexOfScalar(u8, token, '/') != null) return true;
    if (looksLikeIssueKey(token) or looksLikeHexHash(token)) return true;
    return false;
}

fn looksLikeIssueKey(token: []const u8) bool {
    const dash = std.mem.indexOfScalar(u8, token, '-') orelse return false;
    if (dash == 0 or dash + 1 >= token.len) return false;
    for (token[0..dash]) |byte| {
        if (!std.ascii.isUpper(byte)) return false;
    }
    for (token[dash + 1 ..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn looksLikeHexHash(token: []const u8) bool {
    if (token.len < 7 or token.len > 64) return false;
    for (token) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f') and !(byte >= 'A' and byte <= 'F')) return false;
    }
    return true;
}
