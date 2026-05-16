// VT parser architecture note: the incremental byte-driven state machine here
// is adequate for the current feature set (ECMA-48 CSI/OSC, SGR, scroll
// regions, private modes). A natural upgrade threshold is adding DCS/SOS/PM/APC
// parsing, character-set designations (SCS), or full DECSC scope (saved origin
// mode, character sets). At that point pulling in libghostty-vt would pay for
// itself by providing a maintained, fuzz-tested VT state machine; until then the
// in-tree parser keeps the dependency surface minimal.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Color = enum(u8) {
    default,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const ExtendedColor = union(enum) {
    named: Color,
    indexed: u8,
    rgb: Rgb,
};

pub const Style = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    double_underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    fg: Color = .default,
    bg: Color = .default,
    fg_extended: ?ExtendedColor = null,
    bg_extended: ?ExtendedColor = null,
    underline_color: ?ExtendedColor = null,

    pub fn foreground(self: Style) ExtendedColor {
        return self.fg_extended orelse .{ .named = self.fg };
    }

    pub fn background(self: Style) ExtendedColor {
        return self.bg_extended orelse .{ .named = self.bg };
    }
};

pub const Cell = struct {
    ch: u8 = ' ',
    codepoint: u21 = ' ',
    width: CellWidth = .narrow,
    style: Style = .{},

    pub fn isContinuation(self: Cell) bool {
        return self.width == .continuation;
    }
};

pub const CellWidth = enum(u8) {
    narrow,
    wide,
    continuation,
};

pub const HistoryLine = struct {
    width: usize,
    cells: []Cell,
};

pub const MouseTracking = enum(u8) {
    disabled,
    x10,
    normal,
    button_event,
    any_event,
};

pub const MouseEncoding = enum(u8) {
    default,
    utf8,
    sgr,
    urxvt,
};

const BufferState = struct {
    cursor_x: usize = 0,
    cursor_y: usize = 0,
    saved_cursor_x: usize = 0,
    saved_cursor_y: usize = 0,
    wrap_pending: bool = false,
};

// Incremental escape-sequence parser state. Stored on the Grid so a sequence
// split across feed() calls (PTY reads are chunked at arbitrary boundaries)
// resumes instead of being printed as literal garbage.
const ParseState = enum {
    ground,
    escape,
    csi,
    osc,
};

// CSI parameter/intermediate bytes are short in practice; cap defensively so a
// hostile or runaway stream cannot grow an unbounded buffer. On overflow the
// sequence is consumed-and-ignored, then the parser resyncs to ground.
const csi_buffer_cap: usize = 256;

pub const default_max_scrollback: usize = 10_000;

