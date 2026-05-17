# VT Conformance Harness

This guide describes a new binary, `ziggyzag-conformance`, that drives the terminal grid through curated VT/CSI/OSC sequences and asserts the resulting cell state. It complements the 82 in-file unit tests in `apps/desktop/src/terminal.zig` by providing a runnable corpus that can be extended without touching the parser source, and by emitting TAP output so CI can summarise pass/fail at the case level.

The harness is additive. It uses the existing public `Grid` API (`Grid.init`, `Grid.feed`, `Grid.lineTextAlloc`, `Grid.visibleTextAlloc`, the cursor and style fields) and does not change the parser. The point is coverage on the corpus, not new features on the terminal.

## Why a separate harness

The unit tests in `terminal.zig` are excellent for tight feedback during parser changes. They run inside `zig build test` and check structural invariants like split-feed equivalence. What they do not do well is scale to hundreds of golden VT sequences, group cases by feature family, or produce machine-readable per-case output. A separate binary with a flat corpus gives that.

This split is the same one Ghostty made when factoring `src/terminal/` into an audited surface against historical xterm behaviour: a parser-level test suite plus a comparison corpus against a reference [1]. vttest itself takes the form of an interactive binary keyed by sequence family [2]. ZiggyZag's harness is non-interactive — it is a CI step, not a tool a human drives.

## Corpus organisation

The corpus is laid out by sequence family. Each family is a `.zig` file under `apps/conformance/corpus/`:

```
apps/conformance/
  src/
    main.zig          # entry point, TAP printer, CLI flags
    case.zig          # Case struct, runCase()
  corpus/
    csi_cursor.zig    # CUU/CUD/CUF/CUB/CUP, save/restore
    csi_erase.zig     # ED, EL, IL, DL, ICH, DCH
    csi_sgr.zig       # SGR colors, attributes, resets
    csi_modes.zig     # DECSET/DECRST private modes
    csi_scroll.zig    # DECSTBM, IND, RI, NEL
    osc_title.zig     # OSC 0/1/2 title sequences (consumed only)
    osc_hyperlink.zig # OSC 8 (links forward to its own spec)
    esc_simple.zig    # ESC 7/8, ESC c, ESC =, ESC >, ESC H
    utf8.zig          # multi-byte scalars, splits, invalid leads
    split.zig         # byte-split invariance across families
```

Each file exports an array of `Case` literals. There is no test discovery magic — `main.zig` imports the family modules explicitly and walks each array. Adding a case is editing one file; adding a family is two lines in `main.zig`.

## Case shape

A `Case` is the smallest unit. It owns its input bytes, the assertions to run, and a human-readable name (used as the TAP description). Keeping it data-flat — no closures, no setup callbacks — keeps the corpus diffable and lets external contributors add cases without learning the harness.

```zig
pub const Case = struct {
    name: []const u8,
    grid_width: usize = 16,
    grid_height: usize = 4,
    input: []const u8,
    expect: Expect,
};

pub const Expect = struct {
    visible: ?[]const u8 = null,    // expected visibleTextAlloc result
    cursor: ?[2]usize = null,        // [x, y]
    cell_at: ?CellAssertion = null,  // single-cell spot check
    history_len: ?usize = null,
    alternate_screen: ?bool = null,
};

pub const CellAssertion = struct {
    row: usize,
    col: usize,
    codepoint: u21,
    fg: ?terminal.Color = null,
    bg: ?terminal.Color = null,
};
```

The runner in `case.zig` allocates a `Grid`, feeds the input, and checks each non-null field of `Expect`. A failing assertion prints the diff and continues — one bad case must not mask the rest.

## TAP output

TAP (Test Anything Protocol) is the lowest-common-denominator format that GitHub Actions, GitLab CI, and local TAP consumers all parse. The harness emits TAP 13:

```
TAP version 13
1..5
ok 1 - csi_cursor: CUP 1;1 homes the cursor
ok 2 - csi_cursor: CUF advances within the row
not ok 3 - csi_erase: ED 0 clears below cursor
  ---
  expected: "AAA\n   \n   "
  got:      "AAA\nBBB\nCCC"
  ---
ok 4 - csi_sgr: SGR 31 sets red foreground
ok 5 - osc_title: OSC 0 title is consumed
```

A `--format=human` flag is also accepted for local runs. CI uses TAP; humans use human.

## Build integration

`build.zig` gains a `conformance` step that compiles and runs the harness. The corpus modules are private to the conformance binary — they do not appear in `desktop_tests` and do not bloat shell or agentd builds.

```zig
const conformance_module = b.createModule(.{
    .root_source_file = b.path("apps/conformance/src/main.zig"),
    .target = target,
    .optimize = optimize,
});
conformance_module.addImport("desktop", b.createModule(.{
    .root_source_file = b.path("apps/desktop/src/lib.zig"),
    .target = target,
    .optimize = optimize,
}));
const conformance_exe = b.addExecutable(.{
    .name = "ziggyzag-conformance",
    .root_module = conformance_module,
});
b.installArtifact(conformance_exe);

const run_conformance = b.addRunArtifact(conformance_exe);
const conformance_step = b.step("conformance", "Run the VT conformance corpus");
conformance_step.dependOn(&run_conformance.step);
```

`zig build test` continues to run only the in-file unit tests. `zig build conformance` runs the corpus. CI runs both.

## Five sample cases

```zig
// corpus/csi_cursor.zig
pub const cases = [_]Case{
    .{
        .name = "CUP 1;1 homes the cursor",
        .input = "XXX\x1b[1;1H",
        .expect = .{ .cursor = .{ 0, 0 } },
    },
    .{
        .name = "CUF 3 advances within the row",
        .input = "\x1b[3C",
        .expect = .{ .cursor = .{ 3, 0 } },
    },
};
```

```zig
// corpus/csi_erase.zig
pub const cases = [_]Case{
    .{
        .name = "ED 0 clears from cursor to end-of-screen",
        .grid_width = 4, .grid_height = 3,
        .input = "AAAA\nBBBB\nCCCC\x1b[2;2H\x1b[0J",
        .expect = .{ .visible = "AAAA\nB\n" },
    },
};
```

```zig
// corpus/csi_sgr.zig
pub const cases = [_]Case{
    .{
        .name = "SGR 31 sets red foreground for following cells",
        .input = "\x1b[31mZ",
        .expect = .{
            .cell_at = .{ .row = 0, .col = 0, .codepoint = 'Z', .fg = .red },
        },
    },
};
```

```zig
// corpus/osc_title.zig
pub const cases = [_]Case{
    .{
        .name = "OSC 0 title sequence is consumed without reaching cells",
        .input = "A\x1b]0;window title\x07B",
        .expect = .{ .visible = "AB\n\n\n" },
    },
};
```

## What this doc does not specify

- The wire format for golden snapshots of full grid state (would be needed for diff-on-update workflows; currently each case spells out its expectation in source).
- A JSON output mode alongside TAP and human — punted until a downstream consumer asks.
- Cross-platform reference-terminal comparison (running the same corpus against xterm via vttest-style scripting and diffing). Tracked under [`vision/alpha-tasks.md`](../vision/alpha-tasks.md).
- A fuzz mode that mutates corpus inputs at the byte level and asserts only that the parser does not crash or allocate unboundedly.
- Performance benchmarks per family. The corpus is correctness-only; throughput sits in a separate binary if it ever becomes necessary.

## Sources

[1] Ghostty VT reference and parser layout — https://ghostty.org/docs/vt and https://github.com/ghostty-org/ghostty (`src/terminal/Parser.zig`).
[2] vttest, the historical VT100/VT220/xterm test utility — https://invisible-island.net/vttest/. The corpus-by-family layout is borrowed from its menu structure; the TAP output is ZiggyZag's choice for CI legibility.
