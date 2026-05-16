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
    mouse_tracking: MouseTracking = .disabled,
    mouse_encoding: MouseEncoding = .default,
    current_style: Style = .{},
    history: std.ArrayList(HistoryLine) = .empty,
    max_scrollback: usize = default_max_scrollback,

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
        };
    }

    pub fn deinit(self: *Grid) void {
        for (self.history.items) |line| {
            self.allocator.free(line.cells);
        }
        self.history.deinit(self.allocator);
        self.allocator.free(self.primary_cells);
        self.allocator.free(self.alternate_cells);
        self.* = undefined;
    }

    pub fn feed(self: *Grid, bytes: []const u8) void {
        var index: usize = 0;
        while (index < bytes.len) {
            const byte = bytes[index];
            switch (byte) {
                '\n' => {
                    self.wrap_pending = false;
                    self.newline();
                    index += 1;
                },
                '\r' => {
                    self.wrap_pending = false;
                    self.cursor_x = 0;
                    index += 1;
                },
                0x08 => {
                    self.wrap_pending = false;
                    if (self.cursor_x > 0) self.cursor_x -= 1;
                    index += 1;
                },
                '\t' => {
                    self.tab();
                    index += 1;
                },
                0x1b => {
                    index = self.consumeEscape(bytes, index);
                },
                else => {
                    if (byte >= 0x20) {
                        const decoded = decodeUtf8Scalar(bytes[index..]);
                        self.putCodepoint(decoded.codepoint);
                        index += decoded.len;
                    } else {
                        index += 1;
                    }
                },
            }
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
    }

    fn consumeEscape(self: *Grid, bytes: []const u8, start: usize) usize {
        if (start + 1 >= bytes.len) return start + 1;
        switch (bytes[start + 1]) {
            '[' => {},
            '7' => {
                self.saveCursor();
                return start + 2;
            },
            '8' => {
                self.restoreCursor();
                return start + 2;
            },
            else => return start + 2,
        }
        var index = start + 2;
        while (index < bytes.len) : (index += 1) {
            const final = bytes[index];
            if ((final >= '@' and final <= '~')) {
                self.applyCsi(bytes[start + 2 .. index], final);
                return index + 1;
            }
        }
        return start + 1;
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
    }

    fn exitAlternateScreen(self: *Grid, clear: bool) void {
        if (!self.alternate_screen) return;
        self.alternate_state = self.activeState();
        if (clear) self.clearCells(self.alternate_cells);
        self.alternate_screen = false;
        self.cells = self.primary_cells;
        self.loadState(self.primary_state);
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
        if (params.len == 0) {
            self.cursor_x = 0;
            self.cursor_y = 0;
            return;
        }

        const row = csiParam(params, 0, 1);
        const col = csiParam(params, 1, 1);
        self.cursor_y = @min(if (row == 0) 0 else row - 1, self.height - 1);
        self.cursor_x = @min(if (col == 0) 0 else col - 1, self.width - 1);
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
        const next_stop = ((self.cursor_x / 8) + 1) * 8;
        self.cursor_x = @min(next_stop, self.width - 1);
    }

    fn put(self: *Grid, byte: u8) void {
        self.putCodepoint(byte);
    }

    fn putCodepoint(self: *Grid, codepoint: u21) void {
        if (self.wrap_pending) {
            self.cursor_x = 0;
            self.newline();
            self.wrap_pending = false;
        }

        var display_width = cellDisplayWidth(codepoint);
        if (display_width == 2 and self.width == 1) display_width = 1;
        if (display_width == 2 and self.cursor_x + 1 >= self.width) {
            self.cursor_x = 0;
            self.newline();
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
            self.cursor_x = self.width - 1;
            self.wrap_pending = true;
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
        const count = @min(requested_count, self.height - self.cursor_y);
        if (count == 0) return;

        const src = self.cells[self.cursor_y * self.width .. (self.height - count) * self.width];
        const dst = self.cells[(self.cursor_y + count) * self.width .. self.height * self.width];
        std.mem.copyBackwards(Cell, dst, src);

        var row = self.cursor_y;
        while (row < self.cursor_y + count) : (row += 1) {
            self.clearLine(row);
        }
    }

    fn deleteLines(self: *Grid, requested_count: usize) void {
        const count = @min(requested_count, self.height - self.cursor_y);
        if (count == 0) return;

        const src = self.cells[(self.cursor_y + count) * self.width .. self.height * self.width];
        const dst = self.cells[self.cursor_y * self.width .. (self.height - count) * self.width];
        std.mem.copyForwards(Cell, dst, src);

        var row = self.height - count;
        while (row < self.height) : (row += 1) {
            self.clearLine(row);
        }
    }

    fn newline(self: *Grid) void {
        self.cursor_x = 0;
        if (self.cursor_y + 1 < self.height) {
            self.cursor_y += 1;
            return;
        }
        self.scrollUp();
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