pub const Grid = struct {
    allocator: Allocator,
    width: usize,
    height: usize,
    cursor_x: usize = 0,
    cursor_y: usize = 0,
    saved_cursor_x: usize = 0,
    saved_cursor_y: usize = 0,
    wrap_pending: bool = false,
    primary_cells: []Cell,
    alternate_cells: []Cell,
    cells: []Cell,
    primary_state: BufferState = .{},
    alternate_state: BufferState = .{},
    alternate_screen: bool = false,
    bracketed_paste: bool = false,
    application_cursor: bool = false,
    application_keypad: bool = false,
    // DECAWM: when false, printable chars at the right margin overwrite the
    // last cell instead of wrapping. Defaults to true (wrap enabled).
    auto_wrap: bool = true,
    // DECOM origin mode: when true, CSI H/f row parameters are relative to
    // scroll_top and the cursor is constrained within [scroll_top,scroll_bottom].
    // Enabling or disabling DECOM also homes the cursor to the (new) origin.
    // Note: DECSC/DECRC do not currently save/restore origin_mode; that
    // omission is tracked as a future improvement (see libghostty-vt note).
    origin_mode: bool = false,
    mouse_tracking: MouseTracking = .disabled,
    mouse_encoding: MouseEncoding = .default,
    current_style: Style = .{},
    history: std.ArrayList(HistoryLine) = .empty,
    max_scrollback: usize = default_max_scrollback,

    // DECSTBM scroll region, 0-based inclusive. Defaults to the whole screen.
    scroll_top: usize = 0,
    scroll_bottom: usize = 0,

    // Horizontal tab stops. A set bit at column index means there is a stop
    // there. Default stops are at every 8th column (0, 8, 16, ...). A null
    // value means we are using the default 8-column rule via arithmetic
    // (avoids an allocation for grids that never set/clear custom stops).
    tab_stops: ?std.DynamicBitSet = null,

    // Resumable escape parser. esc_buffer accumulates CSI param/intermediate
    // bytes; utf8_buffer holds a multi-byte scalar split across feed() calls.
    parse_state: ParseState = .ground,
    esc_buffer: [csi_buffer_cap]u8 = undefined,
    esc_len: usize = 0,
    esc_overflow: bool = false,
    osc_saw_esc: bool = false,
    utf8_buffer: [4]u8 = undefined,
    utf8_len: usize = 0,
    utf8_need: usize = 0,

    pub fn init(allocator: Allocator, width: usize, height: usize) !Grid {
        return initWithMaxScrollback(allocator, width, height, default_max_scrollback);
    }

    pub fn initWithMaxScrollback(allocator: Allocator, width: usize, height: usize, max_scrollback: usize) !Grid {
        if (width == 0 or height == 0) return error.InvalidGridSize;
        const primary_cells = try allocator.alloc(Cell, width * height);
        errdefer allocator.free(primary_cells);
        const alternate_cells = try allocator.alloc(Cell, width * height);
        @memset(primary_cells, .{});
        @memset(alternate_cells, .{});
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .primary_cells = primary_cells,
            .alternate_cells = alternate_cells,
            .cells = primary_cells,
            .max_scrollback = max_scrollback,
            .scroll_bottom = height - 1,
        };
    }

    pub fn deinit(self: *Grid) void {
        for (self.history.items) |line| {
            self.allocator.free(line.cells);
        }
        self.history.deinit(self.allocator);
        self.allocator.free(self.primary_cells);
        self.allocator.free(self.alternate_cells);
        if (self.tab_stops) |*ts| ts.deinit();
        self.* = undefined;
    }

    pub fn feed(self: *Grid, bytes: []const u8) void {
        for (bytes) |byte| self.feedByte(byte);
    }

    fn feedByte(self: *Grid, byte: u8) void {
        switch (self.parse_state) {
            .ground => self.groundByte(byte),
            .escape => self.escapeByte(byte),
            .csi => self.csiByte(byte),
            .osc => self.oscByte(byte),
        }
    }

    fn groundByte(self: *Grid, byte: u8) void {
        if (self.utf8_len > 0) {
            // Mid multi-byte scalar: a valid continuation extends it; anything
            // else means the lead was invalid (matches decodeUtf8Scalar, which
            // emits one replacement and consumes only the lead byte).
            if (byte >= 0x80 and byte <= 0xbf) {
                self.utf8_buffer[self.utf8_len] = byte;
                self.utf8_len += 1;
                if (self.utf8_len == self.utf8_need) {
                    const decoded = decodeUtf8Scalar(self.utf8_buffer[0..self.utf8_len]);
                    if (decoded.len == self.utf8_need) {
                        self.utf8_len = 0;
                        self.utf8_need = 0;
                        self.putCodepoint(decoded.codepoint);
                    } else {
                        // Overlong / surrogate / out-of-range: decodeUtf8Scalar
                        // consumes only the lead byte, so emit one replacement
                        // and reprocess the continuation bytes.
                        self.flushInvalidUtf8();
                    }
                }
                return;
            }
            self.flushInvalidUtf8();
            // fall through and reprocess this byte as fresh ground input
        }

        switch (byte) {
            '\n' => {
                self.wrap_pending = false;
                self.newline();
            },
            '\r' => {
                self.wrap_pending = false;
                self.cursor_x = 0;
            },
            0x08 => {
                self.wrap_pending = false;
                if (self.cursor_x > 0) self.cursor_x -= 1;
            },
            '\t' => self.tab(),
            0x1b => self.parse_state = .escape,
            else => {
                if (byte < 0x20) return;
                if (byte < 0x80) {
                    self.putCodepoint(byte);
                    return;
                }
                const need = utf8SequenceLen(byte);
                if (need == 0) {
                    // invalid lead byte: replacement, consume one byte
                    self.putCodepoint(replacement_codepoint);
                    return;
                }
                self.utf8_buffer[0] = byte;
                self.utf8_len = 1;
                self.utf8_need = need;
            },
        }
    }

    fn flushInvalidUtf8(self: *Grid) void {
        // The buffered lead byte is invalid; emit one replacement for it and
        // reprocess the gathered continuation bytes as fresh input. Each is in
        // 0x80..0xbf, so each independently becomes its own replacement, which
        // matches decodeUtf8Scalar consuming only the lead byte on failure.
        var saved: [4]u8 = undefined;
        const n = self.utf8_len;
        @memcpy(saved[0..n], self.utf8_buffer[0..n]);
        self.utf8_len = 0;
        self.utf8_need = 0;
        self.putCodepoint(replacement_codepoint);
        var i: usize = 1;
        while (i < n) : (i += 1) self.groundByte(saved[i]);
    }

    fn escapeByte(self: *Grid, byte: u8) void {
        switch (byte) {
            '[' => {
                self.parse_state = .csi;
                self.esc_len = 0;
                self.esc_overflow = false;
            },
            ']' => {
                self.parse_state = .osc;
                self.osc_saw_esc = false;
            },
            '7' => {
                self.saveCursor();
                self.parse_state = .ground;
            },
            '8' => {
                self.restoreCursor();
                self.parse_state = .ground;
            },
            'M' => {
                self.reverseIndex();
                self.parse_state = .ground;
            },
            'D' => {
                self.lineFeed();
                self.parse_state = .ground;
            },
            'E' => {
                self.cursor_x = 0;
                self.lineFeed();
                self.parse_state = .ground;
            },
            'c' => {
                self.hardReset();
                self.parse_state = .ground;
            },
            // HTS — Horizontal Tab Set: sets a tab stop at the current column.
            'H' => {
                self.setTabStop(self.cursor_x);
                self.parse_state = .ground;
            },
            // Application keypad (DECKPAM) / Normal keypad (DECKPNM).
            '=' => {
                self.application_keypad = true;
                self.parse_state = .ground;
            },
            '>' => {
                self.application_keypad = false;
                self.parse_state = .ground;
            },
            else => self.parse_state = .ground,
        }
    }

    fn csiByte(self: *Grid, byte: u8) void {
        if (byte == 0x1b) {
            // A new escape aborts a malformed CSI and resyncs the parser.
            self.parse_state = .escape;
            return;
        }
        // ECMA-48 §8.3: C0 controls (other than CAN/SUB/ESC) execute in place
        // inside a CSI sequence without aborting it. We handle the printable
        // C0 set: BS, HT, LF/VT/FF (all line feeds), CR.
        // CAN (0x18) and SUB (0x1a) abort the sequence per the spec.
        switch (byte) {
            0x08 => { // BS — backspace
                if (self.cursor_x > 0) self.cursor_x -= 1;
                return;
            },
            0x09 => { // HT — horizontal tab
                self.tab();
                return;
            },
            0x0a, 0x0b, 0x0c => { // LF / VT / FF — line feed
                self.wrap_pending = false;
                self.newline();
                return;
            },
            0x0d => { // CR — carriage return
                self.wrap_pending = false;
                self.cursor_x = 0;
                return;
            },
            0x18, 0x1a => { // CAN / SUB — abort sequence
                self.esc_len = 0;
                self.esc_overflow = false;
                self.parse_state = .ground;
                return;
            },
            else => {},
        }
        if (byte >= 0x40 and byte <= 0x7e) {
            if (!self.esc_overflow) self.applyCsi(self.esc_buffer[0..self.esc_len], byte);
            self.esc_len = 0;
            self.esc_overflow = false;
            self.parse_state = .ground;
            return;
        }
        if (self.esc_len < self.esc_buffer.len) {
            self.esc_buffer[self.esc_len] = byte;
            self.esc_len += 1;
        } else {
            self.esc_overflow = true;
        }
    }

    fn oscByte(self: *Grid, byte: u8) void {
        // The grid does not act on OSC payloads (title/hyperlink/clipboard);
        // it only consumes them so they never corrupt the visible cells.
        if (self.osc_saw_esc) {
            self.osc_saw_esc = false;
            if (byte == '\\') {
                self.parse_state = .ground; // ST terminator (ESC \)
            } else {
                // ESC began a new sequence inside the OSC string.
                self.parse_state = .escape;
                self.escapeByte(byte);
            }
            return;
        }
        switch (byte) {
            0x07 => self.parse_state = .ground, // BEL terminator
            0x1b => self.osc_saw_esc = true,
            0x18, 0x1a => self.parse_state = .ground, // CAN / SUB abort
            else => {},
        }
    }

    pub fn isAlternateScreen(self: *const Grid) bool {
        return self.alternate_screen;
    }

    pub fn isBracketedPasteEnabled(self: *const Grid) bool {
        return self.bracketed_paste;
    }

    pub fn isApplicationCursorEnabled(self: *const Grid) bool {
        return self.application_cursor;
    }

    pub fn isApplicationKeypadEnabled(self: *const Grid) bool {
        return self.application_keypad;
    }

    pub fn isAutoWrapEnabled(self: *const Grid) bool {
        return self.auto_wrap;
    }

    pub fn isOriginModeEnabled(self: *const Grid) bool {
        return self.origin_mode;
    }

    pub fn mouseTrackingMode(self: *const Grid) MouseTracking {
        return self.mouse_tracking;
    }

    pub fn mouseEncodingMode(self: *const Grid) MouseEncoding {
        return self.mouse_encoding;
    }

    pub fn lineAlloc(self: *const Grid, allocator: Allocator, row: usize) ![]u8 {
        if (row >= self.height) return error.RowOutOfBounds;
        const text = try allocator.alloc(u8, self.width);
        for (text, 0..) |*out, index| {
            out.* = self.cells[row * self.width + index].ch;
        }
        return text;
    }

    pub fn lineTextAlloc(self: *const Grid, allocator: Allocator, row: usize) ![]u8 {
        if (row >= self.height) return error.RowOutOfBounds;
        const line = self.cells[row * self.width .. (row + 1) * self.width];
        return cellsTextAlloc(allocator, line);
    }

    pub fn historyLen(self: *const Grid) usize {
        return self.history.items.len;
    }

    pub fn setMaxScrollback(self: *Grid, max_scrollback: usize) void {
        self.max_scrollback = max_scrollback;
        self.trimHistory();
    }

    pub fn historyLineAlloc(self: *const Grid, allocator: Allocator, row: usize) ![]u8 {
        if (row >= self.history.items.len) return error.RowOutOfBounds;
        const line = self.history.items[row];
        const text = try allocator.alloc(u8, line.width);
        for (text, 0..) |*out, index| {
            out.* = line.cells[index].ch;
        }
        return text;
    }

    pub fn historyLineTextAlloc(self: *const Grid, allocator: Allocator, row: usize) ![]u8 {
        if (row >= self.history.items.len) return error.RowOutOfBounds;
        return cellsTextAlloc(allocator, self.history.items[row].cells);
    }

    pub fn visibleTextAlloc(self: *const Grid, allocator: Allocator) ![]u8 {
        var len: usize = 0;
        var row: usize = 0;
        while (row < self.height) : (row += 1) {
            const line = self.cells[row * self.width .. (row + 1) * self.width];
            len += cellsTextLen(line[0..trimmedCellLen(line)]);
            if (row + 1 < self.height) len += 1;
        }

        const text = try allocator.alloc(u8, len);
        var out: usize = 0;
        row = 0;
        while (row < self.height) : (row += 1) {
            const line = self.cells[row * self.width .. (row + 1) * self.width];
            const trimmed_len = trimmedCellLen(line);
            out += encodeCellsText(line[0..trimmed_len], text[out..]);
            if (row + 1 < self.height) {
                text[out] = '\n';
                out += 1;
            }
        }
        return text;
    }

    pub fn selectionAlloc(
        self: *const Grid,
        allocator: Allocator,
        start_row: usize,
        start_col: usize,
        end_row: usize,
        end_col: usize,
    ) ![]u8 {
        if (start_row >= self.height or end_row >= self.height) return error.RowOutOfBounds;

        var first_row = start_row;
        var first_col = start_col;
        var last_row = end_row;
        var last_col = end_col;
        if (last_row < first_row or (last_row == first_row and last_col < first_col)) {
            first_row = end_row;
            first_col = end_col;
            last_row = start_row;
            last_col = start_col;
        }

        var len: usize = 0;
        var row: usize = first_row;
        while (row <= last_row) : (row += 1) {
            const line_start = if (row == first_row) @min(first_col, self.width) else 0;
            const line_end = if (row == last_row) @min(last_col, self.width) else self.width;
            if (line_end > line_start) {
                const line = self.cells[row * self.width .. (row + 1) * self.width];
                len += cellsTextLen(line[line_start..line_end]);
            }
            if (row < last_row) len += 1;
        }

        const text = try allocator.alloc(u8, len);
        var out: usize = 0;
        row = first_row;
        while (row <= last_row) : (row += 1) {
            const line_start = if (row == first_row) @min(first_col, self.width) else 0;
            const line_end = if (row == last_row) @min(last_col, self.width) else self.width;
            const line = self.cells[row * self.width .. (row + 1) * self.width];
            out += encodeCellsText(line[line_start..line_end], text[out..]);
            if (row < last_row) {
                text[out] = '\n';
                out += 1;
            }
        }
        return text;
    }

    pub fn resize(self: *Grid, width: usize, height: usize) !void {
        if (width == 0 or height == 0) return error.InvalidGridSize;
        if (width == self.width and height == self.height) return;

        const old_width = self.width;
        const old_height = self.height;
        const old_primary_cells = self.primary_cells;
        const old_alternate_cells = self.alternate_cells;
        const new_primary_cells = try self.allocator.alloc(Cell, width * height);
        errdefer self.allocator.free(new_primary_cells);
        const new_alternate_cells = try self.allocator.alloc(Cell, width * height);
        @memset(new_primary_cells, .{});
        @memset(new_alternate_cells, .{});

        const copy_width = @min(old_width, width);
        const copy_height = @min(old_height, height);
        copyResizedCells(new_primary_cells, width, old_primary_cells, old_width, copy_width, copy_height);
        copyResizedCells(new_alternate_cells, width, old_alternate_cells, old_width, copy_width, copy_height);

        self.allocator.free(old_primary_cells);
        self.allocator.free(old_alternate_cells);
        self.width = width;
        self.height = height;
        self.primary_cells = new_primary_cells;
        self.alternate_cells = new_alternate_cells;
        self.cells = if (self.alternate_screen) self.alternate_cells else self.primary_cells;
        self.cursor_x = @min(self.cursor_x, width - 1);
        self.cursor_y = @min(self.cursor_y, height - 1);
        self.saved_cursor_x = @min(self.saved_cursor_x, width - 1);
        self.saved_cursor_y = @min(self.saved_cursor_y, height - 1);
        clampBufferState(&self.primary_state, width, height);
        clampBufferState(&self.alternate_state, width, height);
        self.wrap_pending = false;
        // A resize invalidates any in-flight escape sequence and the prior
        // scroll region; reset both rather than carrying stale geometry.
        self.resetScrollRegion();
        // Deinit any existing tab-stop bitmap so resetTabStops reinitialises
        // it at the new width. The arithmetic fallback in hasTabStop covers
        // grids that never used custom stops.
        if (self.tab_stops) |*ts| {
            ts.deinit();
            self.tab_stops = null;
        }
        self.resetTabStops();
        self.resetParser();
    }

    fn resetScrollRegion(self: *Grid) void {
        self.scroll_top = 0;
        self.scroll_bottom = self.height - 1;
    }

    fn resetParser(self: *Grid) void {
        self.parse_state = .ground;
        self.esc_len = 0;
        self.esc_overflow = false;
        self.osc_saw_esc = false;
        self.utf8_len = 0;
        self.utf8_need = 0;
    }

    // Returns true if there is a tab stop at `col`.  When tab_stops is null we
    // fall back to the default 8-column rule.
    fn hasTabStop(self: *const Grid, col: usize) bool {
        if (self.tab_stops) |*ts| return ts.isSet(col);
        return col % 8 == 0;
    }

    // Ensure tab_stops is allocated (lazily), then set or clear the bit at col.
    fn ensureTabStops(self: *Grid) !void {
        if (self.tab_stops == null) {
            var bs = try std.DynamicBitSet.initEmpty(self.allocator, self.width);
            // Initialise with default 8-column stops.
            var c: usize = 0;
            while (c < self.width) : (c += 8) bs.set(c);
            self.tab_stops = bs;
        }
    }

    // HTS (ESC H): set a tab stop at the current column.
    fn setTabStop(self: *Grid, col: usize) void {
        if (col >= self.width) return;
        // Fast path: the column already has a default stop — nothing to do.
        if (self.tab_stops == null and col % 8 == 0) return;
        self.ensureTabStops() catch return;
        self.tab_stops.?.set(col);
    }

    // TBC (CSI g): param 0 clears the stop at the cursor; param 3 clears all.
    fn clearTabStop(self: *Grid, params: []const u8) void {
        const mode = csiParam(params, 0, 0);
        switch (mode) {
            0 => {
                const col = self.cursor_x;
                if (col >= self.width) return;
                // If we haven't materialised the bitmap yet, the stop only
                // exists if it falls on a default boundary.
                if (self.tab_stops == null and col % 8 != 0) return;
                self.ensureTabStops() catch return;
                self.tab_stops.?.unset(col);
            },
            3 => {
                // Clear all stops: replace with an all-zeros bitmap.
                if (self.tab_stops) |*ts| {
                    ts.setRangeValue(.{ .start = 0, .end = ts.capacity() }, false);
                } else {
                    self.ensureTabStops() catch return;
                    self.tab_stops.?.setRangeValue(.{ .start = 0, .end = self.tab_stops.?.capacity() }, false);
                }
            },
            else => {},
        }
    }

    // Restore default 8-column tab stops (called on resize and hard reset).
    fn resetTabStops(self: *Grid) void {
        if (self.tab_stops) |*ts| {
            ts.setRangeValue(.{ .start = 0, .end = ts.capacity() }, false);
            var c: usize = 0;
            while (c < ts.capacity()) : (c += 8) ts.set(c);
        }
        // If tab_stops is null the arithmetic fallback in hasTabStop already
        // gives correct default behaviour — nothing to do.
    }

    fn setScrollRegion(self: *Grid, params: []const u8) void {
        const top = csiParam(params, 0, 1);
        const bottom = csiParam(params, 1, self.height);
        const top0 = top - 1;
        const bottom0 = @min(bottom - 1, self.height - 1);
        if (top0 >= bottom0) {
            self.resetScrollRegion();
        } else {
            self.scroll_top = top0;
            self.scroll_bottom = bottom0;
        }
        // DECSTBM always homes the cursor to the origin (scroll_top when
        // DECOM is active, row 0 otherwise).
        self.cursorToOrigin();
    }

    fn applyCsi(self: *Grid, params: []const u8, final: u8) void {
        if (final != 'm') self.wrap_pending = false;
        switch (final) {
            '@' => self.insertCharacters(csiParam(params, 0, 1)),
            'A', 'B', 'C', 'D' => self.cursorMove(params, final),
            'L' => self.insertLines(csiParam(params, 0, 1)),
            'M' => self.deleteLines(csiParam(params, 0, 1)),
            'P' => self.deleteCharacters(csiParam(params, 0, 1)),
            'H', 'f' => self.cursorHome(params),
            'J' => self.clearScreen(csiParam(params, 0, 0)),
            'K' => self.clearLineByMode(csiParam(params, 0, 0)),
            'm' => self.applySgr(params),
            'h' => self.applyPrivateMode(params, true),
            'l' => self.applyPrivateMode(params, false),
            'g' => self.clearTabStop(params),
            'r' => self.setScrollRegion(params),
            's' => self.saveCursor(),
            'u' => self.restoreCursor(),
            else => {},
        }
    }

    fn applyPrivateMode(self: *Grid, params: []const u8, enabled: bool) void {
        if (params.len == 0 or params[0] != '?') return;

        var index: usize = 1;
        while (index <= params.len) {
            const start = index;
            while (index < params.len and params[index] != ';') : (index += 1) {}
            const part = params[start..index];
            index += 1;
            if (part.len == 0) continue;

            const mode = std.fmt.parseInt(usize, part, 10) catch continue;
            switch (mode) {
                1 => self.application_cursor = enabled,
                6 => {
                    // DECOM: enabling or disabling homes the cursor to the new origin.
                    self.origin_mode = enabled;
                    self.cursorToOrigin();
                },
                7 => self.auto_wrap = enabled,
                9 => self.setMouseTracking(if (enabled) .x10 else .disabled),
                47, 1047 => {
                    if (enabled) {
                        self.enterAlternateScreen(false);
                    } else {
                        self.exitAlternateScreen(false);
                    }
                },
                1000 => self.setMouseTracking(if (enabled) .normal else .disabled),
                1002 => self.setMouseTracking(if (enabled) .button_event else .disabled),
                1003 => self.setMouseTracking(if (enabled) .any_event else .disabled),
                1005 => self.mouse_encoding = if (enabled) .utf8 else .default,
                1006 => self.mouse_encoding = if (enabled) .sgr else .default,
                1015 => self.mouse_encoding = if (enabled) .urxvt else .default,
                1048 => {
                    if (enabled) {
                        self.saveCursor();
                    } else {
                        self.restoreCursor();
                    }
                },
                1049 => {
                    if (enabled) {
                        self.saveCursor();
                        self.enterAlternateScreen(true);
                    } else {
                        self.exitAlternateScreen(true);
                    }
                },
                2004 => self.bracketed_paste = enabled,
                else => {},
            }
        }
    }

    fn setMouseTracking(self: *Grid, mode: MouseTracking) void {
        self.mouse_tracking = mode;
        if (mode == .disabled) self.mouse_encoding = .default;
    }

    fn enterAlternateScreen(self: *Grid, clear: bool) void {
        if (!self.alternate_screen) {
            self.primary_state = self.activeState();
            self.alternate_screen = true;
            self.cells = self.alternate_cells;
            self.loadState(self.alternate_state);
        }
        if (clear) {
            self.clearCells(self.cells);
            self.cursor_x = 0;
            self.cursor_y = 0;
            self.wrap_pending = false;
        }
        self.resetScrollRegion();
    }

    fn exitAlternateScreen(self: *Grid, clear: bool) void {
        if (!self.alternate_screen) return;
        self.alternate_state = self.activeState();
        if (clear) self.clearCells(self.alternate_cells);
        self.alternate_screen = false;
        self.cells = self.primary_cells;
        self.loadState(self.primary_state);
        self.resetScrollRegion();
    }

    // ESC c (RIS): full reset to a fresh terminal state.
    fn hardReset(self: *Grid) void {
        self.current_style = .{};
        self.clearCells(self.primary_cells);
        self.clearCells(self.alternate_cells);
        self.clearHistory();
        self.cells = self.primary_cells;
        self.alternate_screen = false;
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.saved_cursor_x = 0;
        self.saved_cursor_y = 0;
        self.wrap_pending = false;
        self.primary_state = .{};
        self.alternate_state = .{};
        self.bracketed_paste = false;
        self.application_cursor = false;
        self.application_keypad = false;
        self.auto_wrap = true;
        self.origin_mode = false;
        self.mouse_tracking = .disabled;
        self.mouse_encoding = .default;
        self.resetScrollRegion();
        self.resetTabStops();
        self.resetParser();
    }

    fn activeState(self: *const Grid) BufferState {
        return .{
            .cursor_x = self.cursor_x,
            .cursor_y = self.cursor_y,
            .saved_cursor_x = self.saved_cursor_x,
            .saved_cursor_y = self.saved_cursor_y,
            .wrap_pending = self.wrap_pending,
        };
    }

    fn loadState(self: *Grid, state: BufferState) void {
        self.cursor_x = @min(state.cursor_x, self.width - 1);
        self.cursor_y = @min(state.cursor_y, self.height - 1);
        self.saved_cursor_x = @min(state.saved_cursor_x, self.width - 1);
        self.saved_cursor_y = @min(state.saved_cursor_y, self.height - 1);
        self.wrap_pending = state.wrap_pending;
    }

    // Home the cursor to the current origin: (scroll_top, 0) in DECOM, else (0, 0).
    fn cursorToOrigin(self: *Grid) void {
        self.cursor_x = 0;
        self.cursor_y = if (self.origin_mode) self.scroll_top else 0;
        self.wrap_pending = false;
    }

    fn cursorMove(self: *Grid, params: []const u8, final: u8) void {
        const count = csiParam(params, 0, 1);
        switch (final) {
            'A' => self.cursor_y = self.cursor_y -| count,
            'B' => self.cursor_y = @min(self.cursor_y +| count, self.height - 1),
            'C' => self.cursor_x = @min(self.cursor_x +| count, self.width - 1),
            'D' => self.cursor_x = self.cursor_x -| count,
            else => {},
        }
    }

    fn cursorHome(self: *Grid, params: []const u8) void {
        const row = csiParam(params, 0, 1);
        const col = csiParam(params, 1, 1);
        const row0 = if (row == 0) 0 else row - 1;
        const col0 = if (col == 0) 0 else col - 1;
        if (self.origin_mode) {
            // In DECOM, row is relative to scroll_top and constrained within
            // [scroll_top, scroll_bottom].
            self.cursor_y = @min(self.scroll_top + row0, self.scroll_bottom);
            self.cursor_x = @min(col0, self.width - 1);
        } else {
            self.cursor_y = @min(row0, self.height - 1);
            self.cursor_x = @min(col0, self.width - 1);
        }
    }

    fn saveCursor(self: *Grid) void {
        self.saved_cursor_x = self.cursor_x;
        self.saved_cursor_y = self.cursor_y;
    }

    fn restoreCursor(self: *Grid) void {
        self.cursor_x = @min(self.saved_cursor_x, self.width - 1);
        self.cursor_y = @min(self.saved_cursor_y, self.height - 1);
        self.wrap_pending = false;
    }

    fn tab(self: *Grid) void {
        if (self.wrap_pending) {
            self.cursor_x = 0;
            self.newline();
            self.wrap_pending = false;
        }
        // Find the next tab stop strictly after the current column.
        if (self.tab_stops != null) {
            var next = self.cursor_x + 1;
            while (next < self.width) : (next += 1) {
                if (self.hasTabStop(next)) {
                    self.cursor_x = next;
                    return;
                }
            }
            // No stop found: move to last column.
            self.cursor_x = self.width - 1;
        } else {
            // Default 8-column arithmetic.
            const next_stop = ((self.cursor_x / 8) + 1) * 8;
            self.cursor_x = @min(next_stop, self.width - 1);
        }
    }

    fn put(self: *Grid, byte: u8) void {
        self.putCodepoint(byte);
    }

    fn putCodepoint(self: *Grid, codepoint: u21) void {
        if (self.wrap_pending) {
            // DECAWM off: wrap_pending is never set, so this branch is only
            // reached when auto_wrap is on.
            self.cursor_x = 0;
            self.newline();
            self.wrap_pending = false;
        }

        var display_width = cellDisplayWidth(codepoint);
        if (display_width == 2 and self.width == 1) display_width = 1;
        if (display_width == 2 and self.cursor_x + 1 >= self.width) {
            if (self.auto_wrap) {
                self.cursor_x = 0;
                self.newline();
            } else {
                // No room for a wide char at the margin with auto-wrap off:
                // render it narrow at the last column.
                display_width = 1;
            }
        }

        const cell_index = self.cursor_y * self.width + self.cursor_x;
        self.clearWideAt(cell_index);
        if (display_width == 2) self.clearWideAt(cell_index + 1);

        self.cells[cell_index] = .{
            .ch = legacyCellByte(codepoint),
            .codepoint = codepoint,
            .width = if (display_width == 2) .wide else .narrow,
            .style = self.current_style,
        };
        if (display_width == 2) {
            self.cells[cell_index + 1] = .{
                .ch = ' ',
                .codepoint = ' ',
                .width = .continuation,
                .style = self.current_style,
            };
        }

        if (self.cursor_x + display_width >= self.width) {
            // Reached the right margin.
            if (self.auto_wrap) {
                self.cursor_x = self.width - 1;
                self.wrap_pending = true;
            } else {
                // With auto-wrap off the cursor stays at (or clamps to) the
                // last column so subsequent chars overwrite it.
                self.cursor_x = self.width - 1;
            }
        } else {
            self.cursor_x += display_width;
        }
    }

    fn clearWideAt(self: *Grid, cell_index: usize) void {
        if (cell_index >= self.cells.len) return;
        const blank = Cell{ .style = self.current_style };
        const col = cell_index % self.width;
        switch (self.cells[cell_index].width) {
            .wide => {
                self.cells[cell_index] = blank;
                if (col + 1 < self.width and cell_index + 1 < self.cells.len and self.cells[cell_index + 1].width == .continuation) {
                    self.cells[cell_index + 1] = blank;
                }
            },
            .continuation => {
                self.cells[cell_index] = blank;
                if (col > 0 and self.cells[cell_index - 1].width == .wide) {
                    self.cells[cell_index - 1] = blank;
                }
            },
            .narrow => {},
        }
    }

    fn insertCharacters(self: *Grid, requested_count: usize) void {
        const row_start = self.cursor_y * self.width;
        const count = @min(requested_count, self.width - self.cursor_x);
        if (count == 0) return;

        const src = self.cells[row_start + self.cursor_x .. row_start + self.width - count];
        const dst = self.cells[row_start + self.cursor_x + count .. row_start + self.width];
        std.mem.copyBackwards(Cell, dst, src);
        self.clearCells(self.cells[row_start + self.cursor_x .. row_start + self.cursor_x + count]);
    }

    fn deleteCharacters(self: *Grid, requested_count: usize) void {
        const row_start = self.cursor_y * self.width;
        const count = @min(requested_count, self.width - self.cursor_x);
        if (count == 0) return;

        const src = self.cells[row_start + self.cursor_x + count .. row_start + self.width];
        const dst = self.cells[row_start + self.cursor_x .. row_start + self.width - count];
        std.mem.copyForwards(Cell, dst, src);
        self.clearCells(self.cells[row_start + self.width - count .. row_start + self.width]);
    }

    fn insertLines(self: *Grid, requested_count: usize) void {
        if (self.cursor_y < self.scroll_top or self.cursor_y > self.scroll_bottom) return;
        const region_limit = self.scroll_bottom + 1;
        const count = @min(requested_count, region_limit - self.cursor_y);
        if (count == 0) return;

        const src = self.cells[self.cursor_y * self.width .. (region_limit - count) * self.width];
        const dst = self.cells[(self.cursor_y + count) * self.width .. region_limit * self.width];
        std.mem.copyBackwards(Cell, dst, src);

        var row = self.cursor_y;
        while (row < self.cursor_y + count) : (row += 1) {
            self.clearLine(row);
        }
    }

    fn deleteLines(self: *Grid, requested_count: usize) void {
        if (self.cursor_y < self.scroll_top or self.cursor_y > self.scroll_bottom) return;
        const region_limit = self.scroll_bottom + 1;
        const count = @min(requested_count, region_limit - self.cursor_y);
        if (count == 0) return;

        const src = self.cells[(self.cursor_y + count) * self.width .. region_limit * self.width];
        const dst = self.cells[self.cursor_y * self.width .. (region_limit - count) * self.width];
        std.mem.copyForwards(Cell, dst, src);

        var row = region_limit - count;
        while (row < region_limit) : (row += 1) {
            self.clearLine(row);
        }
    }

    fn newline(self: *Grid) void {
        self.cursor_x = 0;
        self.lineFeed();
    }

    // Vertical movement shared by LF, ESC D (IND), and ESC E (NEL): scroll the
    // region when at its bottom margin, otherwise step the cursor down.
    fn lineFeed(self: *Grid) void {
        if (self.cursor_y == self.scroll_bottom) {
            self.scrollRegionUp();
        } else if (self.cursor_y + 1 < self.height) {
            self.cursor_y += 1;
        }
    }

    // ESC M (Reverse Index): move up, scrolling the region down at the top.
    fn reverseIndex(self: *Grid) void {
        self.wrap_pending = false;
        if (self.cursor_y == self.scroll_top) {
            self.scrollRegionDown();
        } else if (self.cursor_y > 0) {
            self.cursor_y -= 1;
        }
    }

    fn scrollRegionUp(self: *Grid) void {
        // A full-screen region keeps the original scrollback-capturing path so
        // existing scroll/history behavior is unchanged.
        if (self.scroll_top == 0 and self.scroll_bottom == self.height - 1) {
            self.scrollUp();
            return;
        }
        const w = self.width;
        std.mem.copyForwards(
            Cell,
            self.cells[self.scroll_top * w .. self.scroll_bottom * w],
            self.cells[(self.scroll_top + 1) * w .. (self.scroll_bottom + 1) * w],
        );
        self.clearLine(self.scroll_bottom);
    }

    fn scrollRegionDown(self: *Grid) void {
        const w = self.width;
        std.mem.copyBackwards(
            Cell,
            self.cells[(self.scroll_top + 1) * w .. (self.scroll_bottom + 1) * w],
            self.cells[self.scroll_top * w .. self.scroll_bottom * w],
        );
        self.clearLine(self.scroll_top);
    }

    fn scrollUp(self: *Grid) void {
        if (self.height <= 1) {
            self.captureHistoryLine(0) catch {};
            self.clearLine(0);
            return;
        }
        self.captureHistoryLine(0) catch {};
        std.mem.copyForwards(Cell, self.cells[0 .. (self.height - 1) * self.width], self.cells[self.width..]);
        self.clearLine(self.height - 1);
    }

    fn clearScreen(self: *Grid, mode: usize) void {
        switch (mode) {
            0 => {
                const start = self.cursor_y * self.width + self.cursor_x;
                self.clearCells(self.cells[start..]);
            },
            1 => {
                const end = self.cursor_y * self.width + self.cursor_x + 1;
                self.clearCells(self.cells[0..end]);
            },
            2 => self.clearCells(self.cells),
            3 => self.clearHistory(),
            else => {},
        }
    }

    fn clearLineByMode(self: *Grid, mode: usize) void {
        const row_start = self.cursor_y * self.width;
        switch (mode) {
            0 => self.clearCells(self.cells[row_start + self.cursor_x .. row_start + self.width]),
            1 => self.clearCells(self.cells[row_start .. row_start + self.cursor_x + 1]),
            2 => self.clearCells(self.cells[row_start .. row_start + self.width]),
            else => {},
        }
    }

    fn clearLine(self: *Grid, row: usize) void {
        const start = row * self.width;
        self.clearCells(self.cells[start .. start + self.width]);
    }

    fn clearCells(self: *Grid, cells: []Cell) void {
        const blank = Cell{ .style = self.current_style };
        for (cells) |*cell| cell.* = blank;
    }

    fn captureHistoryLine(self: *Grid, row: usize) !void {
        if (self.alternate_screen) return;
        if (self.max_scrollback == 0) return;
        while (self.history.items.len >= self.max_scrollback) {
            const line = self.history.orderedRemove(0);
            self.allocator.free(line.cells);
        }

        const start = row * self.width;
        const cells = try self.allocator.alloc(Cell, self.width);
        @memcpy(cells, self.cells[start .. start + self.width]);
        errdefer self.allocator.free(cells);
        try self.history.append(self.allocator, .{
            .width = self.width,
            .cells = cells,
        });
    }

    fn trimHistory(self: *Grid) void {
        while (self.history.items.len > self.max_scrollback) {
            const line = self.history.orderedRemove(0);
            self.allocator.free(line.cells);
        }
    }

    fn clearHistory(self: *Grid) void {
        for (self.history.items) |line| {
            self.allocator.free(line.cells);
        }
        self.history.clearRetainingCapacity();
    }

    fn applySgr(self: *Grid, params: []const u8) void {
        if (params.len == 0) {
            self.current_style = .{};
            return;
        }

        var index: usize = 0;
        while (nextSgrParam(params, &index)) |code| {
            switch (code) {
                0 => self.current_style = .{},
                1 => self.current_style.bold = true,
                2 => self.current_style.dim = true,
                3 => self.current_style.italic = true,
                4 => {
                    self.current_style.underline = true;
                    self.current_style.double_underline = false;
                },
                5, 6 => self.current_style.blink = true,
                7 => self.current_style.inverse = true,
                8 => self.current_style.hidden = true,
                9 => self.current_style.strikethrough = true,
                21 => {
                    self.current_style.bold = false;
                    self.current_style.double_underline = true;
                    self.current_style.underline = true;
                },
                22 => {
                    self.current_style.bold = false;
                    self.current_style.dim = false;
                },
                23 => self.current_style.italic = false,
                24 => {
                    self.current_style.underline = false;
                    self.current_style.double_underline = false;
                },
                25 => self.current_style.blink = false,
                27 => self.current_style.inverse = false,
                28 => self.current_style.hidden = false,
                29 => self.current_style.strikethrough = false,
                30...37 => self.setForeground(.{ .named = sgrColor(code - 30, false) }),
                38 => self.applyExtendedSgrColor(params, &index, true),
                39 => self.resetForeground(),
                40...47 => self.setBackground(.{ .named = sgrColor(code - 40, false) }),
                48 => self.applyExtendedSgrColor(params, &index, false),
                49 => self.resetBackground(),
                53 => self.current_style.overline = true,
                55 => self.current_style.overline = false,
                58 => self.current_style.underline_color = parseExtendedSgrColor(params, &index),
                59 => self.current_style.underline_color = null,
                90...97 => self.setForeground(.{ .named = sgrColor(code - 90, true) }),
                100...107 => self.setBackground(.{ .named = sgrColor(code - 100, true) }),
                else => {},
            }
        }
    }

    fn setForeground(self: *Grid, color: ExtendedColor) void {
        self.current_style.fg_extended = extendedOverride(color);
        self.current_style.fg = legacyColor(color);
    }

    fn resetForeground(self: *Grid) void {
        self.current_style.fg = .default;
        self.current_style.fg_extended = null;
    }

    fn setBackground(self: *Grid, color: ExtendedColor) void {
        self.current_style.bg_extended = extendedOverride(color);
        self.current_style.bg = legacyColor(color);
    }

    fn resetBackground(self: *Grid) void {
        self.current_style.bg = .default;
        self.current_style.bg_extended = null;
    }

    fn applyExtendedSgrColor(self: *Grid, params: []const u8, index: *usize, foreground: bool) void {
        const color = parseExtendedSgrColor(params, index) orelse return;
        if (foreground) {
            self.setForeground(color);
        } else {
            self.setBackground(color);
        }
    }
};

