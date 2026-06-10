//! macOS Cocoa native terminal window host for ZiggyZag (Wave 3).
//!
//! Creates an NSWindow containing a custom NSView subclass (ZZTermView),
//! spawns the shell via POSIX PTY, feeds output through terminal.Grid, and
//! renders each cell using Core Text.  A detached POSIX thread drives the
//! PTY read loop; an NSTimer at 60 fps flushes the dirty flag and calls
//! setNeedsDisplay on the main thread.
//!
//! Entry point: run(init_data, shell_path)
//! Called from posix_app.runNativeWindow() when ZIGGYZAG_NATIVE_WINDOW is set.

const std       = @import("std");
const builtin   = @import("builtin");
const posix_pty = @import("posix_pty.zig");
const terminal  = @import("terminal.zig");

comptime {
    if (builtin.os.tag != .macos) @compileError("macos_app.zig is macOS-only");
}

const Allocator = std.mem.Allocator;

// Spin-lock using std.atomic.Mutex (Zig 0.16 has no std.Thread.Mutex).
const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *SpinLock) void { while (!self.state.tryLock()) {} }
    fn unlock(self: *SpinLock) void { self.state.unlock(); }
};

// ── ObjC runtime (parses cleanly with Zig's C translator) ─────────────────
const objc = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

// ── Manual CoreFoundation / CoreGraphics / CoreText declarations ───────────
//
// The CoreGraphics umbrella header includes files with ObjC block syntax (^)
// and nullability specifiers on array parameters, both of which Zig 0.16's
// @cImport translator cannot handle.  We declare only the narrow slice we
// actually call; the symbols are resolved at link time from the frameworks.

const CGFloat = f64;
const CFIndex = c_long;
const CGGlyph = u16; // typedef uint16_t CGGlyph (CoreGraphics/CGFont.h)

const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize  = extern struct { width: CGFloat, height: CGFloat };
const CGRect  = extern struct { origin: CGPoint, size: CGSize };
const CGAffineTransform = extern struct {
    a: CGFloat, b: CGFloat,
    // field named 'c' in the C struct; accessed as .@"c" in Zig to avoid
    // ambiguity with the local namespace alias
    @"c": CGFloat, d: CGFloat,
    tx: CGFloat, ty: CGFloat,
};

// Opaque CF / CG / CT types
const CGContextRef  = *anyopaque;
const CTFontRef     = *anyopaque;
const CFAllocatorRef = ?*anyopaque;
const CFStringRef    = ?*anyopaque;
const CFTypeRef      = ?*anyopaque;
const kCFStringEncodingUTF8: u32 = 0x08000100;
const kCTFontOrientationDefault: u32 = 0;

// CoreFoundation
extern fn CFStringCreateWithCString(alloc: CFAllocatorRef, cStr: [*:0]const u8, encoding: u32) CFStringRef;
extern fn CFRelease(cf: CFTypeRef) void;

