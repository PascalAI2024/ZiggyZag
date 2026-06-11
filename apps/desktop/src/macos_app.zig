//! macOS Cocoa native terminal window host for ZiggyZag (Wave 3+).
//!
//! Coordinate system: standard CoreGraphics (y=0 at bottom, y increases up).
//! Row 0 is the topmost visual row; its bottom edge is at y = H - cell_h.
//! This avoids the isFlipped + text-matrix-double-flip hazard that made text
//! invisible (text matrix scale(1,-1) negated glyph y-positions).
//!
//! Features: dynamic resize, mouse-wheel scrollback, Cmd+V paste,
//! Cmd+Shift+C copy visible, application-cursor arrows, Ctrl+Space AgentD
//! overlay with universal input, Ctrl+Shift+P command palette,
//! Ctrl+Shift+F search, Ctrl+Shift+O quick select, Ctrl+, settings,
//! Ctrl+Shift+T theme cycle with live OSC 7777 broadcast.
//!
//! Entry point: run(init_data, shell_path)

const std = @import("std");
const builtin = @import("builtin");
const posix_pty = @import("posix_pty.zig");
const terminal = @import("terminal.zig");
const theme_mod = @import("theme.zig");

comptime {
    if (builtin.os.tag != .macos) @compileError("macos_app.zig is macOS-only");
}

const Allocator = std.mem.Allocator;

// Spin-lock (Zig 0.16 std.atomic.Mutex).
const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *SpinLock) void {
        while (!self.state.tryLock()) {}
    }
    fn unlock(self: *SpinLock) void {
        self.state.unlock();
    }
};

// ── ObjC runtime ──────────────────────────────────────────────────────────
const objc = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

// ── CoreGraphics / CoreText forward declarations ───────────────────────────
const CGFloat = f64;
const CFIndex = c_long;
const CGGlyph = u16;

const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };
const CGAffineTransform = extern struct {
    a: CGFloat,
    b: CGFloat,
    c: CGFloat,
    d: CGFloat,
    tx: CGFloat,
    ty: CGFloat,
};

const CGContextRef = *anyopaque;
const CTFontRef = *anyopaque;
const CFAllocatorRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFTypeRef = ?*anyopaque;
const kCFStringEncodingUTF8: u32 = 0x08000100;
const kCTFontOrientationDefault: u32 = 0;

extern fn CFStringCreateWithCString(alloc: CFAllocatorRef, cStr: [*:0]const u8, encoding: u32) CFStringRef;
extern fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;
extern fn CFRelease(cf: CFTypeRef) void;

