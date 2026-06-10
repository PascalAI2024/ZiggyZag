//! macOS Cocoa native terminal window host for ZiggyZag (Wave 3+).
//!
//! Coordinate system: standard CoreGraphics (y=0 at bottom, y increases up).
//! Row 0 is the topmost visual row; its bottom edge is at y = H - cell_h.
//! This avoids the isFlipped + text-matrix-double-flip hazard that made text
//! invisible (text matrix scale(1,-1) negated glyph y-positions).
//!
//! Features: dynamic resize, mouse-wheel scrollback, Cmd+V paste,
//! application-cursor arrows, Ctrl+Space AgentD overlay.
//!
//! Entry point: run(init_data, shell_path)

const std       = @import("std");
const builtin   = @import("builtin");
const posix_pty = @import("posix_pty.zig");
const terminal  = @import("terminal.zig");

comptime {
    if (builtin.os.tag != .macos) @compileError("macos_app.zig is macOS-only");
}

const Allocator = std.mem.Allocator;

// Spin-lock (Zig 0.16 std.atomic.Mutex).
const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *SpinLock) void { while (!self.state.tryLock()) {} }
    fn unlock(self: *SpinLock) void { self.state.unlock(); }
};

// ── ObjC runtime ──────────────────────────────────────────────────────────────
const objc = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

// ── CoreGraphics / CoreText forward declarations ───────────────────────────────
//
// We avoid the CG umbrella header (ObjC block syntax / nullability specifiers
// break Zig's @cImport).  Symbols resolve from the linked frameworks.

const CGFloat = f64;
const CFIndex = c_long;
const CGGlyph  = u16;

const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize  = extern struct { width: CGFloat, height: CGFloat };
const CGRect  = extern struct { origin: CGPoint, size: CGSize };
const CGAffineTransform = extern struct {
    a: CGFloat, b: CGFloat, @"c": CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat,
};

const CGContextRef   = *anyopaque;
const CTFontRef      = *anyopaque;
const CFAllocatorRef = ?*anyopaque;
const CFStringRef    = ?*anyopaque;
const CFTypeRef      = ?*anyopaque;
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

// ── ObjC handle types ─────────────────────────────────────────────────────────
const ID  = ?*anyopaque;
const SEL = ?*anyopaque;
const CLS = ?*anyopaque;

const NSTitled: c_ulong         = 1;
const NSClosable: c_ulong       = 2;
const NSMiniaturizable: c_ulong = 4;
const NSResizable: c_ulong      = 8;
const NSBackingStoreBuffered: c_ulong = 2;
const NSViewWidthSizable: c_ulong    = 2;
const NSViewHeightSizable: c_ulong   = 16;

const NSCommandKeyMask: c_ulong = 0x100000;
const NSControlKeyMask: c_ulong = 0x040000;

// Virtual key codes (HIToolbox/Events.h)
const kVK_Space:    u16 = 0x31;
const kVK_V:        u16 = 0x09;
const kVK_H:        u16 = 0x04;
const kVK_T:        u16 = 0x11;
const kVK_Escape:   u16 = 0x35;
const kVK_Delete:   u16 = 0x33;
const kVK_Return:   u16 = 0x24;
const kVK_NumEnter: u16 = 0x4C;
const kVK_Up:       u16 = 0x7E;
const kVK_Down:     u16 = 0x7D;
const kVK_Right:    u16 = 0x7C;
const kVK_Left:     u16 = 0x7B;
const kVK_PageUp:   u16 = 0x74;
const kVK_PageDown: u16 = 0x79;

// ── msgSend wrappers ──────────────────────────────────────────────────────────

inline fn cls(name: [*:0]const u8) CLS { return @ptrCast(objc.objc_getClass(name)); }
inline fn sel(name: [*:0]const u8) SEL { return @ptrCast(objc.sel_registerName(name)); }

fn allocClass(superclass: CLS, name: [*:0]const u8) CLS {
    return @ptrCast(objc.objc_allocateClassPair(@ptrCast(superclass), name, 0));
}
fn addClass(klass: CLS, s: SEL, imp: anytype, types: [*:0]const u8) void {
    _ = objc.class_addMethod(@ptrCast(klass), @ptrCast(s), @ptrCast(imp), types);
}
fn registerClass(klass: CLS) void { objc.objc_registerClassPair(@ptrCast(klass)); }

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