fn copyResizedCells(
    new_cells: []Cell,
    new_width: usize,
    old_cells: []const Cell,
    old_width: usize,
    copy_width: usize,
    copy_height: usize,
) void {
    var row: usize = 0;
    while (row < copy_height) : (row += 1) {
        const old_start = row * old_width;
        const new_start = row * new_width;
        @memcpy(new_cells[new_start .. new_start + copy_width], old_cells[old_start .. old_start + copy_width]);
    }
}

fn clampBufferState(state: *BufferState, width: usize, height: usize) void {
    state.cursor_x = @min(state.cursor_x, width - 1);
    state.cursor_y = @min(state.cursor_y, height - 1);
    state.saved_cursor_x = @min(state.saved_cursor_x, width - 1);
    state.saved_cursor_y = @min(state.saved_cursor_y, height - 1);
    state.wrap_pending = false;
}

fn sgrColor(index: u16, bright: bool) Color {
    return if (bright) switch (index) {
        0 => .bright_black,
        1 => .bright_red,
        2 => .bright_green,
        3 => .bright_yellow,
        4 => .bright_blue,
        5 => .bright_magenta,
        6 => .bright_cyan,
        else => .bright_white,
    } else switch (index) {
        0 => .black,
        1 => .red,
        2 => .green,
        3 => .yellow,
        4 => .blue,
        5 => .magenta,
        6 => .cyan,
        else => .white,
    };
}