extern fn CGContextSetRGBFillColor(ctx: CGContextRef, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
extern fn CGContextFillRect(ctx: CGContextRef, rect: CGRect) void;

extern fn CTFontCreateWithName(name: CFStringRef, size: CGFloat, matrix: ?*const CGAffineTransform) CTFontRef;
extern fn CTFontGetAscent(font: CTFontRef) CGFloat;
extern fn CTFontGetDescent(font: CTFontRef) CGFloat;
extern fn CTFontGetLeading(font: CTFontRef) CGFloat;
extern fn CTFontGetAdvancesForGlyphs(font: CTFontRef, orientation: u32, glyphs: *const CGGlyph, advances: ?*CGSize, count: CFIndex) f64;
extern fn CTFontGetGlyphsForCharacters(font: CTFontRef, characters: *const u16, glyphs: *CGGlyph, count: CFIndex) bool;
extern fn CTFontDrawGlyphs(font: CTFontRef, glyphs: *const CGGlyph, positions: *const CGPoint, count: usize, context: CGContextRef) void;

// ── ObjC handle types ─────────────────────────────────────────────────────
const ID = ?*anyopaque;
const SEL = ?*anyopaque;
const CLS = ?*anyopaque;

const NSTitled: c_ulong = 1;
const NSClosable: c_ulong = 2;
const NSMiniaturizable: c_ulong = 4;
const NSResizable: c_ulong = 8;
const NSBackingStoreBuffered: c_ulong = 2;
const NSViewWidthSizable: c_ulong = 2;
const NSViewHeightSizable: c_ulong = 16;

const NSCommandKeyMask: c_ulong = 0x100000;
const NSShiftKeyMask: c_ulong = 0x020000;
const NSControlKeyMask: c_ulong = 0x040000;

// Virtual key codes (HIToolbox/Events.h)
const kVK_Space: u16 = 0x31;
const kVK_V: u16 = 0x09;
const kVK_C: u16 = 0x08;
const kVK_H: u16 = 0x04;
const kVK_I: u16 = 0x22;
const kVK_T: u16 = 0x11;
const kVK_P: u16 = 0x23;
const kVK_F: u16 = 0x03;
const kVK_O: u16 = 0x1F;
const kVK_Escape: u16 = 0x35;
const kVK_Delete: u16 = 0x33;
const kVK_Return: u16 = 0x24;
const kVK_NumEnter: u16 = 0x4C;
const kVK_Up: u16 = 0x7E;
const kVK_Down: u16 = 0x7D;
const kVK_Right: u16 = 0x7C;
const kVK_Left: u16 = 0x7B;
const kVK_PageUp: u16 = 0x74;
const kVK_PageDown: u16 = 0x79;
const kVK_Slash: u16 = 0x2C;
const kVK_Comma: u16 = 0x2B;

// ── msgSend wrappers ──────────────────────────────────────────────────────

inline fn cls(name: [*:0]const u8) CLS {
    return @ptrCast(objc.objc_getClass(name));
}
inline fn sel(name: [*:0]const u8) SEL {
    return @ptrCast(objc.sel_registerName(name));
}

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
fn msg1ulv(recv: ID, s: SEL, v: c_ulong) void {
    (@as(*const fn (ID, SEL, c_ulong) callconv(.c) void, @ptrCast(&objc.objc_msgSend)))(recv, s, v);
}
fn msgRect(recv: ID, s: SEL, r: CGRect) ID {
    return (@as(*const fn (ID, SEL, CGRect) callconv(.c) ID, @ptrCast(&objc.objc_msgSend)))(recv, s, r);
}
fn msgCGRect(recv: ID, s: SEL) CGRect {
    return (@as(*const fn (ID, SEL) callconv(.c) CGRect, @ptrCast(&objc.objc_msgSend)))(recv, s);
}
fn msgInitWindow(recv: ID, s: SEL, r: CGRect, style: c_ulong, backing: c_ulong, defer_: u8) ID {
    return (@as(*const fn (ID, SEL, CGRect, c_ulong, c_ulong, u8) callconv(.c) ID, @ptrCast(&objc.objc_msgSend)))(recv, s, r, style, backing, defer_);
}
fn msgTimer(recv: CLS, s: SEL, interval: f64, target: ID, action: SEL, userinfo: ID, repeats: u8) ID {
    return (@as(*const fn (CLS, SEL, f64, ID, SEL, ID, u8) callconv(.c) ID, @ptrCast(&objc.objc_msgSend)))(recv, s, interval, target, action, userinfo, repeats);
}
fn msgCGContext(recv: ID, s: SEL) CGContextRef {
    return (@as(*const fn (ID, SEL) callconv(.c) CGContextRef, @ptrCast(&objc.objc_msgSend)))(recv, s);
}
fn msgKeyCode(recv: ID, s: SEL) u16 {
    return (@as(*const fn (ID, SEL) callconv(.c) u16, @ptrCast(&objc.objc_msgSend)))(recv, s);
}
fn msgULong(recv: ID, s: SEL) c_ulong {
    return (@as(*const fn (ID, SEL) callconv(.c) c_ulong, @ptrCast(&objc.objc_msgSend)))(recv, s);
}
fn msgDouble(recv: ID, s: SEL) f64 {
    return (@as(*const fn (ID, SEL) callconv(.c) f64, @ptrCast(&objc.objc_msgSend)))(recv, s);
}
fn msgCStr(recv: ID, s: SEL) ?[*:0]const u8 {
    return (@as(*const fn (ID, SEL) callconv(.c) ?[*:0]const u8, @ptrCast(&objc.objc_msgSend)))(recv, s);
}

fn cfString(s: [*:0]const u8) ID {
    return CFStringCreateWithCString(null, s, kCFStringEncodingUTF8);
}

// ── Overlay system ────────────────────────────────────────────────────────

const Overlay = enum {
    none,
    settings,
    command_palette,
    search,
    quick_select,
    agent,
};

// ── Palette actions ───────────────────────────────────────────────────────

const PaletteActionKind = enum {
    copy_visible,
    paste_clipboard,
    search_scrollback,
    quick_select,
    open_agent_panel,
    agent_health,
    agent_tools,
    toggle_settings,
    next_theme,
    clear_scrollback,
};

const PaletteAction = struct {
    title: []const u8,
    detail: []const u8,
    kind: PaletteActionKind,
};

const palette_actions = [_]PaletteAction{
    .{ .title = "Copy visible text", .detail = "Copy current viewport to clipboard", .kind = .copy_visible },
    .{ .title = "Paste clipboard", .detail = "Paste clipboard text into the active shell", .kind = .paste_clipboard },
    .{ .title = "Search scrollback", .detail = "Find text in visible output and history", .kind = .search_scrollback },
    .{ .title = "Quick select", .detail = "Copy URLs, paths, issue keys, and hashes", .kind = .quick_select },
    .{ .title = "AgentD panel", .detail = "Open the local AgentD sidecar", .kind = .open_agent_panel },
    .{ .title = "AgentD health", .detail = "Ask AgentD for provider and runtime status", .kind = .agent_health },
    .{ .title = "AgentD tools", .detail = "List local tools, schemas, and approval", .kind = .agent_tools },
    .{ .title = "Settings", .detail = "Toggle settings and theme info", .kind = .toggle_settings },
    .{ .title = "Next theme", .detail = "Cycle through built-in terminal themes", .kind = .next_theme },
    .{ .title = "Clear scrollback", .detail = "Clear terminal history", .kind = .clear_scrollback },
};

// ── Quick select ──────────────────────────────────────────────────────────

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

const MAX_QUICK_ITEMS = 32;

// ── AppState ──────────────────────────────────────────────────────────────

const TRANSCRIPT_CAP: usize = 8192;
const MAX_PALETTE_QUERY: usize = 128;
const MAX_SEARCH_QUERY: usize = 128;

const AppState = struct {
    allocator: Allocator,
    grid: terminal.Grid,
    session: posix_pty.Session,
    mutex: SpinLock = .{},
    dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    view_obj: ID = null,
    font: ?CTFontRef = null,
    cell_w: f64 = 8,
    cell_h: f64 = 16,
    cell_ascent: f64 = 12,
    win_w: f64 = 640,
    win_h: f64 = 384,
    scroll_offset: i32 = 0,
    // Current overlay
    overlay: Overlay = .none,
    // Command palette
    palette_query: [MAX_PALETTE_QUERY]u8 = undefined,
    palette_query_len: usize = 0,
    palette_selected: usize = 0,
    // Search
    search_query: [MAX_SEARCH_QUERY]u8 = undefined,
    search_query_len: usize = 0,
    search_match_line: usize = 0,
    search_match_label: [128]u8 = undefined,
    search_match_label_len: usize = 0,
    // Quick select
    quick_items: [MAX_QUICK_ITEMS]QuickItem = undefined,
    quick_item_count: usize = 0,
    quick_selected: usize = 0,
    // Theme (cycles through the built-in registry)
    theme_index: usize = 0,
    // AgentD
    agentd_pid: i32 = 0,
    agentd_write_fd: i32 = -1,
    agentd_read_fd: i32 = -1,
    agentd_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    agent_next_id: u32 = 1,
    transcript: [TRANSCRIPT_CAP]u8 = undefined,
    transcript_len: usize = 0,
    // AgentD universal input state
    agent_input: [256]u8 = undefined,
    agent_input_len: usize = 0,
    agent_input_active: bool = false,
};

var g_state: ?*AppState = null;

// ── Theme helpers ─────────────────────────────────────────────────────────
// Themes are sourced from theme.zig (the single source of truth shared
// with the shell via the ZIGGYZAG_THEME env var and OSC 7777 events).

fn nextTheme(state: *AppState) void {
    state.theme_index = (state.theme_index + 1) % theme_mod.themes.len;
}

fn currentThemeId(state: *const AppState) []const u8 {
    return theme_mod.themes[state.theme_index % theme_mod.themes.len].id;
}

fn currentThemeName(state: *const AppState) []const u8 {
    return theme_mod.themes[state.theme_index % theme_mod.themes.len].name;
}

// ── Color palette ─────────────────────────────────────────────────────────

fn namedColor(color: terminal.Color, is_fg: bool) [3]f64 {
    return switch (color) {
        .default => if (is_fg) .{ 0.85, 0.85, 0.85 } else .{ 0.0, 0.0, 0.0 },
        .black => .{ 0.07, 0.07, 0.07 },
        .red => .{ 0.80, 0.20, 0.20 },
        .green => .{ 0.20, 0.70, 0.20 },
        .yellow => .{ 0.80, 0.70, 0.10 },
        .blue => .{ 0.25, 0.45, 0.85 },
        .magenta => .{ 0.70, 0.20, 0.70 },
        .cyan => .{ 0.20, 0.70, 0.70 },
        .white => .{ 0.80, 0.80, 0.80 },
        .bright_black => .{ 0.40, 0.40, 0.40 },
        .bright_red => .{ 1.00, 0.40, 0.40 },
        .bright_green => .{ 0.40, 1.00, 0.40 },
        .bright_yellow => .{ 1.00, 1.00, 0.40 },
        .bright_blue => .{ 0.40, 0.60, 1.00 },
        .bright_magenta => .{ 1.00, 0.40, 1.00 },
        .bright_cyan => .{ 0.40, 1.00, 1.00 },
        .bright_white => .{ 1.00, 1.00, 1.00 },
    };
}

// ── Glyph drawing ─────────────────────────────────────────────────────────

fn drawGlyph(font: CTFontRef, ctx: CGContextRef, x: f64, baseline_y: f64, cp: u21) void {
    if (cp > 0xFFFF) return;
    var uni: u16 = @intCast(cp);
    var glyph: CGGlyph = 0;
    if (!CTFontGetGlyphsForCharacters(font, &uni, &glyph, 1)) return;
    if (glyph == 0) return;
    const pt = CGPoint{ .x = x, .y = baseline_y };
    CTFontDrawGlyphs(font, &glyph, &pt, 1, ctx);
}

fn drawAscii(font: CTFontRef, ctx: CGContextRef, x0: f64, baseline_y: f64, cw: f64, text: []const u8) void {
    for (text, 0..) |ch, i| {
        if (ch < 0x20 or ch > 0x7E) continue;
        drawGlyph(font, ctx, x0 + cw * @as(f64, @floatFromInt(i)), baseline_y, ch);
    }
}

fn drawAsciiRange(font: CTFontRef, ctx: CGContextRef, x0: f64, baseline_y: f64, cw: f64, text: []const u8) void {
    for (text, 0..) |ch, i| {
        drawGlyph(font, ctx, x0 + cw * @as(f64, @floatFromInt(i)), baseline_y, if (ch >= 0x20 and ch <= 0x7E) ch else '?');
    }
}

// ── Row renderer ──────────────────────────────────────────────────────────

fn renderCells(
    ctx: CGContextRef,
    font: CTFontRef,
    cells: []const terminal.Cell,
    width: usize,
    visual_row: usize,
    cw: f64,
    ch: f64,
    asc: f64,
    H: f64,
) void {
    const y_bot = H - @as(f64, @floatFromInt(visual_row + 1)) * ch;
    const y_base = y_bot + asc;

    for (0..width) |col| {
        if (col >= cells.len) break;
        const cell = cells[col];
        if (cell.isContinuation()) continue;

        const px = cw * @as(f64, @floatFromInt(col));

        if (cell.style.bg != .default) {
            const bg = namedColor(cell.style.bg, false);
            CGContextSetRGBFillColor(ctx, bg[0], bg[1], bg[2], 1.0);
            CGContextFillRect(ctx, .{
                .origin = .{ .x = px, .y = y_bot },
                .size = .{ .width = cw, .height = ch },
            });
        }

        const cp = cell.codepoint;
        if (cp == 0 or cp == ' ') continue;

        const fg = namedColor(cell.style.fg, true);
        CGContextSetRGBFillColor(ctx, fg[0], fg[1], fg[2], 1.0);
        drawGlyph(font, ctx, px, y_base, cp);
    }
}

// ── View callbacks ────────────────────────────────────────────────────────

fn viewAcceptsFirstResponder(_: ID, _: SEL) callconv(.c) u8 {
    return 1;
}

// drawRect:(NSRect) — standard CG coordinates, no isFlipped.
fn viewDrawRect(_: ID, _: SEL, _: CGRect) callconv(.c) void {
    const state = g_state orelse return;

    const gc = msg0(cls("NSGraphicsContext"), sel("currentContext"));
    if (gc == null) return;
    const ctx = msgCGContext(gc, sel("CGContext"));

    state.mutex.lock();
    defer state.mutex.unlock();

    const grid = &state.grid;
    const cw = state.cell_w;
    const ch = state.cell_h;
    const asc = state.cell_ascent;
    const W = state.win_w;
    const H = state.win_h;

    // Background fill
    CGContextSetRGBFillColor(ctx, 0.06, 0.06, 0.09, 1.0);
    CGContextFillRect(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = W, .height = H } });

    const font = state.font orelse return;

    // Unified timeline scrollback rendering
    const hist_len = grid.historyLen();
    const scroll = state.scroll_offset;

    for (0..grid.height) |i| {
        const tl: i64 = @as(i64, @intCast(hist_len)) - @as(i64, scroll) + @as(i64, @intCast(i));
        if (tl < 0) continue;
        const ul: usize = @intCast(tl);
        if (ul < hist_len) {
            const hline = grid.history.items[ul];
            renderCells(ctx, font, hline.cells, grid.width, i, cw, ch, asc, H);
        } else {
            const sr = ul - hist_len;
            if (sr >= grid.height) continue;
            const cells = grid.cells[sr * grid.width .. (sr + 1) * grid.width];
            renderCells(ctx, font, cells, grid.width, i, cw, ch, asc, H);
        }
    }

    // Block cursor
    if (scroll == 0) {
        const cx = cw * @as(f64, @floatFromInt(grid.cursor_x));
        const cy = H - @as(f64, @floatFromInt(grid.cursor_y + 1)) * ch;
        CGContextSetRGBFillColor(ctx, 0.9, 0.9, 0.9, 0.55);
        CGContextFillRect(ctx, .{ .origin = .{ .x = cx, .y = cy }, .size = .{ .width = cw, .height = ch } });
    }

    // Scrollback indicator
    if (scroll > 0) {
        const msg = "[scrollback - wheel to scroll, any key to jump live]";
        const msg_len = @min(msg.len, @as(usize, @intFromFloat(W / cw)));
        const ix = W - cw * @as(f64, @floatFromInt(msg_len));
        CGContextSetRGBFillColor(ctx, 0.9, 0.9, 0.3, 1.0);
        drawAscii(font, ctx, ix, H - ch + asc, cw, msg[0..msg_len]);
    }

    // Draw active overlay
    switch (state.overlay) {
        .settings => drawSettingsOverlay(ctx, state, font, W, H, cw, ch, asc),
        .command_palette => drawPaletteOverlay(ctx, state, font, W, H, cw, ch, asc),
        .search => drawSearchOverlay(ctx, state, font, W, H, cw, ch, asc),
        .quick_select => drawQuickSelectOverlay(ctx, state, font, W, H, cw, ch, asc),
        .agent => drawAgentOverlay(ctx, state, font, W, H, cw, ch, asc),
        .none => {},
    }
}

