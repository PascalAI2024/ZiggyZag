//! Standalone VT conformance harness for the ZiggyZag terminal grid.
//!
//! Feeds a fixed corpus of CSI / OSC / erase / scroll-region / alt-screen
//! escape sequences into a fresh `terminal.Grid` and asserts the resulting
//! grid state (each visible row's text plus the cursor position). On a
//! mismatch it prints a readable per-row diff and the harness exits non-zero,
//! so `zig build vt-conformance` is a hard gate in CI.
//!
//! This is intentionally a separate runnable binary from the in-file unit
//! tests: the unit tests prove individual handlers in isolation, while this
//! corpus exercises whole-sequence interactions (scroll region + cursor home,
//! alt screen save/restore, SGR + erase) and produces a human-readable report
//! when something regresses.

const std = @import("std");
const terminal = @import("terminal.zig");

/// One conformance case: feed `input` into a fresh `width`×`height` grid and
/// assert every visible row equals `rows[i]` and the cursor lands at
/// (`cursor_x`, `cursor_y`).
const Case = struct {
    name: []const u8,
    width: usize,
    height: usize,
    input: []const u8,
    rows: []const []const u8,
    cursor_x: usize,
    cursor_y: usize,
};

const corpus = [_]Case{
    .{
        .name = "plain text with newlines lands on the grid",
        .width = 3,
        .height = 3,
        .input = "AAA\nBBB\nCCC",
        .rows = &.{ "AAA", "BBB", "CCC" },
        // Filling the last column leaves the cursor parked on it (pending wrap),
        // not advanced past the right margin.
        .cursor_x = 2,
        .cursor_y = 2,
    },
    .{
        .name = "CSI H absolute cursor move then overwrite",
        .width = 4,
        .height = 3,
        .input = "abcd\nefgh\nijkl\x1b[2;2HX",
        .rows = &.{ "abcd", "eXgh", "ijkl" },
        .cursor_x = 2,
        .cursor_y = 1,
    },
    .{
        .name = "CSI 2J erases the whole screen and CSI H homes the cursor",
        .width = 3,
        .height = 2,
        .input = "XXX\nYYY\x1b[2J\x1b[H",
        .rows = &.{ "", "" },
        .cursor_x = 0,
        .cursor_y = 0,
    },
    .{
        .name = "CSI K erases from the cursor to the end of the line",
        .width = 5,
        .height = 1,
        .input = "ABCDE\x1b[1;3H\x1b[K",
        .rows = &.{"AB"},
        .cursor_x = 2,
        .cursor_y = 0,
    },
    .{
        .name = "CSI 1K erases from line start to the cursor inclusive",
        .width = 5,
        .height = 1,
        .input = "ABCDE\x1b[1;3H\x1b[1K",
        .rows = &.{"   DE"},
        .cursor_x = 2,
        .cursor_y = 0,
    },
    .{
        .name = "DECSTBM scroll region scrolls only within its margins",
        .width = 3,
        .height = 5,
        .input = "AAA\nBBB\nCCC\nDDD\nEEE\x1b[2;4r\x1b[4;1H\nXXX",
        .rows = &.{ "AAA", "CCC", "DDD", "XXX", "EEE" },
        .cursor_x = 2,
        .cursor_y = 3,
    },
    .{
        .name = "ESC M reverse index scrolls the region down at the top",
        .width = 3,
        .height = 3,
        .input = "AAA\nBBB\nCCC\x1b[1;1H\x1bM",
        .rows = &.{ "", "AAA", "BBB" },
        .cursor_x = 0,
        .cursor_y = 0,
    },
    .{
        .name = "CSI L inserts a blank line at the cursor within the region",
        .width = 3,
        .height = 3,
        .input = "AAA\nBBB\nCCC\x1b[2;1H\x1b[L",
        .rows = &.{ "AAA", "", "BBB" },
        .cursor_x = 0,
        .cursor_y = 1,
    },
    .{
        .name = "CSI M deletes a line at the cursor, pulling lines up",
        .width = 3,
        .height = 3,
        .input = "AAA\nBBB\nCCC\x1b[1;1H\x1b[M",
        .rows = &.{ "BBB", "CCC", "" },
        .cursor_x = 0,
        .cursor_y = 0,
    },
    .{
        .name = "alt screen is independent and restores the primary on exit",
        .width = 3,
        .height = 2,
        .input = "AB\nCD\x1b[?1049hZZ\x1b[?1049l",
        .rows = &.{ "AB", "CD" },
        .cursor_x = 2,
        .cursor_y = 1,
    },
    .{
        .name = "SGR color does not alter the printed glyphs",
        .width = 4,
        .height = 1,
        .input = "\x1b[31mRED\x1b[0m",
        .rows = &.{"RED"},
        .cursor_x = 3,
        .cursor_y = 0,
    },
    .{
        .name = "CSI C and CSI D move the cursor right then left",
        .width = 6,
        .height = 1,
        .input = "\x1b[3C\x1b[1DX",
        .rows = &.{"  X"},
        .cursor_x = 3,
        .cursor_y = 0,
    },
    .{
        .name = "box-drawing glyphs render as narrow cells, not '?'",
        .width = 8,
        .height = 1,
        .input = "\u{250c}\u{2500}\u{2510}",
        .rows = &.{"\u{250c}\u{2500}\u{2510}"},
        .cursor_x = 3,
        .cursor_y = 0,
    },
    .{
        // The combining mark takes no column and is not stored on the base
        // cell yet (see putCodepoint), so the row text is "ex" — the important
        // property is that 'x' is not shifted and the cursor advances by 2.
        .name = "combining mark is zero-width and does not shift following text",
        .width = 8,
        .height = 1,
        .input = "e\u{0301}x",
        .rows = &.{"ex"},
        .cursor_x = 2,
        .cursor_y = 0,
    },
    .{
        .name = "CJK wide pair advances two columns with a continuation cell",
        .width = 8,
        .height = 1,
        .input = "a\u{4e2d}b",
        .rows = &.{"a\u{4e2d}b"},
        .cursor_x = 4,
        .cursor_y = 0,
    },
};