// CoreGraphics
extern fn CGContextSetRGBFillColor(ctx: CGContextRef, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
extern fn CGContextFillRect(ctx: CGContextRef, rect: CGRect) void;
extern fn CGContextSetTextMatrix(ctx: CGContextRef, t: CGAffineTransform) void;
extern fn CGAffineTransformMakeScale(sx: CGFloat, sy: CGFloat) CGAffineTransform;

// CoreText
extern fn CTFontCreateWithName(name: CFStringRef, size: CGFloat, matrix: ?*const CGAffineTransform) CTFontRef;
extern fn CTFontGetAscent(font: CTFontRef) CGFloat;
extern fn CTFontGetDescent(font: CTFontRef) CGFloat;
extern fn CTFontGetLeading(font: CTFontRef) CGFloat;
extern fn CTFontGetAdvancesForGlyphs(font: CTFontRef, orientation: u32, glyphs: *const CGGlyph, advances: ?*CGSize, count: CFIndex) f64;
extern fn CTFontGetGlyphsForCharacters(font: CTFontRef, characters: *const u16, glyphs: *CGGlyph, count: CFIndex) bool;
extern fn CTFontDrawGlyphs(font: CTFontRef, glyphs: *const CGGlyph, positions: *const CGPoint, count: usize, context: CGContextRef) void;

// ── Opaque handle types ────────────────────────────────────────────────────
const ID  = ?*anyopaque;
const SEL = ?*anyopaque;
const CLS = ?*anyopaque;

// NSWindowStyleMask bits
const NSTitled         : c_ulong = 1;
const NSClosable       : c_ulong = 2;
const NSMiniaturizable : c_ulong = 4;
const NSResizable      : c_ulong = 8;
const NSBackingStoreBuffered: c_ulong = 2;

// Terminal grid dimensions (fixed for Wave 3)
const COLS: u16 = 80;
const ROWS: u16 = 24;

// ── Typed objc_msgSend wrappers ────────────────────────────────────────────
//
// objc_msgSend is declared variadic in C.  On arm64 the variadic ABI differs
// from the fixed-arg ABI for non-integer/non-pointer arguments (structs,
// doubles).  Casting to the exact concrete function type for every call site
// forces the compiler to generate correct register assignments.

inline fn cls(name: [*:0]const u8) CLS { return @ptrCast(objc.objc_getClass(name)); }
inline fn sel(name: [*:0]const u8) SEL { return @ptrCast(objc.sel_registerName(name)); }

// ObjC class registration wrappers that bridge ?*anyopaque ↔ objc cimport types.
fn allocClass(superclass: CLS, name: [*:0]const u8) CLS {
    return @ptrCast(objc.objc_allocateClassPair(@ptrCast(superclass), name, 0));
}
fn addClass(klass: CLS, s: SEL, imp: anytype, types: [*:0]const u8) void {
    _ = objc.class_addMethod(@ptrCast(klass), @ptrCast(s), @ptrCast(imp), types);
}
fn registerClass(klass: CLS) void {
    objc.objc_registerClassPair(@ptrCast(klass));
}

fn msg0(recv: ID, s: SEL) ID {
    return (@as(*const fn (ID, SEL) callconv(.c) ID, @ptrCast(&objc.objc_msgSend)))(recv, s);
}
fn msg0v(recv: ID, s: SEL) void {
    (@as(*const fn (ID, SEL) callconv(.c) void, @ptrCast(&objc.objc_msgSend)))(recv, s);
}
fn msg1(recv: ID, s: SEL, a: ID) ID {
    return (@as(*const fn (ID, SEL, ID) callconv(.c) ID, @ptrCast(&objc.objc_msgSend)))(recv, s, a);
}
fn msg1v(recv: ID, s: SEL, a: ID) void {
    (@as(*const fn (ID, SEL, ID) callconv(.c) void, @ptrCast(&objc.objc_msgSend)))(recv, s, a);
}
fn msg1bv(recv: ID, s: SEL, b: u8) void {
    (@as(*const fn (ID, SEL, u8) callconv(.c) void, @ptrCast(&objc.objc_msgSend)))(recv, s, b);
}
fn msg1lv(recv: ID, s: SEL, l: c_long) void {
    (@as(*const fn (ID, SEL, c_long) callconv(.c) void, @ptrCast(&objc.objc_msgSend)))(recv, s, l);
}
fn msgRect(recv: ID, s: SEL, r: CGRect) ID {
    return (@as(*const fn (ID, SEL, CGRect) callconv(.c) ID, @ptrCast(&objc.objc_msgSend)))(recv, s, r);
}
fn msgInitWindow(recv: ID, s: SEL, r: CGRect, style: c_ulong, backing: c_ulong, defer_: u8) ID {
    return (@as(*const fn (ID, SEL, CGRect, c_ulong, c_ulong, u8) callconv(.c) ID,
        @ptrCast(&objc.objc_msgSend)))(recv, s, r, style, backing, defer_);
}
fn msgTimer(recv: CLS, s: SEL, interval: f64, target: ID, action: SEL, userinfo: ID, repeats: u8) ID {
    return (@as(*const fn (CLS, SEL, f64, ID, SEL, ID, u8) callconv(.c) ID,
        @ptrCast(&objc.objc_msgSend)))(recv, s, interval, target, action, userinfo, repeats);
}
fn msgCGContext(recv: ID, s: SEL) CGContextRef {
    return (@as(*const fn (ID, SEL) callconv(.c) CGContextRef, @ptrCast(&objc.objc_msgSend)))(recv, s);
}
fn msgKeyCode(recv: ID, s: SEL) u16 {
    return (@as(*const fn (ID, SEL) callconv(.c) u16, @ptrCast(&objc.objc_msgSend)))(recv, s);
}
fn msgCStr(recv: ID, s: SEL) ?[*:0]const u8 {
    return (@as(*const fn (ID, SEL) callconv(.c) ?[*:0]const u8, @ptrCast(&objc.objc_msgSend)))(recv, s);
}

fn cfString(s: [*:0]const u8) ID {
    return CFStringCreateWithCString(null, s, kCFStringEncodingUTF8);
}

// ── Application state ──────────────────────────────────────────────────────

const AppState = struct {
    allocator:   Allocator,
    grid:        terminal.Grid,
    session:     posix_pty.Session,
    mutex:       SpinLock                      = .{},
    dirty:       std.atomic.Value(bool)       = std.atomic.Value(bool).init(false),
    running:     std.atomic.Value(bool)       = std.atomic.Value(bool).init(true),
    view_obj:    ID                           = null,
    font:        ?CTFontRef                   = null,
    cell_w:      f64                          = 8,
    cell_h:      f64                          = 16,
    cell_ascent: f64                          = 12,
};

// Single-window app: one global state pointer shared with ObjC callbacks.
var g_state: ?*AppState = null;

// ── ZZTermView ObjC callbacks ──────────────────────────────────────────────

fn viewAcceptsFirstResponder(_: ID, _: SEL) callconv(.c) u8 { return 1; }

// isFlipped=YES puts the origin at the top-left of the view, matching row 0
// of the terminal grid.  We must also flip the text matrix when drawing.
fn viewIsFlipped(_: ID, _: SEL) callconv(.c) u8 { return 1; }

// drawRect:(NSRect)rect
// With isFlipped=YES the CTM is already set up so y=0 is the top of the view.
// CGRect on arm64 is an HFA of 4 doubles; the ABI passes it in d0-d3.
fn viewDrawRect(_: ID, _: SEL, rect: CGRect) callconv(.c) void {
    _ = rect;
    const state = g_state orelse return;

    // NSGraphicsContext.currentContext.CGContext
    const gc = msg0(cls("NSGraphicsContext"), sel("currentContext"));
    if (gc == null) return;
    const ctx = msgCGContext(gc, sel("CGContext"));

    state.mutex.lock();
    defer state.mutex.unlock();

    const grid  = &state.grid;
    const cw    = state.cell_w;
    const ch    = state.cell_h;
    const asc   = state.cell_ascent;
    const total_w = cw * @as(f64, @floatFromInt(grid.width));
    const total_h = ch * @as(f64, @floatFromInt(grid.height));

    // Fill background
    CGContextSetRGBFillColor(ctx, 0.06, 0.06, 0.09, 1.0);
    CGContextFillRect(ctx, .{
        .origin = .{ .x = 0, .y = 0 },
        .size   = .{ .width = total_w, .height = total_h },
    });

    const font = state.font orelse return;

    // CTFontDrawGlyphs uses the text matrix, not the CTM.  Counter-flip so
    // glyphs render right-side-up inside the already-flipped CTM.
    CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1.0, -1.0));

    for (0..grid.height) |row| {
        // In a flipped view, row 0 is at y=0 and increases downward.
        const row_top = ch * @as(f64, @floatFromInt(row));
        const baseline = row_top + asc;

        for (0..grid.width) |col| {
            const cell = grid.cells[row * grid.width + col];
            if (cell.isContinuation()) continue;

            const cp = cell.codepoint;
            const px = cw * @as(f64, @floatFromInt(col));

            // Coloured cell background (skip default to avoid overdrawing)
            if (cell.style.bg != .default) {
                const bg = namedColor(cell.style.bg, false);
                CGContextSetRGBFillColor(ctx, bg[0], bg[1], bg[2], 1.0);
                CGContextFillRect(ctx, .{
                    .origin = .{ .x = px, .y = row_top },
                    .size   = .{ .width = cw, .height = ch },
                });
            }

            if (cp == 0 or cp == ' ') continue;
            if (cp > 0xFFFF) continue; // BMP only for Wave 3

            var uni: u16 = @intCast(cp);
            var glyph: CGGlyph = 0;
            if (!CTFontGetGlyphsForCharacters(font, &uni, &glyph, 1)) continue;
            if (glyph == 0) continue;

            const fg = namedColor(cell.style.fg, true);
            CGContextSetRGBFillColor(ctx, fg[0], fg[1], fg[2], 1.0);
            const pt = CGPoint{ .x = px, .y = baseline };
            CTFontDrawGlyphs(font, &glyph, &pt, 1, ctx);
        }
    }

    // Block cursor
    const cx = cw * @as(f64, @floatFromInt(grid.cursor_x));
    const cy = ch * @as(f64, @floatFromInt(grid.cursor_y));
    CGContextSetRGBFillColor(ctx, 0.9, 0.9, 0.9, 0.55);
    CGContextFillRect(ctx, .{
        .origin = .{ .x = cx, .y = cy },
        .size   = .{ .width = cw, .height = ch },
    });
}