// ── Overlay drawing helpers ──────────────────────────────────────────────

fn fillPanel(ctx: CGContextRef, x: f64, y: f64, w: f64, bottom: f64) void {
    CGContextSetRGBFillColor(ctx, 0.06, 0.06, 0.16, 0.94);
    CGContextFillRect(ctx, .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = bottom - y } });
}

fn fillPanelHeader(ctx: CGContextRef, x: f64, y: f64, w: f64, ch: f64) void {
    CGContextSetRGBFillColor(ctx, 0.12, 0.22, 0.55, 1.0);
    CGContextFillRect(ctx, .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = ch } });
}

fn highlightRow(ctx: CGContextRef, x: f64, y: f64, w: f64, ch: f64) void {
    CGContextSetRGBFillColor(ctx, 0.18, 0.32, 0.55, 0.60);
    CGContextFillRect(ctx, .{ .origin = .{ .x = x - 4, .y = y - 1 }, .size = .{ .width = w - @min(x - 4, 0.0), .height = ch + 2 } });
}

fn drawSettingsOverlay(ctx: CGContextRef, state: *AppState, font: CTFontRef, W: f64, H: f64, cw: f64, ch: f64, asc: f64) void {
    const panel_w_f: f64 = @min(@max(W - 48, 280), 760);
    const left = @max(W - panel_w_f - 24, 0);
    const bottom = @min(H - 12, 24 + ch * 20 + 40);
    if (bottom <= 24 + ch * 4) return;

    fillPanel(ctx, left, 24, panel_w_f, bottom);
    fillPanelHeader(ctx, left, bottom - ch, panel_w_f, ch);
    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
    drawAscii(font, ctx, left + cw, bottom - ch + asc, cw, "Settings");

    const x = left + cw;
    const max_w = panel_w_f - 2 * cw;
    var y = bottom - 2 * ch + asc;

    CGContextSetRGBFillColor(ctx, 0.55, 0.85, 0.55, 1.0);
    var theme_buf: [128]u8 = undefined;
    const tid = currentThemeId(state);
    const tname = currentThemeName(state);
    const theme_text = std.fmt.bufPrint(&theme_buf, "Theme: {s} ({s})", .{ tname, tid }) catch "Theme";
    drawAsciiRange(font, ctx, x, y, cw, theme_text);
    y -= ch;

    CGContextSetRGBFillColor(ctx, 0.72, 0.72, 0.72, 1.0);
    drawAsciiRange(font, ctx, x, y, cw, "Font: Menlo 14pt");
    y -= ch;
    const dims_text = std.fmt.bufPrint(&theme_buf, "Grid: {d}x{d}  Cells: {d:.1}x{d:.1}", .{
        state.grid.width, state.grid.height, state.cell_w, state.cell_h,
    }) catch "Grid";
    drawAsciiRange(font, ctx, x, y, cw, dims_text);
    y -= ch;

    // Theme list
    y -= ch;
    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
    drawAsciiRange(font, ctx, x, y, cw, "Built-in themes (Ctrl+Shift+T cycles):");
    y -= ch * 0.5;

    // 2-column theme grid
    const cols: usize = 2;
    const col_w = max_w / @as(f64, @floatFromInt(cols));
    for (theme_mod.themes, 0..) |t, i| {
        const ci: usize = i % cols;
        const ri: usize = i / cols;
        const tx = x + cw * @as(f64, @floatFromInt(ci)) * col_w;
        const ty = y - cw * @as(f64, @floatFromInt(ri)) * (ch + 4);
        if (ty < 24) break;
        if (i == state.theme_index) {
            CGContextSetRGBFillColor(ctx, 0.55, 0.85, 0.55, 1.0);
            drawAsciiRange(font, ctx, tx, ty, cw, "> ");
        }
        drawAsciiRange(font, ctx, tx + 2 * cw, ty, cw, t.name);
        CGContextSetRGBFillColor(ctx, 0.72, 0.72, 0.72, 1.0);
    }

    // Footer
    CGContextSetRGBFillColor(ctx, 0.45, 0.45, 0.45, 1.0);
    drawAsciiRange(font, ctx, x, 24 + ch + asc, cw, "Ctrl+, toggle  Ctrl+Shift+T cycle theme  Ctrl+Shift+P palette  Esc close");
}

fn drawPaletteOverlay(ctx: CGContextRef, state: *AppState, font: CTFontRef, W: f64, H: f64, cw: f64, ch: f64, asc: f64) void {
    const panel_w = @min(@max(W - 80, 360), 720);
    const left = (W - panel_w) / 2.0;
    const top: f64 = 48;
    const bottom = @min(H - 24, top + ch * 18 + 44);
    if (bottom <= top + ch * 5) return;

    fillPanel(ctx, left, top, panel_w, bottom);
    fillPanelHeader(ctx, left, bottom - ch, panel_w, ch);

    const x = left + cw;

    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
    drawAscii(font, ctx, x, bottom - ch + asc, cw, "Command Palette");

    var y = bottom - 2 * ch + asc;
    var qbuf: [MAX_PALETTE_QUERY + 8]u8 = undefined;
    const qtext = std.fmt.bufPrint(&qbuf, "> {s}", .{state.palette_query[0..state.palette_query_len]}) catch "> ";
    CGContextSetRGBFillColor(ctx, 0.85, 0.85, 0.85, 1.0);
    drawAsciiRange(font, ctx, x, y, cw, qtext);
    y -= ch + 8;

    var match_index: usize = 0;
    for (palette_actions) |action| {
        if (!paletteActionMatches(state, action)) continue;
        if (y - ch < top + 12) break;

        if (match_index == state.palette_selected) {
            highlightRow(ctx, x, y, panel_w, ch + 4);
        }
        CGContextSetRGBFillColor(ctx, if (match_index == state.palette_selected) 0.55 else 0.85, if (match_index == state.palette_selected) 0.85 else 0.85, if (match_index == state.palette_selected) 0.55 else 0.85, 1.0);
        drawAsciiRange(font, ctx, x, y, cw, action.title);
        y -= ch;
        CGContextSetRGBFillColor(ctx, 0.45, 0.45, 0.45, 1.0);
        drawAsciiRange(font, ctx, x + 2 * cw, y, cw, action.detail);
        y -= ch + 2;
        match_index += 1;
    }

    CGContextSetRGBFillColor(ctx, 0.40, 0.40, 0.40, 1.0);
    drawAsciiRange(font, ctx, x, top + ch + asc, cw, "Type to filter. Enter runs. Esc closes. Up/Down navigate.");
}

fn drawSearchOverlay(ctx: CGContextRef, state: *AppState, font: CTFontRef, W: f64, H: f64, cw: f64, ch: f64, asc: f64) void {
    const panel_w = @min(@max(W - 80, 360), 680);
    const left = (W - panel_w) / 2.0;
    const top = @max(H - 24 - ch * 8 - 32, 24);
    const bottom = top + ch * 6 + 26;

    fillPanel(ctx, left, top, panel_w, bottom);
    fillPanelHeader(ctx, left, bottom - ch, panel_w, ch);

    const x = left + cw;
    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
    drawAscii(font, ctx, x, bottom - ch + asc, cw, "Search Scrollback");

    var y = bottom - 2 * ch + asc;
    var qbuf: [MAX_SEARCH_QUERY + 8]u8 = undefined;
    const qtext = std.fmt.bufPrint(&qbuf, "/ {s}", .{state.search_query[0..state.search_query_len]}) catch "/ ";
    CGContextSetRGBFillColor(ctx, 0.85, 0.85, 0.85, 1.0);
    drawAsciiRange(font, ctx, x, y, cw, qtext);
    y -= ch + 8;

    const result: []const u8 = if (state.search_match_label_len > 0)
        state.search_match_label[0..state.search_match_label_len]
    else
        "Type to search visible output and scrollback history";
    CGContextSetRGBFillColor(ctx, 0.45, 0.45, 0.45, 1.0);
    drawAsciiRange(font, ctx, x, y, cw, result);
    y -= ch + 4;
    drawAsciiRange(font, ctx, x, y, cw, "Esc closes. Enter jumps to match.");
}