fn legacyColor(color: ExtendedColor) Color {
    return switch (color) {
        .named => |named| named,
        .indexed => |index| indexedAnsiFallback(index),
        .rgb => .default,
    };
}

fn extendedOverride(color: ExtendedColor) ?ExtendedColor {
    return switch (color) {
        .named => null,
        .indexed, .rgb => color,
    };
}

fn indexedAnsiFallback(index: u8) Color {
    return switch (index) {
        0 => .black,
        1 => .red,
        2 => .green,
        3 => .yellow,
        4 => .blue,
        5 => .magenta,
        6 => .cyan,
        7 => .white,
        8 => .bright_black,
        9 => .bright_red,
        10 => .bright_green,
        11 => .bright_yellow,
        12 => .bright_blue,
        13 => .bright_magenta,
        14 => .bright_cyan,
        15 => .bright_white,
        else => .default,
    };
}

fn parseExtendedSgrColor(params: []const u8, index: *usize) ?ExtendedColor {
    const mode = nextSgrParam(params, index) orelse return null;
    switch (mode) {
        5 => {
            const color_index = nextSgrParam(params, index) orelse return null;
            if (color_index > 255) return null;
            return .{ .indexed = @intCast(color_index) };
        },
        2 => {
            const r = nextSgrByte(params, index) orelse return null;
            const g = nextSgrByte(params, index) orelse return null;
            const b = nextSgrByte(params, index) orelse return null;
            return .{ .rgb = .{ .r = r, .g = g, .b = b } };
        },
        else => return null,
    }
}

fn nextSgrByte(params: []const u8, index: *usize) ?u8 {
    const value = nextSgrParam(params, index) orelse return null;
    if (value > 255) return null;
    return @intCast(value);
}

fn nextSgrParam(params: []const u8, index: *usize) ?u16 {
    if (index.* > params.len) return null;

    const start = index.*;
    if (start == params.len) {
        index.* = params.len + 1;
        return 0;
    }

    var end = start;
    while (end < params.len and params[end] != ';') : (end += 1) {}
    index.* = if (end < params.len) end + 1 else params.len + 1;
    if (end == start) return 0;
    return std.fmt.parseInt(u16, params[start..end], 10) catch 0;
}

const replacement_codepoint: u21 = 0xfffd;

const DecodedScalar = struct {
    codepoint: u21,
    len: usize,
};

// Expected total byte length for a UTF-8 lead byte, or 0 if it cannot start a
// sequence. Mirrors the lead-byte ranges decodeUtf8Scalar accepts so the
// incremental parser and the slice decoder agree.
fn utf8SequenceLen(lead: u8) usize {
    if (lead >= 0xc2 and lead <= 0xdf) return 2;
    if (lead >= 0xe0 and lead <= 0xef) return 3;
    if (lead >= 0xf0 and lead <= 0xf4) return 4;
    return 0;
}

fn decodeUtf8Scalar(bytes: []const u8) DecodedScalar {
    if (bytes.len == 0) return .{ .codepoint = replacement_codepoint, .len = 0 };

    const first = bytes[0];
    if (first < 0x80) return .{ .codepoint = first, .len = 1 };

    const needed: usize = if (first >= 0xc2 and first <= 0xdf)
        2
    else if (first >= 0xe0 and first <= 0xef)
        3
    else if (first >= 0xf0 and first <= 0xf4)
        4
    else
        return .{ .codepoint = replacement_codepoint, .len = 1 };

    if (bytes.len < needed) return .{ .codepoint = replacement_codepoint, .len = 1 };

    var codepoint: u21 = first & switch (needed) {
        2 => @as(u8, 0x1f),
        3 => @as(u8, 0x0f),
        4 => @as(u8, 0x07),
        else => unreachable,
    };
    var index: usize = 1;
    while (index < needed) : (index += 1) {
        const byte = bytes[index];
        if (byte < 0x80 or byte > 0xbf) {
            return .{ .codepoint = replacement_codepoint, .len = 1 };
        }
        codepoint = (codepoint << 6) | @as(u21, byte & 0x3f);
    }

    if (!isValidScalarForUtf8(codepoint, needed)) {
        return .{ .codepoint = replacement_codepoint, .len = 1 };
    }
    return .{ .codepoint = codepoint, .len = needed };
}