// ── AppState ──────────────────────────────────────────────────────────────────

const TRANSCRIPT_CAP: usize = 8192;

const AppState = struct {
    allocator:       Allocator,
    grid:            terminal.Grid,
    session:         posix_pty.Session,
    mutex:           SpinLock                   = .{},
    dirty:           std.atomic.Value(bool)     = std.atomic.Value(bool).init(false),
    running:         std.atomic.Value(bool)     = std.atomic.Value(bool).init(true),
    view_obj:        ID                         = null,
    font:            ?CTFontRef                 = null,
    cell_w:          f64                        = 8,
    cell_h:          f64                        = 16,
    cell_ascent:     f64                        = 12,
    win_w:           f64                        = 640,
    win_h:           f64                        = 384,
    scroll_offset:   i32                        = 0,
    overlay_visible: bool                       = false,
    // AgentD
    agentd_pid:      i32                        = 0,
    agentd_write_fd: i32                        = -1,
    agentd_read_fd:  i32                        = -1,
    agentd_running:  std.atomic.Value(bool)     = std.atomic.Value(bool).init(false),
    agent_next_id:   u32                        = 1,
    transcript:      [TRANSCRIPT_CAP]u8         = undefined,
    transcript_len:  usize                      = 0,
};

var g_state: ?*AppState = null;

// ── Color palette ─────────────────────────────────────────────────────────────

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

// ── Glyph drawing ─────────────────────────────────────────────────────────────

// Draw a single BMP codepoint at (x, baseline_y) using the current fill color.
// baseline_y is in standard CG coordinates (y=0 at bottom of view).
fn drawGlyph(font: CTFontRef, ctx: CGContextRef, x: f64, baseline_y: f64, cp: u21) void {
    if (cp > 0xFFFF) return;
    var uni: u16 = @intCast(cp);
    var glyph: CGGlyph = 0;
    if (!CTFontGetGlyphsForCharacters(font, &uni, &glyph, 1)) return;
    if (glyph == 0) return;
    const pt = CGPoint{ .x = x, .y = baseline_y };
    CTFontDrawGlyphs(font, &glyph, &pt, 1, ctx);
}

// Draw an ASCII string.  Caller sets the fill color first.
fn drawAscii(font: CTFontRef, ctx: CGContextRef, x0: f64, baseline_y: f64, cw: f64, text: []const u8) void {
    for (text, 0..) |ch, i| {
        if (ch < 0x20 or ch > 0x7E) continue;
        drawGlyph(font, ctx, x0 + cw * @as(f64, @floatFromInt(i)), baseline_y, ch);
    }
}

// ── Row renderer ─────────────────────────────────────────────────────────────

// visual_row: 0 = topmost row on screen.
// H: total view height in points.
fn renderCells(
    ctx:        CGContextRef,
    font:       CTFontRef,
    cells:      []const terminal.Cell,
    width:      usize,
    visual_row: usize,
    cw: f64, ch: f64, asc: f64, H: f64,
) void {
    const y_bot  = H - @as(f64, @floatFromInt(visual_row + 1)) * ch;
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
                .size   = .{ .width = cw, .height = ch },
            });
        }

        const cp = cell.codepoint;
        if (cp == 0 or cp == ' ') continue;

        const fg = namedColor(cell.style.fg, true);
        CGContextSetRGBFillColor(ctx, fg[0], fg[1], fg[2], 1.0);
        drawGlyph(font, ctx, px, y_base, cp);
    }
}

// ── View callbacks ────────────────────────────────────────────────────────────

fn viewAcceptsFirstResponder(_: ID, _: SEL) callconv(.c) u8 { return 1; }