fn drawQuickSelectOverlay(ctx: CGContextRef, state: *AppState, font: CTFontRef, W: f64, H: f64, cw: f64, ch: f64, asc: f64) void {
    const panel_w = @min(@max(W - 80, 360), 720);
    const left = (W - panel_w) / 2.0;
    const top: f64 = 48;
    const bottom = @min(H - 24, top + ch * 18 + 44);

    fillPanel(ctx, left, top, panel_w, bottom);
    fillPanelHeader(ctx, left, bottom - ch, panel_w, ch);

    const x = left + cw;
    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
    drawAscii(font, ctx, x, bottom - ch + asc, cw, "Quick Select");

    var y = bottom - 2 * ch + asc;
    if (state.quick_item_count == 0) {
        CGContextSetRGBFillColor(ctx, 0.45, 0.45, 0.45, 1.0);
        drawAsciiRange(font, ctx, x, y, cw, "No URLs, paths, hashes, or issue keys found.");
    } else {
        for (0..state.quick_item_count) |i| {
            if (y - ch < top + 12) break;
            if (i == state.quick_selected) highlightRow(ctx, x, y, panel_w, ch + 2);
            CGContextSetRGBFillColor(ctx, if (i == state.quick_selected) 0.55 else 0.85, 0.85, if (i == state.quick_selected) 0.55 else 0.85, 1.0);
            drawAsciiRange(font, ctx, x, y, cw, state.quick_items[i].slice());
            y -= ch + 2;
        }
    }

    CGContextSetRGBFillColor(ctx, 0.40, 0.40, 0.40, 1.0);
    drawAsciiRange(font, ctx, x, top + ch + asc, cw, "Enter copies selection. Esc closes.");
}

fn drawAgentOverlay(ctx: CGContextRef, state: *AppState, font: CTFontRef, W: f64, H: f64, cw: f64, ch: f64, asc: f64) void {
    const panel_w = @min(@max(W - 80, 420), 860);
    const left = (W - panel_w) / 2.0;
    const top: f64 = 42;
    const bottom = @min(H - 24, top + ch * 22 + 56);
    if (bottom <= top + ch * 6) return;

    fillPanel(ctx, left, top, panel_w, bottom);
    fillPanelHeader(ctx, left, bottom - ch, panel_w, ch);

    const x = left + cw;
    const max_w = panel_w - 2 * cw;
    const max_cols: usize = @max(1, @as(usize, @intFromFloat(max_w / cw)));

    // Header
    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
    if (state.agent_input_active)
        drawAscii(font, ctx, x, bottom - ch + asc, cw, "AgentD — type your request, Enter to send, Esc to cancel")
    else
        drawAscii(font, ctx, x, bottom - ch + asc, cw, "AgentD  [H]health [T]tools [I]command input [Esc]close");

    var y = bottom - 2 * ch + asc;

    // Status line
    const status_text: []const u8 = if (state.agentd_running.load(.monotonic))
        "status: connected"
    else
        "status: unavailable (build ziggyzag-agentd first)";
    CGContextSetRGBFillColor(ctx, if (state.agentd_running.load(.monotonic)) 0.40 else 0.90, if (state.agentd_running.load(.monotonic)) 0.90 else 0.40, 0.40, 1.0);
    drawAscii(font, ctx, x, y, cw, status_text);
    y -= ch;

    // AgentD universal input line
    if (state.agent_input_active) {
        y -= ch * 0.5;
        var ibuf: [260]u8 = undefined;
        const itext = std.fmt.bufPrint(&ibuf, "> {s}_", .{state.agent_input[0..state.agent_input_len]}) catch "> _";
        CGContextSetRGBFillColor(ctx, 0.85, 0.85, 0.30, 1.0);
        drawAsciiRange(font, ctx, x, y, cw, itext);
        y -= ch;
        CGContextSetRGBFillColor(ctx, 0.40, 0.40, 0.40, 1.0);
        drawAsciiRange(font, ctx, x, y, cw, "Enter: send to AgentD to generate shell command. Esc: cancel.");
        y -= ch;
    }

    // Provider hint
    const show_hint = blk: {
        if (state.transcript_len == 0) break :blk false;
        const t = state.transcript[0..state.transcript_len];
        break :blk std.mem.indexOf(u8, t, "provider_status") != null and
            std.mem.indexOf(u8, t, "\"reachable\"") == null;
    };
    if (show_hint) {
        CGContextSetRGBFillColor(ctx, 0.85, 0.85, 0.30, 1.0);
        drawAsciiRange(font, ctx, x, y, cw, "No AI provider reachable.");
        y -= ch;
        CGContextSetRGBFillColor(ctx, 0.45, 0.45, 0.45, 1.0);
        drawAsciiRange(font, ctx, x, y, cw, "  ollama pull qwen2.5-coder:1.5b  |  set ZIGGYZAG_AGENT_PROVIDER=ollama");
        y -= ch;
    }

    // Transcript
    y -= ch * 0.5;
    const transcript = state.transcript[0..state.transcript_len];
    var remaining = transcript;
    var lines_shown: usize = 0;
    CGContextSetRGBFillColor(ctx, 0.72, 0.72, 0.72, 1.0);
    // Walk backwards to show newest lines first
    while (remaining.len > 0 and lines_shown < 16) : (lines_shown += 1) {
        if (y - ch < top + 12) break;
        // Find last line in remaining
        var end = remaining.len;
        if (end > 0 and remaining[end - 1] == '\n') end -= 1;
        var start = end;
        while (start > 0 and remaining[start - 1] != '\n') start -= 1;
        if (start < end) {
            const line = remaining[start..end];
            const display = if (line.len > max_cols) line[0..max_cols] else line;
            drawAsciiRange(font, ctx, x, y, cw, display);
            y -= ch + 1;
        }
        if (start == 0) break;
        remaining = remaining[0..start -| 1];
    }

    if (state.transcript_len == 0) {
        CGContextSetRGBFillColor(ctx, 0.45, 0.45, 0.45, 1.0);
        drawAsciiRange(font, ctx, x, y, cw, "Press H for health, T for tools, I for command input.");
    }

    CGContextSetRGBFillColor(ctx, 0.40, 0.40, 0.40, 1.0);
    drawAsciiRange(font, ctx, x, top + ch + asc, cw, "Enter sends command preview. Esc closes.");
}

// ── Key handling ──────────────────────────────────────────────────────────