// keyDown:(NSEvent*)event
fn viewKeyDown(_: ID, _: SEL, event_obj: ID) callconv(.c) void {
    const state = g_state orelse return;
    if (!state.running.load(.monotonic)) return;

    // Intercept arrow keys and a handful of special keys by USB HID key code.
    // NSEvent.characters cannot encode these unambiguously.
    const kc = msgKeyCode(event_obj, sel("keyCode"));
    const special: ?[]const u8 = switch (kc) {
        0x7E => "\x1b[A",  // Up
        0x7D => "\x1b[B",  // Down
        0x7C => "\x1b[C",  // Right
        0x7B => "\x1b[D",  // Left
        0x35 => "\x1b",    // Escape
        0x33 => "\x7f",    // Delete → DEL (BSP sends 127 in xterm-256color)
        0x24, 0x4C => "\r", // Return / numpad Enter
        else => null,
    };
    if (special) |bytes| {
        posix_pty.writeAll(state.session.master_fd, bytes) catch {};
        return;
    }

    // Regular printable characters via NSEvent.characters
    const ns_chars = msg1(event_obj, sel("characters"), null);
    if (ns_chars == null) return;
    if (msgCStr(ns_chars, sel("UTF8String"))) |ptr| {
        const bytes = std.mem.sliceTo(ptr, 0);
        if (bytes.len > 0) posix_pty.writeAll(state.session.master_fd, bytes) catch {};
    }
}