fn isValidScalarForUtf8(codepoint: u21, len: usize) bool {
    if (codepoint > 0x10ffff) return false;
    if (codepoint >= 0xd800 and codepoint <= 0xdfff) return false;
    return switch (len) {
        2 => codepoint >= 0x80,
        3 => codepoint >= 0x800,
        4 => codepoint >= 0x10000,
        else => codepoint < 0x80,
    };
}

fn legacyCellByte(codepoint: u21) u8 {
    if (codepoint >= 0x20 and codepoint <= 0x7e) return @intCast(codepoint);
    return '?';
}

fn cellDisplayWidth(codepoint: u21) usize {
    return if (isWideCodepoint(codepoint)) 2 else 1;
}

fn isWideCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x1100 and codepoint <= 0x115f) or
        (codepoint >= 0x2329 and codepoint <= 0x232a) or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x1f300 and codepoint <= 0x1faff) or
        (codepoint >= 0x20000 and codepoint <= 0x3fffd);
}

fn trimmedCellLen(cells: []const Cell) usize {
    var len = cells.len;
    while (len > 0 and cells[len - 1].codepoint == ' ') : (len -= 1) {}
    return len;
}

pub fn cellUtf8Len(cell: Cell) usize {
    if (cell.width == .continuation) return 0;
    const codepoint = cell.codepoint;
    if (codepoint < 0x80) return 1;
    if (codepoint < 0x800) return 2;
    if (codepoint < 0x10000) return 3;
    return 4;
}

pub fn encodeCellUtf8(cell: Cell, out: []u8) ![]u8 {
    const len = cellUtf8Len(cell);
    if (out.len < len) return error.NoSpaceLeft;
    _ = encodeCellUtf8Into(cell, out);
    return out[0..len];
}

pub fn cellsTextLen(cells: []const Cell) usize {
    var len: usize = 0;
    for (cells) |cell| len += cellUtf8Len(cell);
    return len;
}

pub fn cellsTextAlloc(allocator: Allocator, cells: []const Cell) ![]u8 {
    const trimmed_len = trimmedCellLen(cells);
    const text = try allocator.alloc(u8, cellsTextLen(cells[0..trimmed_len]));
    _ = encodeCellsText(cells[0..trimmed_len], text);
    return text;
}

fn encodeCellsText(cells: []const Cell, out: []u8) usize {
    var written: usize = 0;
    for (cells) |cell| {
        written += encodeCellUtf8Into(cell, out[written..]);
    }
    return written;
}

fn encodeCellUtf8Into(cell: Cell, out: []u8) usize {
    if (cell.width == .continuation) return 0;
    const codepoint = cell.codepoint;
    if (codepoint < 0x80) {
        out[0] = @intCast(codepoint);
        return 1;
    }
    if (codepoint < 0x800) {
        out[0] = @intCast(0xc0 | (codepoint >> 6));
        out[1] = @intCast(0x80 | (codepoint & 0x3f));
        return 2;
    }
    if (codepoint < 0x10000) {
        out[0] = @intCast(0xe0 | (codepoint >> 12));
        out[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
        out[2] = @intCast(0x80 | (codepoint & 0x3f));
        return 3;
    }
    out[0] = @intCast(0xf0 | (codepoint >> 18));
    out[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3f));
    out[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
    out[3] = @intCast(0x80 | (codepoint & 0x3f));
    return 4;
}

fn csiParam(params: []const u8, target_index: usize, default_value: usize) usize {
    var split = std.mem.splitScalar(u8, params, ';');
    var index: usize = 0;
    while (split.next()) |part| : (index += 1) {
        if (index != target_index) continue;
        if (part.len == 0) return default_value;
        const parsed = std.fmt.parseInt(usize, part, 10) catch return default_value;
        return if (parsed == 0) default_value else parsed;
    }
    return default_value;
}

test "writes printable bytes to the grid" {
    var grid = try Grid.init(std.testing.allocator, 8, 2);
    defer grid.deinit();
    grid.feed("hello");

    const line = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("hello   ", line);
}

test "decodes UTF-8 text into cell scalars" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("caf\xc3\xa9");

    try std.testing.expectEqual(@as(u21, 0x00e9), grid.cells[3].codepoint);
    try std.testing.expectEqual(@as(u8, '?'), grid.cells[3].ch);

    const line = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("caf\xc3\xa9", line);
}

test "replaces invalid UTF-8 bytes" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("a\xc0\xafz");

    try std.testing.expectEqual(@as(u21, replacement_codepoint), grid.cells[1].codepoint);
    try std.testing.expectEqual(@as(u21, replacement_codepoint), grid.cells[2].codepoint);

    const line = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("a\xef\xbf\xbd\xef\xbf\xbdz", line);
}

test "tracks wide UTF-8 cell continuations" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("A\xe4\xb8\xadB");

    try std.testing.expectEqual(@as(u21, 0x4e2d), grid.cells[1].codepoint);
    try std.testing.expectEqual(CellWidth.wide, grid.cells[1].width);
    try std.testing.expectEqual(CellWidth.continuation, grid.cells[2].width);
    try std.testing.expect(grid.cells[2].isContinuation());
    try std.testing.expectEqual(@as(usize, 4), grid.cursor_x);

    const line = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("A\xe4\xb8\xadB", line);
}

test "handles carriage return and clear line" {
    var grid = try Grid.init(std.testing.allocator, 8, 2);
    defer grid.deinit();
    grid.feed("hello\rhe\x1b[K");

    const line = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("he      ", line);
}

test "supports clear line variants" {
    var grid = try Grid.init(std.testing.allocator, 8, 3);
    defer grid.deinit();

    grid.feed("abcdefgh\x1b[1;4H\x1b[0K");
    const line0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line0);
    try std.testing.expectEqualStrings("abc     ", line0);

    grid.feed("\x1b[2;1Habcdefgh\x1b[2;4H\x1b[1K");
    const line1 = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(line1);
    try std.testing.expectEqualStrings("    efgh", line1);

    grid.feed("\x1b[3;1Habcdefgh\x1b[3;4H\x1b[2K");
    const line2 = try grid.lineAlloc(std.testing.allocator, 2);
    defer std.testing.allocator.free(line2);
    try std.testing.expectEqualStrings("        ", line2);
}

test "supports clear screen variants without moving cursor" {
    var grid = try Grid.init(std.testing.allocator, 4, 3);
    defer grid.deinit();

    grid.feed("abcd\nefgh\nijkl\x1b[2;3H\x1b[0J");
    try std.testing.expectEqual(@as(usize, 2), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 1), grid.cursor_y);

    const before0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(before0);
    try std.testing.expectEqualStrings("abcd", before0);
    const before1 = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(before1);
    try std.testing.expectEqualStrings("ef  ", before1);
    const before2 = try grid.lineAlloc(std.testing.allocator, 2);
    defer std.testing.allocator.free(before2);
    try std.testing.expectEqualStrings("    ", before2);

    grid.feed("\x1b[2J");
    try std.testing.expectEqual(@as(usize, 2), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 1), grid.cursor_y);
    const after0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(after0);
    try std.testing.expectEqualStrings("    ", after0);
    const after1 = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(after1);
    try std.testing.expectEqualStrings("    ", after1);
    const after2 = try grid.lineAlloc(std.testing.allocator, 2);
    defer std.testing.allocator.free(after2);
    try std.testing.expectEqualStrings("    ", after2);
}

test "clear scrollback variant drops history without clearing visible cells" {
    var grid = try Grid.initWithMaxScrollback(std.testing.allocator, 4, 2, 4);
    defer grid.deinit();
    grid.feed("one\ntwo\ntri");

    try std.testing.expectEqual(@as(usize, 1), grid.historyLen());
    grid.feed("\x1b[3J");

    try std.testing.expectEqual(@as(usize, 0), grid.historyLen());
    const first = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(first);
    const second = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("two ", first);
    try std.testing.expectEqualStrings("tri ", second);
}

test "scrolls when writing past the bottom" {
    var grid = try Grid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();
    grid.feed("one\ntwo\ntri");

    const first = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(first);
    const second = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("two ", first);
    try std.testing.expectEqualStrings("tri ", second);
}

test "cursor movement clamps to grid bounds" {
    var grid = try Grid.init(std.testing.allocator, 5, 3);
    defer grid.deinit();

    grid.feed("\x1b[99;99HZ");
    try std.testing.expectEqual(@as(usize, 4), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 2), grid.cursor_y);
    try std.testing.expectEqual(@as(u8, 'Z'), grid.cells[2 * grid.width + 4].ch);

    grid.feed("\x1b[999D\x1b[999AX");
    try std.testing.expectEqual(@as(usize, 1), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 0), grid.cursor_y);
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[0].ch);

    grid.feed("\x1b[0C\x1b[0BY");
    try std.testing.expectEqual(@as(usize, 3), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 1), grid.cursor_y);
    try std.testing.expectEqual(@as(u8, 'Y'), grid.cells[1 * grid.width + 2].ch);
}

test "tabs move to simple eight-column stops" {
    var grid = try Grid.init(std.testing.allocator, 12, 2);
    defer grid.deinit();
    grid.feed("a\tb");

    const line = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("a       b   ", line);
    try std.testing.expectEqual(@as(usize, 9), grid.cursor_x);
}

test "tab honors deferred wrap at the line edge" {
    var grid = try Grid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();
    grid.feed("abcd\tZ");

    const line0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line0);
    try std.testing.expectEqualStrings("abcd", line0);
    const line1 = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(line1);
    try std.testing.expectEqualStrings("   Z", line1);
}

test "resizes while preserving visible cells" {
    var grid = try Grid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();
    grid.feed("abc\nef");
    try grid.resize(6, 3);

    const first = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(first);
    const second = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("abc   ", first);
    try std.testing.expectEqualStrings("ef    ", second);
}

test "resize preserves existing cell styles" {
    var grid = try Grid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();
    grid.feed("\x1b[31mab\n\x1b[44mcd");
    try grid.resize(6, 3);

    try std.testing.expectEqual(Color.red, grid.cells[0].style.fg);
    try std.testing.expectEqual(Color.red, grid.cells[1].style.fg);
    try std.testing.expectEqual(Color.blue, grid.cells[6].style.bg);
    try std.testing.expectEqual(Color.blue, grid.cells[7].style.bg);
}

test "scroll preserves visible and history cell styles" {
    var grid = try Grid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();
    grid.feed("\x1b[31mred\n\x1b[44mblu\nend");

    try std.testing.expectEqual(@as(usize, 1), grid.historyLen());
    try std.testing.expectEqual(Color.red, grid.history.items[0].cells[0].style.fg);
    try std.testing.expectEqual(Color.blue, grid.cells[0].style.bg);
}

test "applies SGR foreground background and intensity to new cells" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("\x1b[1;2;31;104mA\x1b[22;92mB\x1b[0mC");

    try std.testing.expect(grid.cells[0].style.bold);
    try std.testing.expect(grid.cells[0].style.dim);
    try std.testing.expectEqual(Color.red, grid.cells[0].style.fg);
    try std.testing.expectEqual(Color.bright_blue, grid.cells[0].style.bg);
    try std.testing.expect(!grid.cells[1].style.bold);
    try std.testing.expect(!grid.cells[1].style.dim);
    try std.testing.expectEqual(Color.bright_green, grid.cells[1].style.fg);
    try std.testing.expectEqual(Color.bright_blue, grid.cells[1].style.bg);
    try std.testing.expectEqual(Style{}, grid.cells[2].style);
}