// keyDown:(NSEvent*)
fn viewKeyDown(_: ID, _: SEL, event_obj: ID) callconv(.c) void {
    const state = g_state orelse return;
    if (!state.running.load(.monotonic)) return;

    const kc = msgKeyCode(event_obj, sel("keyCode"));
    const mods = msgULong(event_obj, sel("modifierFlags"));

    const ctrl = (mods & NSControlKeyMask) != 0;
    const cmd = (mods & NSCommandKeyMask) != 0;
    const shift = (mods & NSShiftKeyMask) != 0;

    // ── Global shortcuts (work even when overlay is open) ────────────

    // Ctrl+Shift+P → command palette
    if (kc == kVK_P and ctrl and shift) {
        openPalette(state);
        return;
    }
    // Ctrl+Shift+F → search
    if (kc == kVK_F and ctrl and shift) {
        openSearch(state);
        return;
    }
    // Ctrl+Shift+O → quick select
    if (kc == kVK_O and ctrl and shift) {
        openQuickSelect(state);
        return;
    }
    // Ctrl+, → settings
    if (kc == kVK_Comma and ctrl and !shift) {
        state.mutex.lock();
        state.overlay = if (state.overlay == .settings) .none else .settings;
        state.mutex.unlock();
        state.dirty.store(true, .monotonic);
        return;
    }
    // Ctrl+Shift+T → theme cycle
    if (kc == kVK_T and ctrl and shift) {
        state.mutex.lock();
        cycleThemeAction(state);
        state.mutex.unlock();
        state.dirty.store(true, .monotonic);
        return;
    }
    // Cmd+Shift+C → copy visible text
    if (kc == kVK_C and cmd and shift) {
        state.mutex.lock();
        copyVisibleToClipboard(state);
        state.mutex.unlock();
        return;
    }
    // Cmd+V → paste
    if (kc == kVK_V and cmd and !shift) {
        pasteFromPasteboard(state);
        return;
    }

    // ── Overlay dispatch ─────────────────────────────────────────────
    if (state.overlay != .none) {
        // Esc always closes overlay or cancels input
        if (kc == kVK_Escape) {
            state.mutex.lock();
            if (state.agent_input_active) {
                state.agent_input_active = false;
                state.agent_input_len = 0;
            } else {
                state.overlay = .none;
            }
            state.mutex.unlock();
            state.dirty.store(true, .monotonic);
            return;
        }

        state.mutex.lock();
        const current_overlay = state.overlay;
        state.mutex.unlock();
        switch (current_overlay) {
            .agent => {
                // AgentD overlay key dispatch
                if (!state.agent_input_active) {
                    switch (kc) {
                        kVK_H => {
                            requestHealth(state);
                            return;
                        },
                        kVK_T => {
                            requestTools(state);
                            return;
                        },
                        kVK_I => {
                            state.mutex.lock();
                            state.agent_input_active = true;
                            state.agent_input_len = 0;
                            state.mutex.unlock();
                            state.dirty.store(true, .monotonic);
                            return;
                        },
                        else => {},
                    }
                } else {
                    // AgentD universal input mode — capture all typed chars
                    handleAgentInputKey(state, kc, event_obj);
                    return;
                }
            },
            .command_palette => {
                switch (kc) {
                    kVK_Up => {
                        state.mutex.lock();
                        paletteMoveUp(state);
                        state.mutex.unlock();
                        state.dirty.store(true, .monotonic);
                        return;
                    },
                    kVK_Down => {
                        state.mutex.lock();
                        paletteMoveDown(state);
                        state.mutex.unlock();
                        state.dirty.store(true, .monotonic);
                        return;
                    },
                    kVK_Return, kVK_NumEnter => {
                        acceptPalette(state);
                        return;
                    },
                    kVK_Delete => {
                        state.mutex.lock();
                        overlayBackspace(state);
                        state.mutex.unlock();
                        state.dirty.store(true, .monotonic);
                        return;
                    },
                    else => {
                        if (kc == kVK_Slash) return; // ignore raw slash from Cmd+Shift shortcut residue
                        const ns_chars = msg0(event_obj, sel("characters"));
                        if (ns_chars == null) return;
                        if (msgCStr(ns_chars, sel("UTF8String"))) |ptr| {
                            const bytes = std.mem.sliceTo(ptr, 0);
                            if (bytes.len > 0 and bytes[0] >= 0x20) {
                                state.mutex.lock();
                                overlayAppendChar(state, bytes[0]);
                                state.mutex.unlock();
                                state.dirty.store(true, .monotonic);
                            }
                        }
                        return;
                    },
                }
            },
            .search => {
                switch (kc) {
                    kVK_Return, kVK_NumEnter => {
                        acceptSearch(state);
                        return;
                    },
                    kVK_Delete => {
                        state.mutex.lock();
                        overlayBackspace(state);
                        state.mutex.unlock();
                        updateSearchMatch(state) catch {};
                        state.dirty.store(true, .monotonic);
                        return;
                    },
                    else => {
                        if (kc == kVK_Slash) return;
                        const ns_chars = msg0(event_obj, sel("characters"));
                        if (ns_chars == null) return;
                        if (msgCStr(ns_chars, sel("UTF8String"))) |ptr| {
                            const bytes = std.mem.sliceTo(ptr, 0);
                            if (bytes.len > 0 and bytes[0] >= 0x20) {
                                state.mutex.lock();
                                overlayAppendChar(state, bytes[0]);
                                state.mutex.unlock();
                                updateSearchMatch(state) catch {};
                                state.dirty.store(true, .monotonic);
                            }
                        }
                        return;
                    },
                }
            },
            .quick_select => {
                switch (kc) {
                    kVK_Up => {
                        state.mutex.lock();
                        quickSelectMoveUp(state);
                        state.mutex.unlock();
                        state.dirty.store(true, .monotonic);
                        return;
                    },
                    kVK_Down => {
                        state.mutex.lock();
                        quickSelectMoveDown(state);
                        state.mutex.unlock();
                        state.dirty.store(true, .monotonic);
                        return;
                    },
                    kVK_Return, kVK_NumEnter => {
                        acceptQuickSelect(state);
                        return;
                    },
                    else => return,
                }
            },
            .settings => return, // Esc handled above
            .none => {},
        }
        return;
    }

    // ── Ctrl+Space → AgentD overlay ──────────────────────────────────
    if (kc == kVK_Space and ctrl and !shift) {
        openAgentOverlay(state);
        return;
    }

    // Any key while scrolled → jump back to live screen
    if (state.scroll_offset > 0) {
        state.mutex.lock();
        state.scroll_offset = 0;
        state.mutex.unlock();
        state.dirty.store(true, .monotonic);
    }

    // Arrow keys: application cursor vs. ANSI
    const app_cursor = state.grid.isApplicationCursorEnabled();
    switch (kc) {
        kVK_Up => {
            posix_pty.writeAll(state.session.master_fd, if (app_cursor) "\x1bOA" else "\x1b[A") catch {};
            return;
        },
        kVK_Down => {
            posix_pty.writeAll(state.session.master_fd, if (app_cursor) "\x1bOB" else "\x1b[B") catch {};
            return;
        },
        kVK_Right => {
            posix_pty.writeAll(state.session.master_fd, if (app_cursor) "\x1bOC" else "\x1b[C") catch {};
            return;
        },
        kVK_Left => {
            posix_pty.writeAll(state.session.master_fd, if (app_cursor) "\x1bOD" else "\x1b[D") catch {};
            return;
        },
        else => {},
    }

    const special: ?[]const u8 = switch (kc) {
        kVK_Escape => "\x1b",
        kVK_Delete => "\x7f",
        kVK_Return, kVK_NumEnter => "\r",
        kVK_PageUp => "\x1b[5~",
        kVK_PageDown => "\x1b[6~",
        else => null,
    };
    if (special) |bytes| {
        posix_pty.writeAll(state.session.master_fd, bytes) catch {};
        return;
    }

    const ns_chars = msg0(event_obj, sel("characters"));
    if (ns_chars == null) return;
    if (msgCStr(ns_chars, sel("UTF8String"))) |ptr| {
        const bytes = std.mem.sliceTo(ptr, 0);
        if (bytes.len > 0) posix_pty.writeAll(state.session.master_fd, bytes) catch {};
    }
}

// ── AgentD input handling ─────────────────────────────────────────────────

fn handleAgentInputKey(state: *AppState, kc: u16, event_obj: ID) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    switch (kc) {
        kVK_Return, kVK_NumEnter => {
            // Send the universal input to AgentD via agent/run
            if (state.agent_input_len > 0) {
                requestAgentRun(state, state.agent_input[0..state.agent_input_len]);
            }
            state.agent_input_len = 0;
            state.agent_input_active = false;
        },
        kVK_Delete => {
            if (state.agent_input_len > 0) state.agent_input_len -= 1;
        },
        else => {
            const ns_chars = msg0(event_obj, sel("characters"));
            if (ns_chars == null) return;
            if (msgCStr(ns_chars, sel("UTF8String"))) |ptr| {
                const bytes = std.mem.sliceTo(ptr, 0);
                for (bytes) |b| {
                    if (state.agent_input_len < state.agent_input.len and b >= 0x20) {
                        state.agent_input[state.agent_input_len] = b;
                        state.agent_input_len += 1;
                    }
                }
            }
        },
    }
    state.dirty.store(true, .monotonic);
}

// scrollWheel:(NSEvent*)
fn viewScrollWheel(_: ID, _: SEL, event_obj: ID) callconv(.c) void {
    const state = g_state orelse return;
    if (state.grid.isAlternateScreen()) return;

    const delta = msgDouble(event_obj, sel("scrollingDeltaY"));
    const lines: i32 = @intFromFloat(delta / 3.0);
    if (lines == 0) return;

    state.mutex.lock();
    const hist = @as(i32, @intCast(state.grid.historyLen()));
    state.scroll_offset = std.math.clamp(state.scroll_offset + lines, 0, hist);
    state.mutex.unlock();
    state.dirty.store(true, .monotonic);
}

// ── Overlay actions ───────────────────────────────────────────────────────

fn openPalette(state: *AppState) void {
    state.mutex.lock();
    state.overlay = .command_palette;
    state.palette_query_len = 0;
    state.palette_selected = 0;
    state.mutex.unlock();
    state.dirty.store(true, .monotonic);
}

fn openSearch(state: *AppState) void {
    state.mutex.lock();
    state.overlay = .search;
    state.search_query_len = 0;
    state.search_match_label_len = 0;
    state.search_match_line = 0;
    state.mutex.unlock();
    state.dirty.store(true, .monotonic);
}

fn openQuickSelect(state: *AppState) void {
    state.mutex.lock();
    populateQuickItems(state);
    state.quick_selected = 0;
    state.overlay = .quick_select;
    state.mutex.unlock();
    state.dirty.store(true, .monotonic);
}

fn openAgentOverlay(state: *AppState) void {
    state.mutex.lock();
    if (state.overlay == .agent) {
        state.overlay = .none;
        state.agent_input_active = false;
    } else {
        state.overlay = .agent;
    }
    state.mutex.unlock();
    state.dirty.store(true, .monotonic);
    if (state.overlay == .agent) {
        if (state.transcript_len == 0) requestHealth(state);
    }
}