const Failure = struct {
    case: []const u8,
    detail: []const u8,
};

pub fn main(init_data: std.process.Init) !void {
    const allocator = init_data.gpa;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init_data.io, &stderr_buf);
    const out = &stderr_writer.interface;

    var passed: usize = 0;
    var failed: usize = 0;

    for (corpus) |case| {
        const ok = runCase(allocator, out, case) catch |err| {
            try out.print("ERROR  {s}: {s}\n", .{ case.name, @errorName(err) });
            failed += 1;
            continue;
        };
        if (ok) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    try out.print("\nvt-conformance: {d} passed, {d} failed ({d} cases)\n", .{ passed, failed, corpus.len });
    try out.flush();

    if (failed != 0) std.process.exit(1);
}

/// Run one case. Returns true on a full match; on mismatch prints a readable
/// per-row diff and returns false.
fn runCase(allocator: std.mem.Allocator, out: anytype, case: Case) !bool {
    var grid = try terminal.Grid.init(allocator, case.width, case.height);
    defer grid.deinit();
    grid.feed(case.input);

    var ok = true;
    var diff: std.Io.Writer.Allocating = .init(allocator);
    defer diff.deinit();
    const dw = &diff.writer;

    // Compare each visible row.
    var row: usize = 0;
    while (row < case.height) : (row += 1) {
        const actual = try grid.lineTextAlloc(allocator, row);
        defer allocator.free(actual);
        const expected: []const u8 = if (row < case.rows.len) case.rows[row] else "";
        if (!std.mem.eql(u8, actual, expected)) {
            ok = false;
            try dw.print("  row {d}: expected {f} got {f}\n", .{
                row, Quoted{ .s = expected }, Quoted{ .s = actual },
            });
        }
    }

    // Compare the cursor position.
    if (grid.cursor_x != case.cursor_x or grid.cursor_y != case.cursor_y) {
        ok = false;
        try dw.print("  cursor: expected ({d},{d}) got ({d},{d})\n", .{
            case.cursor_x, case.cursor_y, grid.cursor_x, grid.cursor_y,
        });
    }

    if (ok) {
        try out.print("ok     {s}\n", .{case.name});
    } else {
        try out.print("FAIL   {s}\n", .{case.name});
        try out.writeAll(diff.written());
    }
    return ok;
}

/// Formats a byte slice with surrounding quotes and visible escapes so a
/// diff line reads cleanly even when the value contains control bytes.
const Quoted = struct {
    s: []const u8,

    pub fn format(self: Quoted, writer: anytype) !void {
        try writer.writeByte('"');
        for (self.s) |b| {
            switch (b) {
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x1b => try writer.writeAll("\\e"),
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                else => {
                    if (b < 0x20) {
                        try writer.print("\\x{x:0>2}", .{b});
                    } else {
                        try writer.writeByte(b);
                    }
                },
            }
        }
        try writer.writeByte('"');
    }
};