test "applies richer SGR attributes and targeted resets" {
    var grid = try Grid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();
    grid.feed("\x1b[3;4;5;7;8;9;53mA\x1b[23;24;25;27;28;29;55mB");

    try std.testing.expect(grid.cells[0].style.italic);
    try std.testing.expect(grid.cells[0].style.underline);
    try std.testing.expect(grid.cells[0].style.blink);
    try std.testing.expect(grid.cells[0].style.inverse);
    try std.testing.expect(grid.cells[0].style.hidden);
    try std.testing.expect(grid.cells[0].style.strikethrough);
    try std.testing.expect(grid.cells[0].style.overline);

    try std.testing.expect(!grid.cells[1].style.italic);
    try std.testing.expect(!grid.cells[1].style.underline);
    try std.testing.expect(!grid.cells[1].style.blink);
    try std.testing.expect(!grid.cells[1].style.inverse);
    try std.testing.expect(!grid.cells[1].style.hidden);
    try std.testing.expect(!grid.cells[1].style.strikethrough);
    try std.testing.expect(!grid.cells[1].style.overline);
}

test "applies indexed RGB and underline SGR colors" {
    var grid = try Grid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();
    grid.feed("\x1b[38;5;196;48;2;1;2;3;58;5;45mA\x1b[39;49;59mB");

    try std.testing.expectEqual(ExtendedColor{ .indexed = 196 }, grid.cells[0].style.foreground());
    try std.testing.expectEqual(Color.default, grid.cells[0].style.fg);
    try std.testing.expectEqual(ExtendedColor{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, grid.cells[0].style.background());
    try std.testing.expectEqual(ExtendedColor{ .indexed = 45 }, grid.cells[0].style.underline_color.?);
    try std.testing.expectEqual(ExtendedColor{ .named = .default }, grid.cells[1].style.foreground());
    try std.testing.expectEqual(ExtendedColor{ .named = .default }, grid.cells[1].style.background());
    try std.testing.expectEqual(@as(?ExtendedColor, null), grid.cells[1].style.underline_color);
}

test "SGR does not cancel deferred wrap" {
    var grid = try Grid.init(std.testing.allocator, 3, 2);
    defer grid.deinit();
    grid.feed("\x1b[31mabc\x1b[32mD");

    const line0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line0);
    try std.testing.expectEqualStrings("abc", line0);
    const line1 = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(line1);
    try std.testing.expectEqualStrings("D  ", line1);
    try std.testing.expectEqual(Color.green, grid.cells[3].style.fg);
}

test "cursor movement cancels deferred wrap and edits current line" {
    var grid = try Grid.init(std.testing.allocator, 3, 2);
    defer grid.deinit();
    grid.feed("abc\x1b[DX");

    const line = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("aXc", line);
    try std.testing.expectEqual(@as(usize, 2), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 0), grid.cursor_y);
}

test "empty and explicit SGR reset restore default style" {
    var grid = try Grid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();
    grid.feed("\x1b[31mA\x1b[mB\x1b[44mC\x1b[0mD");

    try std.testing.expectEqual(Color.red, grid.cells[0].style.fg);
    try std.testing.expectEqual(Style{}, grid.cells[1].style);
    try std.testing.expectEqual(Color.blue, grid.cells[2].style.bg);
    try std.testing.expectEqual(Style{}, grid.cells[3].style);
}

test "tracks alternate screen buffer and restores primary contents" {
    var grid = try Grid.init(std.testing.allocator, 6, 2);
    defer grid.deinit();
    grid.feed("main\x1b[?1049halt\x1b[2;4HZ");

    try std.testing.expect(grid.isAlternateScreen());
    const alt0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(alt0);
    const alt1 = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(alt1);
    try std.testing.expectEqualStrings("alt   ", alt0);
    try std.testing.expectEqualStrings("   Z  ", alt1);

    grid.feed("\x1b[?1049l!");
    try std.testing.expect(!grid.isAlternateScreen());
    const primary = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(primary);
    try std.testing.expectEqualStrings("main! ", primary);
    try std.testing.expectEqual(@as(usize, 5), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 0), grid.cursor_y);
}

test "alternate screen scrolls without appending primary scrollback" {
    var grid = try Grid.initWithMaxScrollback(std.testing.allocator, 3, 1, 8);
    defer grid.deinit();
    grid.feed("one\ntwo");
    try std.testing.expectEqual(@as(usize, 1), grid.historyLen());

    grid.feed("\x1b[?1049habc\ndef\nghi\x1b[?1049l");
    try std.testing.expectEqual(@as(usize, 1), grid.historyLen());
}

test "tracks bracketed paste application cursor and mouse private modes" {
    var grid = try Grid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();
    grid.feed("\x1b[?1;2004;1002;1006h");

    try std.testing.expect(grid.isApplicationCursorEnabled());
    try std.testing.expect(grid.isBracketedPasteEnabled());
    try std.testing.expectEqual(MouseTracking.button_event, grid.mouseTrackingMode());
    try std.testing.expectEqual(MouseEncoding.sgr, grid.mouseEncodingMode());

    grid.feed("\x1b[?1002l\x1b[?1;2004l");
    try std.testing.expect(!grid.isApplicationCursorEnabled());
    try std.testing.expect(!grid.isBracketedPasteEnabled());
    try std.testing.expectEqual(MouseTracking.disabled, grid.mouseTrackingMode());
    try std.testing.expectEqual(MouseEncoding.default, grid.mouseEncodingMode());
}

test "captures scrolled lines in history with cell styles" {
    var grid = try Grid.init(std.testing.allocator, 5, 2);
    defer grid.deinit();
    grid.feed("\x1b[31mred\n\x1b[0mnext\nlast");

    try std.testing.expectEqual(@as(usize, 1), grid.historyLen());
    const history = try grid.historyLineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(history);
    try std.testing.expectEqualStrings("red", history);
    try std.testing.expectEqual(Color.red, grid.history.items[0].cells[0].style.fg);
}

test "scrollback is capped and keeps newest history lines" {
    var grid = try Grid.initWithMaxScrollback(std.testing.allocator, 8, 1, 3);
    defer grid.deinit();
    grid.feed("one\ntwo\nthree\nfour\nfive");

    try std.testing.expectEqual(@as(usize, 3), grid.historyLen());
    const first = try grid.historyLineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(first);
    const second = try grid.historyLineTextAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(second);
    const third = try grid.historyLineTextAlloc(std.testing.allocator, 2);
    defer std.testing.allocator.free(third);
    try std.testing.expectEqualStrings("two", first);
    try std.testing.expectEqualStrings("three", second);
    try std.testing.expectEqualStrings("four", third);
}

test "scrollback cap can shrink and disable history" {
    var grid = try Grid.initWithMaxScrollback(std.testing.allocator, 8, 1, 4);
    defer grid.deinit();
    grid.feed("one\ntwo\nthree\nfour");

    grid.setMaxScrollback(2);
    try std.testing.expectEqual(@as(usize, 2), grid.historyLen());
    const first = try grid.historyLineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(first);
    const second = try grid.historyLineTextAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("two", first);
    try std.testing.expectEqualStrings("three", second);

    grid.setMaxScrollback(0);
    try std.testing.expectEqual(@as(usize, 0), grid.historyLen());
    grid.feed("\nfive");
    try std.testing.expectEqual(@as(usize, 0), grid.historyLen());
}

test "extracts trimmed visible lines and selections" {
    var grid = try Grid.init(std.testing.allocator, 6, 3);
    defer grid.deinit();
    grid.feed("hello\nworld!");

    const first = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("hello", first);

    const visible = try grid.visibleTextAlloc(std.testing.allocator);
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualStrings("hello\nworld!\n", visible);

    const selected = try grid.selectionAlloc(std.testing.allocator, 0, 1, 1, 3);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("ello \nwor", selected);
}

test "saves and restores cursor with CSI and ESC variants" {
    var grid = try Grid.init(std.testing.allocator, 8, 2);
    defer grid.deinit();
    grid.feed("abc\x1b[sde\x1b[uX");

    const csi_line = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(csi_line);
    try std.testing.expectEqualStrings("abcXe   ", csi_line);
    try std.testing.expectEqual(@as(usize, 4), grid.cursor_x);

    grid.feed("\x1b[2;1H12\x1b" ++ "734\x1b" ++ "8Y");
    const esc_line = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(esc_line);
    try std.testing.expectEqualStrings("12Y4    ", esc_line);
    try std.testing.expectEqual(@as(usize, 3), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 1), grid.cursor_y);
}

test "inserts and deletes characters on the current line" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("abcdef\x1b[1;3H\x1b[2@XY\x1b[1;5H\x1b[2P");

    const line = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("abXYef  ", line);
    try std.testing.expectEqual(@as(usize, 4), grid.cursor_x);
}

test "inserts and deletes lines below the cursor" {
    var grid = try Grid.init(std.testing.allocator, 4, 4);
    defer grid.deinit();
    grid.feed("aaaa\nbbbb\ncccc\ndddd");

    grid.feed("\x1b[2;1H\x1b[L");
    const inserted0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(inserted0);
    const inserted1 = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(inserted1);
    const inserted2 = try grid.lineAlloc(std.testing.allocator, 2);
    defer std.testing.allocator.free(inserted2);
    const inserted3 = try grid.lineAlloc(std.testing.allocator, 3);
    defer std.testing.allocator.free(inserted3);
    try std.testing.expectEqualStrings("aaaa", inserted0);
    try std.testing.expectEqualStrings("    ", inserted1);
    try std.testing.expectEqualStrings("bbbb", inserted2);
    try std.testing.expectEqualStrings("cccc", inserted3);

    grid.feed("\x1b[2;1H\x1b[M");
    const deleted0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(deleted0);
    const deleted1 = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(deleted1);
    const deleted2 = try grid.lineAlloc(std.testing.allocator, 2);
    defer std.testing.allocator.free(deleted2);
    const deleted3 = try grid.lineAlloc(std.testing.allocator, 3);
    defer std.testing.allocator.free(deleted3);
    try std.testing.expectEqualStrings("aaaa", deleted0);
    try std.testing.expectEqualStrings("bbbb", deleted1);
    try std.testing.expectEqualStrings("cccc", deleted2);
    try std.testing.expectEqualStrings("    ", deleted3);
}

// --- VT conformance: resumable parser, OSC, scroll regions, ESC controls ---

fn feedWholeFingerprint(input: []const u8, out_cursor: *[2]usize) ![]u8 {
    var grid = try Grid.init(std.testing.allocator, 16, 4);
    defer grid.deinit();
    grid.feed(input);
    out_cursor.* = .{ grid.cursor_x, grid.cursor_y };
    return grid.visibleTextAlloc(std.testing.allocator);
}

// Feeding a byte stream split at any boundary must produce the same screen as
// feeding it whole. This is the discriminating check for cross-feed() parser
// state: the old stateless parser printed the tail of a split escape as text.
fn expectSplitInvariant(input: []const u8) !void {
    var ref_cursor: [2]usize = undefined;
    const reference = try feedWholeFingerprint(input, &ref_cursor);
    defer std.testing.allocator.free(reference);

    var split: usize = 1;
    while (split < input.len) : (split += 1) {
        var grid = try Grid.init(std.testing.allocator, 16, 4);
        defer grid.deinit();
        grid.feed(input[0..split]);
        grid.feed(input[split..]);
        const got = try grid.visibleTextAlloc(std.testing.allocator);
        defer std.testing.allocator.free(got);
        std.testing.expectEqualStrings(reference, got) catch |err| {
            std.debug.print("split-invariance failed at boundary {d}\n", .{split});
            return err;
        };
        try std.testing.expectEqual(ref_cursor[0], grid.cursor_x);
        try std.testing.expectEqual(ref_cursor[1], grid.cursor_y);
    }
}

test "escape sequences split across feed calls are not corrupted" {
    try expectSplitInvariant("a\x1b[31mbc\x1b[2;3Hd\xc3\xa9\x1b]0;title\x07Z\x1b[m!");
    try expectSplitInvariant("\x1b[1;1Hhi\x1b[Kthere\x1b[2Jdone\x1b[?1049h\x1b[Halt");
    try expectSplitInvariant("plain text with no escapes at all");
}