fn paletteActionMatches(state: *const AppState, action: PaletteAction) bool {
    const query = state.palette_query[0..state.palette_query_len];
    if (query.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(action.title, query) != null or
        std.ascii.indexOfIgnoreCase(action.detail, query) != null;
}

fn paletteMatchCount(state: *const AppState) usize {
    var count: usize = 0;
    for (palette_actions) |action| {
        if (paletteActionMatches(state, action)) count += 1;
    }
    return count;
}

fn paletteMoveUp(state: *AppState) void {
    const count = paletteMatchCount(state);
    if (count == 0) return;
    state.palette_selected = if (state.palette_selected == 0) count - 1 else state.palette_selected - 1;
}

fn paletteMoveDown(state: *AppState) void {
    const count = paletteMatchCount(state);
    if (count == 0) return;
    state.palette_selected = if (state.palette_selected + 1 >= count) 0 else state.palette_selected + 1;
}

fn paletteActionAt(state: *const AppState, selected: usize) ?PaletteAction {
    var count: usize = 0;
    for (palette_actions) |action| {
        if (!paletteActionMatches(state, action)) continue;
        if (count == selected) return action;
        count += 1;
    }
    return null;
}

fn acceptPalette(state: *AppState) void {
    const action = paletteActionAt(state, state.palette_selected) orelse {
        state.overlay = .none;
        state.dirty.store(true, .monotonic);
        return;
    };
    state.overlay = .none;
    // clear_scrollback writes to grid — best-effort on main thread
    switch (action.kind) {
        .copy_visible => copyVisibleToClipboard(state),
        .paste_clipboard => pasteFromPasteboard(state),
        .search_scrollback => openSearch(state),
        .quick_select => openQuickSelect(state),
        .open_agent_panel => openAgentOverlay(state),
        .agent_health => requestHealth(state),
        .agent_tools => requestTools(state),
        .toggle_settings => {
            state.overlay = .settings;
        },
        .next_theme => {
            cycleThemeAction(state);
        },
        .clear_scrollback => {
            state.grid.feed("\x1b[3J");
            state.scroll_offset = 0;
        },
    }
    state.dirty.store(true, .monotonic);
}

fn acceptSearch(state: *AppState) void {
    if (state.search_match_line > 0) {
        const grid_height = state.grid.height;
        const target_y = state.search_match_line - 1;
        if (target_y >= grid_height) {
            state.scroll_offset = @intCast(target_y - grid_height + 1);
        }
    }
    // Overlay/switching writes are main-thread-only; drawRect reads under mutex
    // but the PTY reader only writes grid cells, not overlay fields.
    state.overlay = .none;
    state.dirty.store(true, .monotonic);
}

fn acceptQuickSelect(state: *AppState) void {
    if (state.quick_selected < state.quick_item_count) {
        const item = state.quick_items[state.quick_selected].slice();
        if (item.len > 0) {
            copyTextToClipboard(item);
        }
    }
    state.overlay = .none;
    state.dirty.store(true, .monotonic);
}

fn quickSelectMoveUp(state: *AppState) void {
    if (state.quick_item_count == 0) return;
    state.quick_selected = if (state.quick_selected == 0) state.quick_item_count - 1 else state.quick_selected - 1;
}
fn quickSelectMoveDown(state: *AppState) void {
    if (state.quick_item_count == 0) return;
    state.quick_selected = if (state.quick_selected + 1 >= state.quick_item_count) 0 else state.quick_selected + 1;
}

fn overlayBackspace(state: *AppState) void {
    switch (state.overlay) {
        .command_palette => {
            if (state.palette_query_len > 0) {
                state.palette_query_len -= 1;
                state.palette_selected = 0;
            }
        },
        .search => {
            if (state.search_query_len > 0) {
                state.search_query_len -= 1;
            }
        },
        else => {},
    }
}

fn overlayAppendChar(state: *AppState, ch: u8) void {
    switch (state.overlay) {
        .command_palette => {
            if (state.palette_query_len < state.palette_query.len) {
                state.palette_query[state.palette_query_len] = ch;
                state.palette_query_len += 1;
                state.palette_selected = 0;
            }
        },
        .search => {
            if (state.search_query_len < state.search_query.len) {
                state.search_query[state.search_query_len] = ch;
                state.search_query_len += 1;
            }
        },
        else => {},
    }
}

// ── Theme cycling ─────────────────────────────────────────────────────────

fn cycleThemeAction(state: *AppState) void {
    nextTheme(state);
    // Broadcast OSC 7777 theme update to shell via PTY
    var buf: [128]u8 = undefined;
    const tid = currentThemeId(state);
    const payload = std.fmt.bufPrint(&buf, "\x1b]7777;ziggyzag.theme={s}\x07", .{tid}) catch return;
    posix_pty.writeAll(state.session.master_fd, payload) catch {};
    state.dirty.store(true, .monotonic);
}

// ── Copy visible text ─────────────────────────────────────────────────────

fn copyVisibleToClipboard(state: *AppState) void {
    state.mutex.lock();
    const text = visibleTextAlloc(state) catch {
        state.mutex.unlock();
        return;
    };
    state.mutex.unlock();
    defer state.allocator.free(text);
    if (text.len == 0) return;
    copyTextToClipboard(text);
}

fn visibleTextAlloc(state: *AppState) ![]u8 {
    const allocator = state.allocator;
    const hist_len = state.grid.historyLen();
    const scroll = state.scroll_offset;

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    // Build list of lines from the current viewport
    if (scroll > 0) {
        const history_start = if (hist_len > state.grid.height + @as(usize, @intCast(scroll)))
            hist_len - state.grid.height - @as(usize, @intCast(scroll))
        else
            0;
        for (0..state.grid.height) |row| {
            const hrow = history_start + row;
            if (hrow >= hist_len) break;
            const line = try state.grid.historyLineTextAlloc(allocator, hrow);
            try lines.append(allocator, line);
        }
    } else {
        for (0..state.grid.height) |row| {
            const cells = state.grid.cells[row * state.grid.width .. (row + 1) * state.grid.width];
            const line = try cellsTextAlloc(allocator, cells);
            try lines.append(allocator, line);
        }
    }

    // Trim trailing empty lines
    var last = lines.items.len;
    while (last > 0 and lines.items[last - 1].len == 0) : (last -= 1) {}

    // Calculate total size
    var total: usize = 0;
    for (lines.items[0..last], 0..) |line, i| {
        total += line.len;
        if (i + 1 < last) total += 1; // \n
    }
    if (total == 0) return allocator.alloc(u8, 0);

    const text = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (lines.items[0..last], 0..) |line, i| {
        @memcpy(text[offset .. offset + line.len], line);
        offset += line.len;
        if (i + 1 < last) {
            text[offset] = '\n';
            offset += 1;
        }
    }
    return text;
}

fn cellsTextAlloc(allocator: Allocator, cells: []const terminal.Cell) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (cells) |cell| {
        if (cell.isContinuation()) continue;
        const cp = cell.codepoint;
        if (cp == 0) continue;
        if (cp <= 0x7F) {
            try buf.append(allocator, @intCast(cp));
        } else if (cp <= 0x7FF) {
            try buf.append(allocator, @intCast(0xC0 | (cp >> 6)));
            try buf.append(allocator, @intCast(0x80 | (cp & 0x3F)));
        } else if (cp <= 0xFFFF) {
            try buf.append(allocator, @intCast(0xE0 | (cp >> 12)));
            try buf.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try buf.append(allocator, @intCast(0x80 | (cp & 0x3F)));
        } else {
            try buf.append(allocator, @intCast(0xF0 | (cp >> 18)));
            try buf.append(allocator, @intCast(0x80 | ((cp >> 12) & 0x3F)));
            try buf.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try buf.append(allocator, @intCast(0x80 | (cp & 0x3F)));
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn msgSetStringForType(recv: ID, s: SEL, str: ID, typ: ID) bool {
    return (@as(*const fn (ID, SEL, ID, ID) callconv(.c) bool, @ptrCast(&objc.objc_msgSend)))(recv, s, str, typ);
}

fn copyTextToClipboard(text: []const u8) void {
    const pb = msg0(cls("NSPasteboard"), sel("generalPasteboard")) orelse return;

    // Null-terminate the text for NSString creation
    var buf: [8192]u8 = undefined;
    const capped = if (text.len > buf.len - 1) text[0 .. buf.len - 1] else text;
    @memcpy(buf[0..capped.len], capped);
    buf[capped.len] = 0;

    const ns = cfString(buf[0..capped.len :0]);
    defer CFRelease(ns);

    msg1lv(pb, sel("clearContents"), 0);

    const pboard_type = cfString("public.utf8-plain-text");
    defer if (pboard_type) |t| CFRelease(t);
    _ = msgSetStringForType(pb, sel("setString:forType:"), ns, pboard_type);
}

// ── Search ────────────────────────────────────────────────────────────────

fn updateSearchMatch(state: *AppState) !void {
    state.search_match_label_len = 0;
    state.search_match_line = 0;
    const query = state.search_query[0..state.search_query_len];
    if (query.len == 0) return;

    state.mutex.lock();
    const text = visibleTextAlloc(state) catch {
        state.mutex.unlock();
        return;
    };
    state.mutex.unlock();
    defer state.allocator.free(text);

    if (std.ascii.indexOfIgnoreCase(text, query)) |index| {
        var nl_count: usize = 0;
        for (text[0..index]) |b| {
            if (b == '\n') nl_count += 1;
        }
        state.search_match_line = nl_count + 1;
        const label = std.fmt.bufPrint(&state.search_match_label, "Found at line {d}", .{state.search_match_line}) catch return;
        state.search_match_label_len = label.len;
    } else {
        const msg = "No match";
        @memcpy(state.search_match_label[0..msg.len], msg);
        state.search_match_label_len = msg.len;
    }
}

// ── Quick select helpers ──────────────────────────────────────────────────

fn populateQuickItems(state: *AppState) void {
    state.quick_item_count = 0;
    const text = visibleTextAlloc(state) catch return;
    defer state.allocator.free(text);

    var index: usize = 0;
    while (index < text.len and state.quick_item_count < state.quick_items.len) {
        // Skip separators
        while (index < text.len and isQuickSep(text[index])) : (index += 1) {}
        const start = index;
        while (index < text.len and !isQuickSep(text[index])) : (index += 1) {}
        const token = trimQuick(text[start..index]);
        if (isQuickToken(token) and !quickItemDup(state, token)) {
            state.quick_items[state.quick_item_count].set(token);
            state.quick_item_count += 1;
        }
    }
}

fn isQuickSep(b: u8) bool {
    return b == ' ' or b == '\n' or b == '\r' or b == '\t' or b == '"' or b == '\'' or b == '<' or b == '>';
}

fn isQuickToken(token: []const u8) bool {
    if (token.len < 3) return false;
    // URL
    if (std.mem.startsWith(u8, token, "http://") or std.mem.startsWith(u8, token, "https://")) return true;
    // Path-like
    if (token[0] == '/' or token[0] == '~' or token[0] == '.') return true;
    // Git hash
    if (token.len >= 7) {
        var is_hex = true;
        for (token) |b| {
            if (!std.ascii.isHex(b)) {
                is_hex = false;
                break;
            }
        }
        if (is_hex) return true;
    }
    // Issue key (#123)
    if (token[0] == '#' and token.len > 1 and token.len <= 8) {
        var is_num = true;
        for (token[1..]) |b| {
            if (!std.ascii.isDigit(b)) {
                is_num = false;
                break;
            }
        }
        if (is_num) return true;
    }
    return false;
}

fn trimQuick(token: []const u8) []const u8 {
    var s = token;
    while (s.len > 0 and (s[s.len - 1] == '.' or s[s.len - 1] == ',' or s[s.len - 1] == ':' or s[s.len - 1] == ';' or s[s.len - 1] == ')' or s[s.len - 1] == ']')) {
        s = s[0 .. s.len - 1];
    }
    return s;
}

fn quickItemDup(state: *const AppState, token: []const u8) bool {
    for (0..state.quick_item_count) |i| {
        if (std.mem.eql(u8, state.quick_items[i].slice(), token)) return true;
    }
    return false;
}

// ── Paste ─────────────────────────────────────────────────────────────────

fn pasteFromPasteboard(state: *AppState) void {
    const pb = msg0(cls("NSPasteboard"), sel("generalPasteboard"));
    if (pb == null) return;

    const ns_type = cfString("public.utf8-plain-text");
    defer if (ns_type) |t| CFRelease(t);

    const ns_str = msg1(pb, sel("stringForType:"), ns_type);
    if (ns_str == null) return;

    const cstr = msgCStr(ns_str, sel("UTF8String")) orelse return;
    const text = std.mem.sliceTo(cstr, 0);
    if (text.len == 0) return;

    state.mutex.lock();
    const bracketed = state.grid.isBracketedPasteEnabled();
    state.mutex.unlock();

    if (bracketed) posix_pty.writeAll(state.session.master_fd, "\x1b[200~") catch {};
    posix_pty.writeAll(state.session.master_fd, text) catch {};
    if (bracketed) posix_pty.writeAll(state.session.master_fd, "\x1b[201~") catch {};
}

// ── AppDelegate callbacks ─────────────────────────────────────────────────

fn delegateDidFinishLaunching(self_obj: ID, _: SEL, _: ID) callconv(.c) void {
    const state = g_state orelse return;

    const font_name_cf = cfString("Menlo-Regular");
    defer CFRelease(font_name_cf);
    state.font = CTFontCreateWithName(font_name_cf, 14.0, null);

    if (state.font) |font| {
        state.cell_ascent = CTFontGetAscent(font);
        state.cell_h = state.cell_ascent + CTFontGetDescent(font) + CTFontGetLeading(font);
        var uni_m: u16 = 'M';
        var glyph_m: CGGlyph = 0;
        if (CTFontGetGlyphsForCharacters(font, &uni_m, &glyph_m, 1)) {
            var adv: CGSize = .{ .width = 0, .height = 0 };
            _ = CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault, &glyph_m, &adv, 1);
            state.cell_w = adv.width;
        }
    }

    const win_w = state.cell_w * @as(f64, @floatFromInt(state.grid.width));
    const win_h = state.cell_h * @as(f64, @floatFromInt(state.grid.height));
    state.win_w = win_w;
    state.win_h = win_h;

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

    const view = msgRect(
        msg0(cls("ZZTermView"), sel("alloc")),
        sel("initWithFrame:"),
        .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = win_w, .height = win_h } },
    );
    state.view_obj = view;
    msg1ulv(view, sel("setAutoresizingMask:"), NSViewWidthSizable | NSViewHeightSizable);
    msg1v(win, sel("setContentView:"), view);
    msg1v(win, sel("setInitialFirstResponder:"), view);

    const app = msg0(cls("NSApplication"), sel("sharedApplication"));
    msg0v(app, sel("activate"));
    msg1bv(app, sel("activateIgnoringOtherApps:"), 1);
    msg1v(win, sel("makeKeyAndOrderFront:"), null);
    msg0v(win, sel("orderFrontRegardless"));
    msg1v(win, sel("makeFirstResponder:"), view);

    state.session.resize(.{ .rows = @intCast(state.grid.height), .cols = @intCast(state.grid.width) }) catch {};

    const t = std.Thread.spawn(.{}, readerLoop, .{state}) catch return;
    t.detach();

    _ = msgTimer(
        cls("NSTimer"),
        sel("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
        1.0 / 60.0,
        self_obj,
        sel("refreshTick:"),
        null,
        1,
    );
}

fn delegateRefreshTick(self_obj: ID, _: SEL, _: ID) callconv(.c) void {
    const state = g_state orelse return;
    if (!state.running.load(.monotonic)) {
        const app = msg0(cls("NSApplication"), sel("sharedApplication"));
        msg1v(app, sel("terminate:"), self_obj);
        return;
    }
    if (state.dirty.swap(false, .monotonic)) {
        if (state.view_obj) |v| msg1bv(v, sel("setNeedsDisplay:"), 1);
    }
}

fn delegateWindowWillClose(self_obj: ID, _: SEL, _: ID) callconv(.c) void {
    const state = g_state orelse return;
    state.running.store(false, .monotonic);
    const app = msg0(cls("NSApplication"), sel("sharedApplication"));
    msg1v(app, sel("terminate:"), self_obj);
}

fn delegateWindowDidResize(_: ID, _: SEL, _: ID) callconv(.c) void {
    const state = g_state orelse return;
    const view = state.view_obj orelse return;

    const bounds = msgCGRect(view, sel("bounds"));
    const new_w = bounds.size.width;
    const new_h = bounds.size.height;
    if (new_w < 1.0 or new_h < 1.0) return;

    state.mutex.lock();
    defer state.mutex.unlock();

    const cw = state.cell_w;
    const ch = state.cell_h;
    if (cw < 1.0 or ch < 1.0) return;

    const new_cols = @max(1, @as(usize, @intFromFloat(new_w / cw)));
    const new_rows = @max(1, @as(usize, @intFromFloat(new_h / ch)));
    if (new_cols == state.grid.width and new_rows == state.grid.height) return;

    state.grid.resize(new_cols, new_rows) catch return;
    state.session.resize(.{ .rows = @intCast(new_rows), .cols = @intCast(new_cols) }) catch {};
    state.win_w = new_w;
    state.win_h = new_h;

    const hist = @as(i32, @intCast(state.grid.historyLen()));
    if (state.scroll_offset > hist) state.scroll_offset = hist;
    state.dirty.store(true, .monotonic);
}

// ── PTY reader thread ─────────────────────────────────────────────────────

fn readerLoop(state: *AppState) void {
    var buf: [4096]u8 = undefined;
    loop: while (state.running.load(.monotonic)) {
        var fds = [1]posix_pty.PollFd{.{
            .fd = state.session.master_fd,
            .events = posix_pty.PollEvent.input,
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
        state.scroll_offset = 0;
        state.mutex.unlock();

        state.dirty.store(true, .monotonic);
    }
    state.running.store(false, .monotonic);
}

// ── AgentD ────────────────────────────────────────────────────────────────

fn spawnAgentd(state: *AppState, envp: [*:null]const ?[*:0]const u8) void {
    var exe_buf: [4096]u8 = undefined;
    var exe_size: u32 = @intCast(exe_buf.len);
    if (_NSGetExecutablePath(&exe_buf, &exe_size) != 0) return;
    const exe_path = std.mem.sliceTo(&exe_buf, 0);
    const dir = std.fs.path.dirname(exe_path) orelse return;

    var agentd_buf: [4096]u8 = undefined;
    const agentd_path = std.fmt.bufPrintZ(&agentd_buf, "{s}/ziggyzag-agentd", .{dir}) catch return;

    if (std.c.access(agentd_path.ptr, 0) != 0) return;

    var stdin_fds: [2]std.c.fd_t = undefined;
    var stdout_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&stdin_fds) != 0) return;
    if (std.c.pipe(&stdout_fds) != 0) {
        _ = std.c.close(stdin_fds[0]);
        _ = std.c.close(stdin_fds[1]);
        return;
    }

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(stdin_fds[0]);
        _ = std.c.close(stdin_fds[1]);
        _ = std.c.close(stdout_fds[0]);
        _ = std.c.close(stdout_fds[1]);
        return;
    }

    if (pid == 0) {
        _ = std.c.dup2(stdin_fds[0], 0);
        _ = std.c.dup2(stdout_fds[1], 1);
        _ = std.c.close(stdin_fds[0]);
        _ = std.c.close(stdin_fds[1]);
        _ = std.c.close(stdout_fds[0]);
        _ = std.c.close(stdout_fds[1]);
        const argv = [_:null]?[*:0]const u8{ agentd_path.ptr, "--stdio", null };
        _ = std.c.execve(agentd_path.ptr, &argv, envp);
        std.c._exit(1);
    }

    _ = std.c.close(stdin_fds[0]);
    _ = std.c.close(stdout_fds[1]);

    state.agentd_pid = pid;
    state.agentd_write_fd = stdin_fds[1];
    state.agentd_read_fd = stdout_fds[0];
    state.agentd_running.store(true, .monotonic);

    const t = std.Thread.spawn(.{}, agentReaderLoop, .{state}) catch return;
    t.detach();
}