// drawRect:(NSRect)  — standard CG coordinates, no isFlipped.
fn viewDrawRect(_: ID, _: SEL, _: CGRect) callconv(.c) void {
    const state = g_state orelse return;

    const gc = msg0(cls("NSGraphicsContext"), sel("currentContext"));
    if (gc == null) return;
    const ctx = msgCGContext(gc, sel("CGContext"));

    state.mutex.lock();
    defer state.mutex.unlock();

    const grid = &state.grid;
    const cw   = state.cell_w;
    const ch   = state.cell_h;
    const asc  = state.cell_ascent;
    const W    = state.win_w;
    const H    = state.win_h;

    // Background fill
    CGContextSetRGBFillColor(ctx, 0.06, 0.06, 0.09, 1.0);
    CGContextFillRect(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = W, .height = H } });

    const font = state.font orelse return;

    // Unified timeline: indices [0, hist_len) = history, [hist_len, hist_len+height) = screen.
    // scroll_offset > 0 shifts the viewport up into history.
    const hist_len = grid.historyLen();
    const scroll   = state.scroll_offset;

    for (0..grid.height) |i| {
        // tl_idx = position in the unified timeline for visual row i
        const tl: i64 = @as(i64, @intCast(hist_len)) - @as(i64, scroll) + @as(i64, @intCast(i));
        if (tl < 0) continue; // blank (before start of history)

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

    // Block cursor — only when at live screen position (not scrolled into history)
    if (scroll == 0) {
        const cx  = cw * @as(f64, @floatFromInt(grid.cursor_x));
        const cy  = H - @as(f64, @floatFromInt(grid.cursor_y + 1)) * ch;
        CGContextSetRGBFillColor(ctx, 0.9, 0.9, 0.9, 0.55);
        CGContextFillRect(ctx, .{ .origin = .{ .x = cx, .y = cy }, .size = .{ .width = cw, .height = ch } });
    }

    // Scrollback indicator (top-right corner)
    if (scroll > 0) {
        const msg = "[scrollback — wheel to scroll, any key to jump live]";
        const msg_len = @min(msg.len, @as(usize, @intFromFloat(W / cw)));
        const ix = W - cw * @as(f64, @floatFromInt(msg_len));
        CGContextSetRGBFillColor(ctx, 0.9, 0.9, 0.3, 1.0);
        drawAscii(font, ctx, ix, H - ch + asc, cw, msg[0..msg_len]);
    }

    // AgentD overlay
    if (state.overlay_visible) {
        drawOverlay(ctx, state, font, W, H, cw, ch, asc);
    }
}

// AgentD overlay panel (right ~65% of window).
fn drawOverlay(ctx: CGContextRef, state: *AppState, font: CTFontRef, W: f64, H: f64, cw: f64, ch: f64, asc: f64) void {
    const panel_x = W * 0.35;
    const panel_w = W - panel_x;

    // Panel background
    CGContextSetRGBFillColor(ctx, 0.05, 0.05, 0.15, 0.90);
    CGContextFillRect(ctx, .{ .origin = .{ .x = panel_x, .y = 0 }, .size = .{ .width = panel_w, .height = H } });

    // Header bar (top row of panel)
    CGContextSetRGBFillColor(ctx, 0.12, 0.22, 0.55, 1.0);
    CGContextFillRect(ctx, .{ .origin = .{ .x = panel_x, .y = H - ch }, .size = .{ .width = panel_w, .height = ch } });
    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
    drawAscii(font, ctx, panel_x + cw, H - ch + asc, cw, "ZiggyZag Agent  [H]health [T]tools [Esc]close");

    // Status line
    const status: []const u8 = if (state.agentd_running.load(.monotonic))
        "status: connected"
    else
        "status: unavailable (build ziggyzag-agentd first)";
    CGContextSetRGBFillColor(ctx, 0.40, 0.90, 0.40, 1.0);
    drawAscii(font, ctx, panel_x + cw, H - 2.0 * ch + asc, cw, status);

    // Transcript — walk backward through byte buffer, show newest lines at top
    const transcript = state.transcript[0..state.transcript_len];
    const max_cols: usize = @max(1, @as(usize, @intFromFloat(panel_w / cw)) - 2);
    var visual_row: usize = 2; // 0 = header, 1 = status, 2+ = content
    var i: usize = transcript.len;
    CGContextSetRGBFillColor(ctx, 0.72, 0.72, 0.72, 1.0);
    while (i > 0) {
        const y_draw = H - @as(f64, @floatFromInt(visual_row + 1)) * ch + asc;
        if (y_draw < 0.0) break;

        // Walk back to find start of this line
        var end = i;
        if (end > 0 and transcript[end - 1] == '\n') end -= 1;
        var start = end;
        while (start > 0 and transcript[start - 1] != '\n') start -= 1;

        if (start < end) {
            const line = transcript[start..end];
            const display = if (line.len > max_cols) line[0..max_cols] else line;
            drawAscii(font, ctx, panel_x + cw, y_draw, cw, display);
            visual_row += 1;
        }

        if (start == 0) break;
        i = start - 1; // skip the newline before this line
    }
}