test "split CSI does not print its tail as literal text" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("\x1b[3");
    grid.feed("1mX");

    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[0].ch);
    try std.testing.expectEqual(Color.red, grid.cells[0].style.fg);

    const line = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("X", line);
}

test "split multi-byte UTF-8 scalar resumes across feed calls" {
    var grid = try Grid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();
    grid.feed("A");
    grid.feed("\xc3");
    grid.feed("\xa9");
    grid.feed("B");

    try std.testing.expectEqual(@as(u21, 'A'), grid.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 0x00e9), grid.cells[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cells[2].codepoint);
}

test "OSC title and hyperlink sequences never reach the grid" {
    var grid = try Grid.init(std.testing.allocator, 16, 2);
    defer grid.deinit();
    grid.feed("\x1b]0;my window title\x07AB");
    grid.feed("\x1b]8;;https://example.com\x1b\\CD");

    const line = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("ABCD", line);
}

test "OSC split across feed calls is still consumed" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("\x1b]0;ti");
    grid.feed("tle\x07X");

    const line = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("X", line);
}

test "overlong CSI overflows, is ignored, and the parser resyncs" {
    var grid = try Grid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();
    grid.feed("\x1b[" ++ ("9" ** 400) ++ "m\x1b[31mZ");

    try std.testing.expectEqual(@as(u8, 'Z'), grid.cells[0].ch);
    try std.testing.expectEqual(Color.red, grid.cells[0].style.fg);

    const line = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("Z", line);
}

test "DECSTBM scrolls only within the region and homes the cursor" {
    var grid = try Grid.init(std.testing.allocator, 3, 5);
    defer grid.deinit();
    grid.feed("AAA\nBBB\nCCC\nDDD\nEEE");
    grid.feed("\x1b[2;4r");

    try std.testing.expectEqual(@as(usize, 0), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 0), grid.cursor_y);

    grid.feed("\x1b[4;1H\nXXX");

    const row0 = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(row0);
    const row1 = try grid.lineTextAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(row1);
    const row2 = try grid.lineTextAlloc(std.testing.allocator, 2);
    defer std.testing.allocator.free(row2);
    const row3 = try grid.lineTextAlloc(std.testing.allocator, 3);
    defer std.testing.allocator.free(row3);
    const row4 = try grid.lineTextAlloc(std.testing.allocator, 4);
    defer std.testing.allocator.free(row4);

    try std.testing.expectEqualStrings("AAA", row0);
    try std.testing.expectEqualStrings("CCC", row1);
    try std.testing.expectEqualStrings("DDD", row2);
    try std.testing.expectEqualStrings("XXX", row3);
    try std.testing.expectEqualStrings("EEE", row4);
}

test "ESC M reverse index scrolls the region down at the top" {
    var grid = try Grid.init(std.testing.allocator, 3, 3);
    defer grid.deinit();
    grid.feed("AAA\nBBB\nCCC");
    grid.feed("\x1b[1;1H\x1bM");

    const row0 = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(row0);
    const row1 = try grid.lineTextAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(row1);
    const row2 = try grid.lineTextAlloc(std.testing.allocator, 2);
    defer std.testing.allocator.free(row2);

    try std.testing.expectEqualStrings("", row0);
    try std.testing.expectEqualStrings("AAA", row1);
    try std.testing.expectEqualStrings("BBB", row2);
}

test "ESC D index keeps the column, ESC E next line returns to column zero" {
    var grid = try Grid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();
    grid.feed("ab\x1bDZ");

    try std.testing.expectEqual(@as(u21, 'Z'), grid.cells[1 * grid.width + 2].codepoint);
    try std.testing.expectEqual(@as(usize, 1), grid.cursor_y);

    var nel = try Grid.init(std.testing.allocator, 4, 2);
    defer nel.deinit();
    nel.feed("ab\x1bEZ");

    const row1 = try nel.lineTextAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(row1);
    try std.testing.expectEqualStrings("Z", row1);
}

test "ESC c performs a full reset" {
    var grid = try Grid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();
    grid.feed("\x1b[31mABCD\nEF\x1b[2;4r\x1bc");

    try std.testing.expectEqual(@as(usize, 0), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 0), grid.cursor_y);
    try std.testing.expectEqual(@as(usize, 0), grid.scroll_top);
    try std.testing.expectEqual(@as(usize, 1), grid.scroll_bottom);
    try std.testing.expectEqual(Style{}, grid.current_style);

    const visible = try grid.visibleTextAlloc(std.testing.allocator);
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualStrings("\n", visible);
}

// --- New feature tests ---

// Item 5: ESC = / ESC > application and normal keypad mode.
test "ESC = sets application keypad mode, ESC > clears it" {
    var grid = try Grid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();

    try std.testing.expect(!grid.isApplicationKeypadEnabled());
    grid.feed("\x1b=");
    try std.testing.expect(grid.isApplicationKeypadEnabled());
    grid.feed("\x1b>");
    try std.testing.expect(!grid.isApplicationKeypadEnabled());
}

test "ESC = does not affect the displayed grid" {
    var grid = try Grid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();
    grid.feed("\x1b=AB\x1b>C");

    const line = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("ABC", line);
}

test "ESC c resets application keypad mode" {
    var grid = try Grid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();
    grid.feed("\x1b=\x1bc");
    try std.testing.expect(!grid.isApplicationKeypadEnabled());
}

// Item 3: DECAWM auto-wrap mode (CSI ?7 h/l).
test "DECAWM off: chars at the right margin overwrite last cell instead of wrapping" {
    var grid = try Grid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();

    // Default: wrap is on.
    try std.testing.expect(grid.isAutoWrapEnabled());

    // Disable auto-wrap.
    grid.feed("\x1b[?7l");
    try std.testing.expect(!grid.isAutoWrapEnabled());

    // Write 6 chars into a 4-col grid; the last 3 should all overwrite col 3.
    grid.feed("ABCDEF");

    const line0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line0);
    // Without wrap the last char wins at column 3; row 1 untouched.
    try std.testing.expectEqualStrings("ABCF", line0);
    const line1 = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(line1);
    try std.testing.expectEqualStrings("    ", line1);
    // Cursor stays at the right margin.
    try std.testing.expectEqual(@as(usize, 3), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 0), grid.cursor_y);
}

test "DECAWM re-enable restores normal wrap behaviour" {
    var grid = try Grid.init(std.testing.allocator, 3, 2);
    defer grid.deinit();
    grid.feed("\x1b[?7l");   // wrap off
    grid.feed("ABCDE");      // D and E overwrite col 2

    grid.feed("\x1b[?7h");   // wrap back on
    grid.feed("\x1b[1;1H");  // home
    grid.feed("abc");        // fills row 0
    grid.feed("X");          // should wrap to row 1, col 0

    const line0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line0);
    try std.testing.expectEqualStrings("abc", line0);
    const line1 = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(line1);
    try std.testing.expectEqualStrings("X  ", line1);
}

test "DECAWM off wrap_pending is never set so SGR at right margin does not wrap" {
    // SGR does not cancel deferred wrap — verify that with auto-wrap off no
    // wrap_pending is ever set (even after a char at the last column).
    var grid = try Grid.init(std.testing.allocator, 3, 2);
    defer grid.deinit();
    grid.feed("\x1b[?7l");
    grid.feed("ABC");
    try std.testing.expect(!grid.wrap_pending);
    try std.testing.expectEqual(@as(usize, 2), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 0), grid.cursor_y);
}

// Item 2: C0 controls inside CSI execute in place without aborting the sequence.
test "LF embedded inside CSI executes then sequence completes" {
    // \x1b[3\n1mX  — the \n fires a newline mid-parse, then [31m applies and X
    // is written at the current (post-newline) position in red.
    var grid = try Grid.init(std.testing.allocator, 4, 3);
    defer grid.deinit();
    grid.feed("ab\x1b[3\n1mX");

    // The cursor started at col 2 row 0. The \n fired newline (cursor moves to
    // col 0 row 1 via newline() which also resets cursor_x). Then [31m applies
    // and X is written at row 1 col 0.
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[1 * grid.width + 0].ch);
    try std.testing.expectEqual(Color.red, grid.cells[1 * grid.width + 0].style.fg);
}

test "CR embedded inside CSI moves cursor to column zero mid-sequence" {
    var grid = try Grid.init(std.testing.allocator, 8, 2);
    defer grid.deinit();
    // Move to col 4, then fire a CSI with a CR embedded before the final byte.
    grid.feed("\x1b[1;5H");           // cursor at row 0 col 4
    grid.feed("\x1b[1\r0;5HX");      // CR inside CSI -> col 0; then [10;5HX
    // After CR cursor_x = 0, CSI "10;5H" -> row 10-1=9 clamped to 1, col 4.
    // After writing X at col 4, cursor advances to 5.
    try std.testing.expectEqual(@as(usize, 5), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 1), grid.cursor_y);
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[1 * grid.width + 4].ch);
}

test "BS embedded inside CSI moves cursor left mid-sequence" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("ABC");                  // cursor at col 3
    grid.feed("\x1b[3\x081mX");       // BS inside CSI -> cursor_x 2; [31m; X
    // After BS cursor_x = 2, [31m applies, X written at col 2.
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[2].ch);
    try std.testing.expectEqual(Color.red, grid.cells[2].style.fg);
}

test "CAN inside CSI aborts the sequence and returns to ground" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    // The \x18 (CAN) aborts the [31m sequence; X should appear with default style.
    grid.feed("\x1b[31\x18X");
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[0].ch);
    try std.testing.expectEqual(Color.default, grid.cells[0].style.fg);
}

test "C0-inside-CSI split across feed boundaries works correctly" {
    // The LF-inside-CSI case must be split-invariant.
    try expectSplitInvariant("ab\x1b[3\n1mX");
}

// Item 1: DECOM origin mode (CSI ?6 h/l).
test "DECOM homes cursor to scroll_top on enable" {
    var grid = try Grid.init(std.testing.allocator, 4, 5);
    defer grid.deinit();
    // Set scroll region rows 2-4 (1-based), then enable DECOM.
    grid.feed("\x1b[2;4r");     // scroll region, also homes cursor to (0,0)
    grid.feed("\x1b[3;3H");     // move cursor away: row 3 col 3
    grid.feed("\x1b[?6h");      // DECOM on — should home to (scroll_top=1, 0)
    try std.testing.expectEqual(@as(usize, 0), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 1), grid.cursor_y); // scroll_top
}

test "DECOM: CSI H row is relative to scroll_top and clamped" {
    var grid = try Grid.init(std.testing.allocator, 4, 6);
    defer grid.deinit();
    // Scroll region rows 3-5 (1-based), so scroll_top=2 scroll_bottom=4.
    grid.feed("\x1b[3;5r");
    grid.feed("\x1b[?6h");      // DECOM on

    // CSI 1;1H should go to (scroll_top+0, 0) = (2, 0).
    grid.feed("\x1b[1;1HX");
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[2 * grid.width + 0].ch);

    // CSI 2;3H should go to (scroll_top+1, 2) = (3, 2).
    grid.feed("\x1b[2;3HY");
    try std.testing.expectEqual(@as(u8, 'Y'), grid.cells[3 * grid.width + 2].ch);

    // CSI 99;1H should be clamped to scroll_bottom (row 4).
    grid.feed("\x1b[99;1HZ");
    try std.testing.expectEqual(@as(usize, 4), grid.cursor_y);
}

test "DECOM disable returns cursor home to row 0" {
    var grid = try Grid.init(std.testing.allocator, 4, 5);
    defer grid.deinit();
    grid.feed("\x1b[2;4r\x1b[?6h"); // DECOM on, homed to scroll_top
    grid.feed("\x1b[?6l");           // DECOM off — homes to (0, 0)
    try std.testing.expectEqual(@as(usize, 0), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 0), grid.cursor_y);
}

test "DECOM: DECSTBM homes to scroll_top when origin mode is active" {
    var grid = try Grid.init(std.testing.allocator, 4, 6);
    defer grid.deinit();
    grid.feed("\x1b[?6h");      // DECOM on (scroll_top still 0)
    grid.feed("\x1b[3;5r");     // DECSTBM: should home to scroll_top=2
    try std.testing.expectEqual(@as(usize, 0), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 2), grid.cursor_y);
}