fn agentReaderLoop(state: *AppState) void {
    var buf: [4096]u8 = undefined;
    while (state.agentd_running.load(.monotonic)) {
        const fd: std.c.fd_t = @intCast(state.agentd_read_fd);
        const n_signed = std.c.read(fd, &buf, buf.len);
        if (n_signed <= 0) break;
        const n: usize = @intCast(n_signed);
        state.mutex.lock();
        appendTranscript(state, buf[0..n]);
        state.mutex.unlock();
        state.dirty.store(true, .monotonic);
    }
    state.agentd_running.store(false, .monotonic);
}

fn appendTranscript(state: *AppState, data: []const u8) void {
    const cap = TRANSCRIPT_CAP;
    const avail = cap - state.transcript_len;
    if (data.len <= avail) {
        @memcpy(state.transcript[state.transcript_len..][0..data.len], data);
        state.transcript_len += data.len;
    } else {
        const need = data.len - avail;
        const shift = @min(need, state.transcript_len);
        if (shift > 0 and shift < state.transcript_len) {
            std.mem.copyForwards(u8, &state.transcript, state.transcript[shift..state.transcript_len]);
        }
        state.transcript_len = @min(state.transcript_len, cap - data.len);
        const write_len = @min(data.len, cap - state.transcript_len);
        @memcpy(state.transcript[state.transcript_len..][0..write_len], data[data.len - write_len ..]);
        state.transcript_len += write_len;
    }
}