// ── AppDelegate ObjC callbacks ─────────────────────────────────────────────

fn delegateDidFinishLaunching(self_obj: ID, _: SEL, _: ID) callconv(.c) void {
    const state = g_state orelse return;

    // Load Menlo and compute cell metrics
    const font_name_cf = cfString("Menlo-Regular");
    defer CFRelease(font_name_cf);
    state.font = CTFontCreateWithName(font_name_cf, 14.0, null);

    if (state.font) |font| {
        state.cell_ascent = CTFontGetAscent(font);
        state.cell_h = state.cell_ascent
            + CTFontGetDescent(font)
            + CTFontGetLeading(font);

        var uni_m: u16 = 'M';
        var glyph_m: CGGlyph = 0;
        if (CTFontGetGlyphsForCharacters(font, &uni_m, &glyph_m, 1)) {
            var adv: CGSize = .{ .width = 0, .height = 0 };
            _ = CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault, &glyph_m, &adv, 1);
            state.cell_w = adv.width;
        }
    }

    const win_w = state.cell_w * @as(f64, @floatFromInt(COLS));
    const win_h = state.cell_h * @as(f64, @floatFromInt(ROWS));

    // Create NSWindow
    const win = msgInitWindow(
        msg0(cls("NSWindow"), sel("alloc")),
        sel("initWithContentRect:styleMask:backing:defer:"),
        .{ .origin = .{ .x = 120, .y = 120 }, .size = .{ .width = win_w, .height = win_h } },
        NSTitled | NSClosable | NSMiniaturizable | NSResizable,
        NSBackingStoreBuffered,
        0,
    );
    const title_cf = cfString("ZiggyZag");
    defer if (title_cf) |t| CFRelease(t);
    msg1v(win, sel("setTitle:"), title_cf);
    msg1v(win, sel("setDelegate:"), self_obj);

    // Create ZZTermView and attach to window
    const view = msgRect(
        msg0(cls("ZZTermView"), sel("alloc")),
        sel("initWithFrame:"),
        .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = win_w, .height = win_h } },
    );
    state.view_obj = view;
    msg1v(win, sel("setContentView:"), view);
    msg1v(win, sel("makeFirstResponder:"), view);
    msg1v(win, sel("makeKeyAndOrderFront:"), null);

    // Resize PTY to match the logical grid
    state.session.resize(.{ .rows = ROWS, .cols = COLS }) catch {};

    // Start PTY reader thread
    const t = std.Thread.spawn(.{}, readerLoop, .{state}) catch return;
    t.detach();

    // 60-fps refresh timer on the run loop
    _ = msgTimer(
        cls("NSTimer"),
        sel("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
        1.0 / 60.0, self_obj, sel("refreshTick:"), null, 1,
    );

    const app = msg0(cls("NSApplication"), sel("sharedApplication"));
    msg1bv(app, sel("activateIgnoringOtherApps:"), 1);
}