// keyDown:(NSEvent*)
fn viewKeyDown(_: ID, _: SEL, event_obj: ID) callconv(.c) void {
    const state = g_state orelse return;
    if (!state.running.load(.monotonic)) return;

    const kc   = msgKeyCode(event_obj, sel("keyCode"));
    const mods = msgULong(event_obj, sel("modifierFlags"));

    // Ctrl+Space → toggle AgentD overlay
    if (kc == kVK_Space and (mods & NSControlKeyMask) != 0) {
        state.mutex.lock();
        const was_visible = state.overlay_visible;
        state.overlay_visible = !was_visible;
        state.mutex.unlock();
        state.dirty.store(true, .monotonic);
        if (!was_visible) requestHealth(state);
        return;
    }

    // Overlay key handling (Esc, H, T)
    if (state.overlay_visible) {
        switch (kc) {
            kVK_Escape => {
                state.mutex.lock();
                state.overlay_visible = false;
                state.mutex.unlock();
                state.dirty.store(true, .monotonic);
            },
            kVK_H => requestHealth(state),
            kVK_T => requestTools(state),
            else   => {},
        }
        return;
    }

    // Cmd+V → paste from clipboard
    if (kc == kVK_V and (mods & NSCommandKeyMask) != 0) {
        pasteFromPasteboard(state);
        return;
    }

    // Any key while scrolled → jump back to live screen
    if (state.scroll_offset > 0) {
        state.mutex.lock();
        state.scroll_offset = 0;
        state.mutex.unlock();
        state.dirty.store(true, .monotonic);
        // Don't consume the key — let it fall through to the PTY
    }

    // Arrow keys: application cursor vs. ANSI
    const app_cursor = state.grid.isApplicationCursorEnabled();
    switch (kc) {
        kVK_Up    => { posix_pty.writeAll(state.session.master_fd, if (app_cursor) "\x1bOA" else "\x1b[A") catch {}; return; },
        kVK_Down  => { posix_pty.writeAll(state.session.master_fd, if (app_cursor) "\x1bOB" else "\x1b[B") catch {}; return; },
        kVK_Right => { posix_pty.writeAll(state.session.master_fd, if (app_cursor) "\x1bOC" else "\x1b[C") catch {}; return; },
        kVK_Left  => { posix_pty.writeAll(state.session.master_fd, if (app_cursor) "\x1bOD" else "\x1b[D") catch {}; return; },
        else      => {},
    }

    const special: ?[]const u8 = switch (kc) {
        kVK_Escape              => "\x1b",
        kVK_Delete              => "\x7f",
        kVK_Return, kVK_NumEnter => "\r",
        kVK_PageUp              => "\x1b[5~",
        kVK_PageDown            => "\x1b[6~",
        else                    => null,
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

// scrollWheel:(NSEvent*)
fn viewScrollWheel(_: ID, _: SEL, event_obj: ID) callconv(.c) void {
    const state = g_state orelse return;
    // On alternate screen, apps handle scrolling themselves (mouse reports, etc.)
    if (state.grid.isAlternateScreen()) return;

    const delta = msgDouble(event_obj, sel("scrollingDeltaY"));
    // Positive delta = scroll up (increase offset = show older history)
    const lines: i32 = @intFromFloat(delta / 3.0);
    if (lines == 0) return;

    state.mutex.lock();
    const hist = @as(i32, @intCast(state.grid.historyLen()));
    state.scroll_offset = std.math.clamp(state.scroll_offset + lines, 0, hist);
    state.mutex.unlock();
    state.dirty.store(true, .monotonic);
}

// ── Paste ─────────────────────────────────────────────────────────────────────

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

// ── AppDelegate callbacks ─────────────────────────────────────────────────────

fn delegateDidFinishLaunching(self_obj: ID, _: SEL, _: ID) callconv(.c) void {
    const state = g_state orelse return;

    // Load Menlo-Regular 14pt and derive cell metrics
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

    // Create NSWindow
    const win = msgInitWindow(
        msg0(cls("NSWindow"), sel("alloc")),
        sel("initWithContentRect:styleMask:backing:defer:"),
        .{ .origin = .{ .x = 120, .y = 120 }, .size = .{ .width = win_w, .height = win_h } },
        NSTitled | NSClosable | NSMiniaturizable | NSResizable,
        NSBackingStoreBuffered, 0,
    );
    const title_cf = cfString("ZiggyZag");
    defer if (title_cf) |t| CFRelease(t);
    msg1v(win, sel("setTitle:"), title_cf);
    msg1v(win, sel("setDelegate:"), self_obj);

    // Create ZZTermView
    const view = msgRect(
        msg0(cls("ZZTermView"), sel("alloc")),
        sel("initWithFrame:"),
        .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = win_w, .height = win_h } },
    );
    state.view_obj = view;
    msg1ulv(view, sel("setAutoresizingMask:"), NSViewWidthSizable | NSViewHeightSizable);
    msg1v(win, sel("setContentView:"), view);
    msg1v(win, sel("setInitialFirstResponder:"), view);

    // Activate (macOS 14+ needs [NSApp activate]; older needs activateIgnoringOtherApps:)
    const app = msg0(cls("NSApplication"), sel("sharedApplication"));
    msg0v(app, sel("activate"));
    msg1bv(app, sel("activateIgnoringOtherApps:"), 1);
    msg1v(win, sel("makeKeyAndOrderFront:"), null);
    msg0v(win, sel("orderFrontRegardless"));
    msg1v(win, sel("makeFirstResponder:"), view);

    state.session.resize(.{ .rows = @intCast(state.grid.height), .cols = @intCast(state.grid.width) }) catch {};

    // PTY reader thread
    const t = std.Thread.spawn(.{}, readerLoop, .{state}) catch return;
    t.detach();

    // 60-fps refresh timer
    _ = msgTimer(
        cls("NSTimer"),
        sel("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
        1.0 / 60.0, self_obj, sel("refreshTick:"), null, 1,
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

// Called when the user resizes the window.
fn delegateWindowDidResize(_: ID, _: SEL, _: ID) callconv(.c) void {
    const state = g_state orelse return;
    const view  = state.view_obj orelse return;

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

// ── PTY reader thread ─────────────────────────────────────────────────────────

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
        state.scroll_offset = 0; // new output → jump to live screen
        state.mutex.unlock();

        state.dirty.store(true, .monotonic);
    }
    state.running.store(false, .monotonic);
}

// ── AgentD ────────────────────────────────────────────────────────────────────

fn spawnAgentd(state: *AppState, envp: [*:null]const ?[*:0]const u8) void {
    // Find ziggyzag-agentd in the same directory as our executable
    var exe_buf: [4096]u8 = undefined;
    var exe_size: u32 = @intCast(exe_buf.len);
    if (_NSGetExecutablePath(&exe_buf, &exe_size) != 0) return;
    const exe_path = std.mem.sliceTo(&exe_buf, 0);
    const dir = std.fs.path.dirname(exe_path) orelse return;

    var agentd_buf: [4096]u8 = undefined;
    const agentd_path = std.fmt.bufPrintZ(&agentd_buf, "{s}/ziggyzag-agentd", .{dir}) catch return;

    // Verify it exists before forking (access F_OK = 0 on macOS)
    if (std.c.access(agentd_path.ptr, 0) != 0) return;

    var stdin_fds: [2]std.c.fd_t = undefined;
    var stdout_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&stdin_fds) != 0) return;
    if (std.c.pipe(&stdout_fds) != 0) {
        _ = std.c.close(stdin_fds[0]); _ = std.c.close(stdin_fds[1]);
        return;
    }

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(stdin_fds[0]);  _ = std.c.close(stdin_fds[1]);
        _ = std.c.close(stdout_fds[0]); _ = std.c.close(stdout_fds[1]);
        return;
    }

    if (pid == 0) {
        // Child: wire pipes to stdin/stdout and exec agentd
        _ = std.c.dup2(stdin_fds[0], 0);
        _ = std.c.dup2(stdout_fds[1], 1);
        _ = std.c.close(stdin_fds[0]);  _ = std.c.close(stdin_fds[1]);
        _ = std.c.close(stdout_fds[0]); _ = std.c.close(stdout_fds[1]);
        const argv = [_:null]?[*:0]const u8{ agentd_path.ptr, "--stdio", null };
        _ = std.c.execve(agentd_path.ptr, &argv, envp);
        std.c._exit(1);
    }

    // Parent: keep write end of stdin_fds, read end of stdout_fds
    _ = std.c.close(stdin_fds[0]);
    _ = std.c.close(stdout_fds[1]);

    state.agentd_pid      = pid;
    state.agentd_write_fd = stdin_fds[1];
    state.agentd_read_fd  = stdout_fds[0];
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
        // Discard oldest bytes to make room
        const need  = data.len - avail;
        const shift = @min(need, state.transcript_len);
        if (shift > 0 and shift < state.transcript_len) {
            std.mem.copyForwards(u8, &state.transcript, state.transcript[shift..state.transcript_len]);
        }
        state.transcript_len = @min(state.transcript_len, cap - data.len);
        const write_len = @min(data.len, cap - state.transcript_len);
        @memcpy(state.transcript[state.transcript_len..][0..write_len], data[data.len - write_len..]);
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
    const line = std.fmt.bufPrint(&buf,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"agent/health\",\"params\":{{}}}}", .{id}) catch return;
    writeAgentLine(state, line);
}