fn writeAgentLine(state: *AppState, line: []const u8) void {
    if (state.agentd_write_fd < 0) return;
    const fd: std.c.fd_t = @intCast(state.agentd_write_fd);
    _ = std.c.write(fd, line.ptr, line.len);
    _ = std.c.write(fd, "\n", 1);
}

fn requestHealth(state: *AppState) void {
    if (!state.agentd_running.load(.monotonic)) return;
    var buf: [128]u8 = undefined;
    const id = state.agent_next_id;
    state.agent_next_id +%= 1;
    const line = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"agent/health\",\"params\":{{}}}}", .{id}) catch return;
    writeAgentLine(state, line);
}

fn requestTools(state: *AppState) void {
    if (!state.agentd_running.load(.monotonic)) return;
    var buf: [128]u8 = undefined;
    const id = state.agent_next_id;
    state.agent_next_id +%= 1;
    const line = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/list\",\"params\":{{}}}}", .{id}) catch return;
    writeAgentLine(state, line);
}

fn requestAgentRun(state: *AppState, prompt: []const u8) void {
    if (!state.agentd_running.load(.monotonic)) return;
    var esc_buf: [512]u8 = undefined;
    const escaped = escapeJsonPrompt(prompt, &esc_buf);

    var buf: [1024]u8 = undefined;
    const id = state.agent_next_id;
    state.agent_next_id +%= 1;
    const line = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"agent/run\",\"params\":{{\"prompt\":\"{s}\"}}}}", .{ id, escaped }) catch return;
    writeAgentLine(state, line);

    // Log a user-facing transcript message
    var log_buf: [320]u8 = undefined;
    const log_msg = std.fmt.bufPrint(&log_buf, "> agent/run: {s}\n", .{prompt}) catch return;
    appendTranscript(state, log_msg);
}

/// Escape special JSON characters in-place into a stack buffer.
/// Returns the escaped string (valid inside JSON double-quotes).
fn escapeJsonPrompt(prompt: []const u8, dest: []u8) []const u8 {
    var di: usize = 0;
    for (prompt) |b| {
        if (di + 2 >= dest.len) break;
        switch (b) {
            '"' => {
                dest[di] = '\\';
                dest[di + 1] = '"';
                di += 2;
            },
            '\\' => {
                dest[di] = '\\';
                dest[di + 1] = '\\';
                di += 2;
            },
            '\n' => {
                dest[di] = '\\';
                dest[di + 1] = 'n';
                di += 2;
            },
            '\r' => {
                dest[di] = '\\';
                dest[di + 1] = 'r';
                di += 2;
            },
            '\t' => {
                dest[di] = '\\';
                dest[di + 1] = 't';
                di += 2;
            },
            else => {
                dest[di] = b;
                di += 1;
            },
        }
    }
    return dest[0..di];
}

// ── Entry point ───────────────────────────────────────────────────────────

pub fn run(init_data: std.process.Init, shell_path: []const u8) !void {
    const allocator = init_data.gpa;

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

    const argv = [_:null]?[*:0]const u8{shell_path_z.ptr};
    var session = try posix_pty.spawnShell(.{
        .shell_path = shell_path_z.ptr,
        .argv = &argv,
        .envp = env_block.slice.ptr,
        .size = .{ .rows = 24, .cols = 80 },
    });
    errdefer session.closeMaster();

    var grid = try terminal.Grid.init(allocator, 80, 24);
    errdefer grid.deinit();

    const state = try allocator.create(AppState);
    errdefer allocator.destroy(state);
    state.* = .{
        .allocator = allocator,
        .grid = grid,
        .session = session,
    };
    g_state = state;

    spawnAgentd(state, env_block.slice.ptr);

    // ── Register ZZTermView ────────────────────────────────────────────
    const view_cls = allocClass(cls("NSView"), "ZZTermView");
    if (view_cls != null) {
        addClass(view_cls, sel("acceptsFirstResponder"), &viewAcceptsFirstResponder, "B@:");
        addClass(view_cls, sel("drawRect:"), &viewDrawRect, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
        addClass(view_cls, sel("keyDown:"), &viewKeyDown, "v@:@");
        addClass(view_cls, sel("scrollWheel:"), &viewScrollWheel, "v@:@");
        registerClass(view_cls);
    }

    // ── Register ZZAppDelegate ─────────────────────────────────────────
    const del_cls = allocClass(cls("NSObject"), "ZZAppDelegate");
    if (del_cls != null) {
        addClass(del_cls, sel("applicationDidFinishLaunching:"), &delegateDidFinishLaunching, "v@:@");
        addClass(del_cls, sel("refreshTick:"), &delegateRefreshTick, "v@:@");
        addClass(del_cls, sel("windowWillClose:"), &delegateWindowWillClose, "v@:@");
        addClass(del_cls, sel("windowDidResize:"), &delegateWindowDidResize, "v@:@");
        registerClass(del_cls);
    }

    // ── Boot NSApplication ─────────────────────────────────────────────
    const app = msg0(cls("NSApplication"), sel("sharedApplication"));
    if (app == null) return error.NSApplicationFailed;
    msg1lv(app, sel("setActivationPolicy:"), 0);

    const delegate = msg0(msg0(del_cls, sel("alloc")), sel("init"));
    msg1v(app, sel("setDelegate:"), delegate);

    msg0v(app, sel("run"));

    // ── Cleanup ────────────────────────────────────────────────────────
    state.running.store(false, .monotonic);
    state.agentd_running.store(false, .monotonic);
    if (state.agentd_write_fd >= 0) _ = std.c.close(state.agentd_write_fd);
    if (state.agentd_read_fd >= 0) _ = std.c.close(state.agentd_read_fd);
    state.session.closeMaster();
    _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 100 * std.time.ns_per_ms }, null);

    g_state = null;
    if (state.font) |f| CFRelease(f);
    state.grid.deinit();
    allocator.destroy(state);
}