// Item 4: Tab stops — HTS (ESC H) and TBC (CSI g).
test "ESC H sets a tab stop at the current column" {
    var grid = try Grid.init(std.testing.allocator, 20, 1);
    defer grid.deinit();

    // Move to col 5 (not a default stop) and set a stop there.
    grid.feed("\x1b[1;6H");   // col 5 (1-based -> 0-based col 5)
    grid.feed("\x1bH");       // HTS: set stop at col 5

    // Now tab from col 0: should land at 5 (our new stop), not 8.
    grid.feed("\x1b[1;1H");  // home
    grid.feed("\tX");
    try std.testing.expectEqual(@as(usize, 5), grid.cursor_x - 1); // X at col 5, cursor at 6
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[5].ch);
}

test "TBC clears the tab stop at the cursor column" {
    var grid = try Grid.init(std.testing.allocator, 20, 1);
    defer grid.deinit();

    // Clear the default stop at column 8.
    grid.feed("\x1b[1;9H");   // move to col 8 (1-based 9)
    grid.feed("\x1b[0g");     // TBC: clear stop at cursor

    // Tab from col 0: should skip 8 (cleared) and land at 16.
    grid.feed("\x1b[1;1H\tX");
    try std.testing.expectEqual(@as(usize, 16), grid.cursor_x - 1);
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[16].ch);
}

test "TBC 3 clears all tab stops" {
    var grid = try Grid.init(std.testing.allocator, 20, 1);
    defer grid.deinit();
    grid.feed("\x1b[3g");     // TBC 3: clear all stops

    // Tab from col 0 with no stops: cursor should jump to last column (19).
    // Then X is written at col 19; cursor stays at 19 with wrap_pending set.
    grid.feed("\x1b[1;1H\tX");
    try std.testing.expectEqual(@as(usize, 19), grid.cursor_x);
    try std.testing.expect(grid.wrap_pending);
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[19].ch);
}

test "HTS and TBC interact correctly with default eight-column stops" {
    var grid = try Grid.init(std.testing.allocator, 24, 1);
    defer grid.deinit();

    // Default stops at 0, 8, 16. Tab from col 1 -> col 8.
    grid.feed("\x1b[1;2H\tX");
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[8].ch);

    // Add a stop at col 4, tab from col 1 -> col 4.
    grid.feed("\x1b[1;5H\x1bH");  // set stop at col 4
    grid.feed("\x1b[1;2H\tY");
    try std.testing.expectEqual(@as(u8, 'Y'), grid.cells[4].ch);
}

test "ESC c resets tab stops to eight-column defaults" {
    var grid = try Grid.init(std.testing.allocator, 20, 1);
    defer grid.deinit();
    grid.feed("\x1b[3g");   // clear all stops
    grid.feed("\x1bc");     // hard reset — should restore defaults

    // Tab from col 0 -> col 8.
    grid.feed("\x1b[1;1H\tX");
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[8].ch);
}

// --- Extended VT conformance test section ---
// These tests exercise CSI/OSC parsing, cursor save/restore, erase modes, scroll
// regions, alternate screen, private modes, and malformed-sequence recovery
// using the split-invariance fuzzer style from the existing conformance block.

test "vt: CSI H and f are equivalent for absolute cursor positioning" {
    var grid = try Grid.init(std.testing.allocator, 8, 4);
    defer grid.deinit();
    grid.feed("\x1b[2;4HX");   // CSI H: row 2 col 4
    grid.feed("\x1b[3;2fY");   // CSI f: row 3 col 2
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[1 * grid.width + 3].ch);
    try std.testing.expectEqual(@as(u8, 'Y'), grid.cells[2 * grid.width + 1].ch);
}

test "vt: cursor save/restore preserves position across styles" {
    var grid = try Grid.init(std.testing.allocator, 8, 3);
    defer grid.deinit();
    grid.feed("\x1b[2;3H");    // cursor at row 1 col 2
    grid.feed("\x1b[s");       // save (CSI s)
    grid.feed("\x1b[31m");     // change style
    grid.feed("\x1b[3;1H");    // move elsewhere
    grid.feed("\x1b[u");       // restore
    try std.testing.expectEqual(@as(usize, 2), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 1), grid.cursor_y);
}

test "vt: ESC 7 / ESC 8 save-restore round-trips cursor" {
    var grid = try Grid.init(std.testing.allocator, 8, 4);
    defer grid.deinit();
    grid.feed("\x1b[3;5H");    // cursor row 2 col 4
    grid.feed("\x1b" ++ "7"); // ESC 7: save
    grid.feed("\x1b[1;1H");   // home
    grid.feed("\x1b" ++ "8"); // ESC 8: restore
    try std.testing.expectEqual(@as(usize, 4), grid.cursor_x);
    try std.testing.expectEqual(@as(usize, 2), grid.cursor_y);
}

test "vt: ED 0 erases from cursor to end-of-screen" {
    var grid = try Grid.init(std.testing.allocator, 4, 3);
    defer grid.deinit();
    grid.feed("ABCD\nEFGH\nIJKL");
    grid.feed("\x1b[2;3H");    // cursor row 1 col 2
    grid.feed("\x1b[0J");

    const row0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(row0);
    const row1 = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(row1);
    const row2 = try grid.lineAlloc(std.testing.allocator, 2);
    defer std.testing.allocator.free(row2);
    try std.testing.expectEqualStrings("ABCD", row0);
    try std.testing.expectEqualStrings("EF  ", row1);
    try std.testing.expectEqualStrings("    ", row2);
}

test "vt: ED 1 erases from beginning-of-screen to cursor" {
    var grid = try Grid.init(std.testing.allocator, 4, 3);
    defer grid.deinit();
    grid.feed("ABCD\nEFGH\nIJKL");
    grid.feed("\x1b[2;3H\x1b[1J");

    const row0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(row0);
    const row1 = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(row1);
    const row2 = try grid.lineAlloc(std.testing.allocator, 2);
    defer std.testing.allocator.free(row2);
    try std.testing.expectEqualStrings("    ", row0);
    try std.testing.expectEqualStrings("   H", row1);
    try std.testing.expectEqualStrings("IJKL", row2);
}

test "vt: EL 0/1/2 erase within the current line only" {
    var grid = try Grid.init(std.testing.allocator, 6, 3);
    defer grid.deinit();
    grid.feed("AAAAAA\nBBBBBB\nCCCCCC");

    grid.feed("\x1b[1;4H\x1b[0K"); // EL 0: erase col 3..end of row 0
    const row0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(row0);
    try std.testing.expectEqualStrings("AAA   ", row0);

    grid.feed("\x1b[2;4H\x1b[1K"); // EL 1: erase col 0..3 of row 1
    const row1 = try grid.lineAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(row1);
    try std.testing.expectEqualStrings("    BB", row1);

    grid.feed("\x1b[3;1H\x1b[2K"); // EL 2: erase entire row 2
    const row2 = try grid.lineAlloc(std.testing.allocator, 2);
    defer std.testing.allocator.free(row2);
    try std.testing.expectEqualStrings("      ", row2);
}

test "vt: alternate screen switch preserves primary scrollback" {
    var grid = try Grid.initWithMaxScrollback(std.testing.allocator, 4, 2, 16);
    defer grid.deinit();
    grid.feed("line\nnext\nlast");   // 1 line pushed to scrollback
    const hist_before = grid.historyLen();

    grid.feed("\x1b[?1049h");        // enter alt screen
    grid.feed("alt1\nalt2\nalt3");   // scroll alt screen
    grid.feed("\x1b[?1049l");        // exit alt screen

    try std.testing.expectEqual(hist_before, grid.historyLen());
    const row0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(row0);
    try std.testing.expectEqualStrings("next", row0);
}

test "vt: private mode 47 (simple alt screen) switches buffers" {
    var grid = try Grid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();
    grid.feed("main");
    grid.feed("\x1b[?47h");   // enter alt (no cursor save)
    try std.testing.expect(grid.isAlternateScreen());
    grid.feed("\x1b[?47l");   // exit
    try std.testing.expect(!grid.isAlternateScreen());
    const row0 = try grid.lineAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(row0);
    try std.testing.expectEqualStrings("main", row0);
}

test "vt: OSC with BEL terminator is consumed without corrupting screen" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("\x1b]2;Terminal Title\x07HI");
    const line = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("HI", line);
}

test "vt: OSC with ST terminator (ESC backslash) is consumed" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("\x1b]0;title\x1b\\AB");
    const line = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("AB", line);
}

test "vt: OSC with CAN (0x18) abort is consumed" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("\x1b]0;title\x18AB");
    const line = try grid.lineTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("AB", line);
}

test "vt: stray ESC [ without final byte resyncs on next ESC" {
    // An uncompleted CSI followed by another ESC: the second ESC aborts the
    // first and starts a fresh escape. The valid [31m should then apply.
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("\x1b[99\x1b[31mX");
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[0].ch);
    try std.testing.expectEqual(Color.red, grid.cells[0].style.fg);
}

test "vt: CSI with unknown final byte is silently ignored" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("\x1b[99~");   // 0x7e is a valid final byte (DEL key VT); parsed but not handled
    grid.feed("X");
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[0].ch);
    try std.testing.expectEqual(@as(usize, 0), grid.cursor_y);
}

test "vt: split-invariant across cursor-home and erase" {
    try expectSplitInvariant("\x1b[2;3HX\x1b[1;1H\x1b[2J\x1b[1;1HY");
}

test "vt: split-invariant across scroll region and reverse index" {
    try expectSplitInvariant("AAA\nBBB\nCCC\x1b[2;3r\x1b[2;1H\x1bM\x1b[3;1HZ");
}

test "vt: split-invariant across alternate screen with scrollback" {
    try expectSplitInvariant("main\x1b[?1049halt\nmore\n\x1b[?1049l!");
}

test "vt: split-invariant for DECAWM disable / enable" {
    try expectSplitInvariant("\x1b[?7lABCDEF\x1b[?7h\nGHI");
}

test "vt: split-invariant for DECOM + CSI H" {
    try expectSplitInvariant("\x1b[2;4r\x1b[?6h\x1b[1;1HX\x1b[?6l");
}

test "vt: split-invariant for C0 inside CSI" {
    try expectSplitInvariant("ab\x1b[3\n1mX");
}

test "vt: split-invariant for HTS and tab" {
    try expectSplitInvariant("\x1b[1;6H\x1bH\x1b[1;1H\tX");
}

test "tab stops are reinitialised at new width after resize" {
    // Regression test for the resize + tab_stops capacity bug.
    // Before the fix, resizing to a wider grid while a tab_stops bitmap was
    // live at the old width would leave the bitmap at the old capacity.  A
    // subsequent HTS (ESC H) at a column >= old width would then panic with
    // an out-of-bounds bit-set access.

    // Start with a 10-wide grid and materialise the bitmap by setting a
    // non-default tab stop at col 5.
    var grid = try Grid.init(std.testing.allocator, 10, 2);
    defer grid.deinit();
    grid.feed("\x1b[1;6H\x1bH"); // cursor to col 5, HTS — bitmap materialises at width 10

    // Resize to 24 wide.  The bitmap must be discarded so that the next
    // ensureTabStops call rebuilds it at the new capacity.
    try grid.resize(24, 2);

    // HTS at col 18 — past the old width of 10.  Must not panic.
    grid.feed("\x1b[1;19H\x1bH"); // cursor to col 18 (1-based 19), HTS

    // Verify the stop is reachable: tab from col 0 should skip default stops
    // at 0, 8, 16 and land on the custom stop at 18, then X goes to col 19.
    grid.feed("\x1b[1;1H");  // cursor home
    grid.feed("\t\t\tX");    // three tabs: 0→8→16→18, then X at 18, cursor→19
    try std.testing.expectEqual(@as(u8, 'X'), grid.cells[18].ch);
    try std.testing.expectEqual(@as(usize, 19), grid.cursor_x);
}