// NSTimer callback — runs on the main thread at 60 fps
fn delegateRefreshTick(self_obj: ID, _: SEL, _: ID) callconv(.c) void {
    const state = g_state orelse return;
    if (!state.running.load(.monotonic)) {
        // Shell exited: terminate the app event loop
        const app = msg0(cls("NSApplication"), sel("sharedApplication"));
        msg1v(app, sel("terminate:"), self_obj);
        return;
    }
    if (state.dirty.swap(false, .monotonic)) {
        if (state.view_obj) |v| msg1bv(v, sel("setNeedsDisplay:"), 1);
    }
}

// NSWindowDelegate: windowWillClose:
fn delegateWindowWillClose(self_obj: ID, _: SEL, _: ID) callconv(.c) void {
    const state = g_state orelse return;
    state.running.store(false, .monotonic);
    const app = msg0(cls("NSApplication"), sel("sharedApplication"));
    msg1v(app, sel("terminate:"), self_obj);
}

// ── PTY reader thread ──────────────────────────────────────────────────────

fn readerLoop(state: *AppState) void {
    var buf: [4096]u8 = undefined;
    loop: while (state.running.load(.monotonic)) {
        var fds = [1]posix_pty.PollFd{.{
            .fd      = state.session.master_fd,
            .events  = posix_pty.PollEvent.input,
            .revents = 0,
        }};
        const ready = posix_pty.poll(&fds, 50) catch break :loop;
        if (ready == 0) continue;
        if ((fds[0].revents & posix_pty.PollEvent.error_or_hangup) != 0) break :loop;
        if ((fds[0].revents & posix_pty.PollEvent.input) == 0) continue;

        const n = posix_pty.readFd(state.session.master_fd, &buf) catch break :loop;
        if (n == 0) break :loop;

        state.mutex.lock();
        state.grid.feed(buf[0..n]);
        state.mutex.unlock();

        state.dirty.store(true, .monotonic);
    }
    state.running.store(false, .monotonic);
}

// ── 16-colour ANSI palette ─────────────────────────────────────────────────

fn namedColor(color: terminal.Color, is_fg: bool) [3]f64 {
    return switch (color) {
        .default        => if (is_fg) .{ 0.85, 0.85, 0.85 } else .{ 0.0, 0.0, 0.0 },
        .black          => .{ 0.07, 0.07, 0.07 },
        .red            => .{ 0.80, 0.20, 0.20 },
        .green          => .{ 0.20, 0.70, 0.20 },
        .yellow         => .{ 0.80, 0.70, 0.10 },
        .blue           => .{ 0.25, 0.45, 0.85 },
        .magenta        => .{ 0.70, 0.20, 0.70 },
        .cyan           => .{ 0.20, 0.70, 0.70 },
        .white          => .{ 0.80, 0.80, 0.80 },
        .bright_black   => .{ 0.40, 0.40, 0.40 },
        .bright_red     => .{ 1.00, 0.40, 0.40 },
        .bright_green   => .{ 0.40, 1.00, 0.40 },
        .bright_yellow  => .{ 1.00, 1.00, 0.40 },
        .bright_blue    => .{ 0.40, 0.60, 1.00 },
        .bright_magenta => .{ 1.00, 0.40, 1.00 },
        .bright_cyan    => .{ 0.40, 1.00, 1.00 },
        .bright_white   => .{ 1.00, 1.00, 1.00 },
    };
}