fn requestTools(state: *AppState) void {
    if (!state.agentd_running.load(.monotonic)) return;
    var buf: [128]u8 = undefined;
    const id = state.agent_next_id;
    state.agent_next_id +%= 1;
    const line = std.fmt.bufPrint(&buf,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/list\",\"params\":{{}}}}", .{id}) catch return;
    writeAgentLine(state, line);
}

// ── Entry point ───────────────────────────────────────────────────────────────

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
        .argv       = &argv,
        .envp       = env_block.slice.ptr,
        .size       = .{ .rows = 24, .cols = 80 },
    });
    errdefer session.closeMaster();

    var grid = try terminal.Grid.init(allocator, 80, 24);
    errdefer grid.deinit();

    const state = try allocator.create(AppState);
    errdefer allocator.destroy(state);
    state.* = .{
        .allocator = allocator,
        .grid      = grid,
        .session   = session,
    };
    g_state = state;

    // Spawn agentd BEFORE [NSApp run] to avoid the fork-after-Cocoa hazard
    // (fork() after NSApp initialisation can deadlock on pthread_atfork).
    spawnAgentd(state, env_block.slice.ptr);

    // ── Register ZZTermView ────────────────────────────────────────────────
    const view_cls = allocClass(cls("NSView"), "ZZTermView");
    if (view_cls != null) {
        addClass(view_cls, sel("acceptsFirstResponder"), &viewAcceptsFirstResponder, "B@:");
        addClass(view_cls, sel("drawRect:"),             &viewDrawRect,  "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
        addClass(view_cls, sel("keyDown:"),              &viewKeyDown,   "v@:@");
        addClass(view_cls, sel("scrollWheel:"),          &viewScrollWheel, "v@:@");
        registerClass(view_cls);
    }

    // ── Register ZZAppDelegate ─────────────────────────────────────────────
    const del_cls = allocClass(cls("NSObject"), "ZZAppDelegate");
    if (del_cls != null) {
        addClass(del_cls, sel("applicationDidFinishLaunching:"), &delegateDidFinishLaunching, "v@:@");
        addClass(del_cls, sel("refreshTick:"),                   &delegateRefreshTick,         "v@:@");
        addClass(del_cls, sel("windowWillClose:"),               &delegateWindowWillClose,     "v@:@");
        addClass(del_cls, sel("windowDidResize:"),               &delegateWindowDidResize,     "v@:@");
        registerClass(del_cls);
    }

    // ── Boot NSApplication ─────────────────────────────────────────────────
    const app = msg0(cls("NSApplication"), sel("sharedApplication"));
    if (app == null) return error.NSApplicationFailed;
    msg1lv(app, sel("setActivationPolicy:"), 0);

    const delegate = msg0(msg0(del_cls, sel("alloc")), sel("init"));
    msg1v(app, sel("setDelegate:"), delegate);

    msg0v(app, sel("run")); // blocks until [NSApp terminate:]

    // ── Cleanup ────────────────────────────────────────────────────────────
    state.running.store(false, .monotonic);
    state.agentd_running.store(false, .monotonic);
    if (state.agentd_write_fd >= 0) _ = std.c.close(state.agentd_write_fd);
    if (state.agentd_read_fd  >= 0) _ = std.c.close(state.agentd_read_fd);
    state.session.closeMaster();
    _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 100 * std.time.ns_per_ms }, null);

    g_state = null;
    if (state.font) |f| CFRelease(f);
    state.grid.deinit();
    allocator.destroy(state);
}
