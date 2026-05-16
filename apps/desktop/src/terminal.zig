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

pub const Style = struct {
    bold: bool = false,
    dim: bool = false,
    fg: Color = .default,
    bg: Color = .default,
};

pub const Cell = struct {
    ch: u8 = ' ',
    style: Style = .{},
};

pub const HistoryLine = struct {
    width: usize,
    cells: []Cell,
};

pub const Grid = struct {
    allocator: Allocator,
    width: usize,
    height: usize,
    cursor_x: usize = 0,
    cursor_y: usize = 0,
    wrap_pending: bool = false,
    cells: []Cell,
    current_style: Style = .{},
    history: std.ArrayList(HistoryLine) = .empty,

    pub fn init(allocator: Allocator, width: usize, height: usize) !Grid {
        if (width == 0 or height == 0) return error.InvalidGridSize;
        const cells = try allocator.alloc(Cell, width * height);
        @memset(cells, .{});
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .cells = cells,
        };
    }

    pub fn deinit(self: *Grid) void {
        for (self.history.items) |line| {
            self.allocator.free(line.cells);
        }
        self.history.deinit(self.allocator);
        self.allocator.free(self.cells);
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
                    if (byte >= 0x20) self.put(byte);
                    index += 1;
                },
            }
        }
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
            len += trimmedCellLen(line);
            if (row + 1 < self.height) len += 1;
        }

        const text = try allocator.alloc(u8, len);
        var out: usize = 0;
        row = 0;
        while (row < self.height) : (row += 1) {
            const line = self.cells[row * self.width .. (row + 1) * self.width];
            const trimmed_len = trimmedCellLen(line);
            for (line[0..trimmed_len]) |cell| {
                text[out] = cell.ch;
                out += 1;
            }
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
            if (line_end > line_start) len += line_end - line_start;
            if (row < last_row) len += 1;
        }

        const text = try allocator.alloc(u8, len);
        var out: usize = 0;
        row = first_row;
        while (row <= last_row) : (row += 1) {
            const line_start = if (row == first_row) @min(first_col, self.width) else 0;
            const line_end = if (row == last_row) @min(last_col, self.width) else self.width;
            const line = self.cells[row * self.width .. (row + 1) * self.width];
            var col = line_start;
            while (col < line_end) : (col += 1) {
                text[out] = line[col].ch;
                out += 1;
            }
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
        const old_cells = self.cells;
        const new_cells = try self.allocator.alloc(Cell, width * height);
        @memset(new_cells, .{});

        const copy_width = @min(old_width, width);
        const copy_height = @min(old_height, height);
        var row: usize = 0;
        while (row < copy_height) : (row += 1) {
            const old_start = row * old_width;
            const new_start = row * width;
            @memcpy(new_cells[new_start .. new_start + copy_width], old_cells[old_start .. old_start + copy_width]);
        }

        self.allocator.free(old_cells);
        self.width = width;
        self.height = height;
        self.cells = new_cells;
        self.cursor_x = @min(self.cursor_x, width - 1);
        self.cursor_y = @min(self.cursor_y, height - 1);
        self.wrap_pending = false;
    }

    fn consumeEscape(self: *Grid, bytes: []const u8, start: usize) usize {
        if (start + 1 >= bytes.len or bytes[start + 1] != '[') return start + 1;
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
            'A', 'B', 'C', 'D' => self.cursorMove(params, final),
            'H', 'f' => self.cursorHome(params),
            'J' => self.clearScreen(csiParam(params, 0, 0)),
            'K' => self.clearLineByMode(csiParam(params, 0, 0)),
            'm' => self.applySgr(params),
            else => {},
        }
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
        if (self.wrap_pending) {
            self.cursor_x = 0;
            self.newline();
            self.wrap_pending = false;
        }
        self.cells[self.cursor_y * self.width + self.cursor_x] = .{
            .ch = byte,
            .style = self.current_style,
        };
        if (self.cursor_x + 1 >= self.width) {
            self.cursor_x = self.width - 1;
            self.wrap_pending = true;
        } else {
            self.cursor_x += 1;
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
        const start = row * self.width;
        const cells = try self.allocator.alloc(Cell, self.width);
        @memcpy(cells, self.cells[start .. start + self.width]);
        errdefer self.allocator.free(cells);
        try self.history.append(self.allocator, .{
            .width = self.width,
            .cells = cells,
        });
    }

    fn applySgr(self: *Grid, params: []const u8) void {
        if (params.len == 0) {
            self.current_style = .{};
            return;
        }

        var split = std.mem.splitScalar(u8, params, ';');
        while (split.next()) |part| {
            const code = std.fmt.parseInt(u16, part, 10) catch 0;
            switch (code) {
                0 => self.current_style = .{},
                1 => self.current_style.bold = true,
                2 => self.current_style.dim = true,
                22 => {
                    self.current_style.bold = false;
                    self.current_style.dim = false;
                },
                30...37 => self.current_style.fg = sgrColor(code - 30, false),
                39 => self.current_style.fg = .default,
                40...47 => self.current_style.bg = sgrColor(code - 40, false),
                49 => self.current_style.bg = .default,
                90...97 => self.current_style.fg = sgrColor(code - 90, true),
                100...107 => self.current_style.bg = sgrColor(code - 100, true),
                else => {},
            }
        }
    }
};

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

fn trimmedCellLen(cells: []const Cell) usize {
    var len = cells.len;
    while (len > 0 and cells[len - 1].ch == ' ') : (len -= 1) {}
    return len;
}

fn cellsTextAlloc(allocator: Allocator, cells: []const Cell) ![]u8 {
    const trimmed_len = trimmedCellLen(cells);
    const text = try allocator.alloc(u8, trimmed_len);
    for (text, 0..) |*out, index| {
        out.* = cells[index].ch;
    }
    return text;
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