// ── Entry point ────────────────────────────────────────────────────────────

pub fn run(init_data: std.process.Init, shell_path: []const u8) !void {
    const allocator = init_data.gpa;

    // Env setup (mirrors posix_app.run)
    try init_data.environ_map.put("ZIGGYZAG_APP", "1");
    try init_data.environ_map.put("ZIGGYZAG_INTEGRATION", "1");
    if (init_data.environ_map.get("TERM") == null)
        try init_data.environ_map.put("TERM", "xterm-256color");
    if (init_data.environ_map.get("ZIGGYZAG_THEME") == null)
        try init_data.environ_map.put("ZIGGYZAG_THEME", "ziggy");

    const shell_path_z = try allocator.dupeZ(u8, shell_path);
    defer allocator.free(shell_path_z);

    const env_block = try init_data.environ_map.createPosixBlock(allocator, .{});
    defer env_block.deinit(allocator);

    // Spawn PTY + shell
    const argv = [_:null]?[*:0]const u8{shell_path_z.ptr};
    var session = try posix_pty.spawnShell(.{
        .shell_path = shell_path_z.ptr,
        .argv       = &argv,
        .envp       = env_block.slice.ptr,
        .size       = .{ .rows = ROWS, .cols = COLS },
    });
    errdefer session.closeMaster();

    var grid = try terminal.Grid.init(allocator, COLS, ROWS);
    errdefer grid.deinit();

    // Heap-allocate state so ObjC callbacks have a stable pointer.
    const state = try allocator.create(AppState);
    errdefer allocator.destroy(state);
    state.* = .{
        .allocator = allocator,
        .grid      = grid,
        .session   = session,
    };
    g_state = state;

    // ── Register ZZTermView ────────────────────────────────────────────────
    const view_cls = allocClass(cls("NSView"), "ZZTermView");
    if (view_cls != null) {
        addClass(view_cls, sel("acceptsFirstResponder"),
            &viewAcceptsFirstResponder, "B@:");
        addClass(view_cls, sel("isFlipped"),
            &viewIsFlipped, "B@:");
        addClass(view_cls, sel("drawRect:"),
            &viewDrawRect,
            "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
        addClass(view_cls, sel("keyDown:"),
            &viewKeyDown, "v@:@");
        registerClass(view_cls);
    }

    // ── Register ZZAppDelegate ─────────────────────────────────────────────
    const del_cls = allocClass(cls("NSObject"), "ZZAppDelegate");
    if (del_cls != null) {
        addClass(del_cls,
            sel("applicationDidFinishLaunching:"),
            &delegateDidFinishLaunching, "v@:@");
        addClass(del_cls,
            sel("refreshTick:"),
            &delegateRefreshTick, "v@:@");
        addClass(del_cls,
            sel("windowWillClose:"),
            &delegateWindowWillClose, "v@:@");
        registerClass(del_cls);
    }

    // ── Boot NSApplication ─────────────────────────────────────────────────
    const app = msg0(cls("NSApplication"), sel("sharedApplication"));
    if (app == null) return error.NSApplicationFailed;

    msg1lv(app, sel("setActivationPolicy:"), 0); // NSApplicationActivationPolicyRegular

    const delegate = msg0(msg0(del_cls, sel("alloc")), sel("init"));
    msg1v(app, sel("setDelegate:"), delegate);

    // blocks until [NSApp terminate:] is called
    msg0v(app, sel("run"));

    // ── Cleanup (normal exit) ──────────────────────────────────────────────
    // Signal reader to stop, close the master fd (causes EIO on reader), then
    // give it 100 ms to drain before freeing the grid.
    state.running.store(false, .monotonic);
    state.session.closeMaster();
    _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 100 * std.time.ns_per_ms }, null);

    g_state = null;
    if (state.font) |f| CFRelease(f);
    state.grid.deinit();
    allocator.destroy(state);

    // errdefer for session/grid/state fired only on early error; those paths
    // return before reaching the cleanup above, so no double-free here.
}
