# Terminal Parser Guide

This guide covers the VT escape-sequence parser and terminal grid implemented in `apps/desktop/src/terminal.zig`. It explains the state machine design, why state is stored on the `Grid` struct, how each parser state handles bytes, what sequences are currently supported, and how to add a new escape sequence with a conformance test.

## Why State Lives On The Grid

The desktop host receives PTY output in arbitrary chunks. A multi-byte escape sequence can be split across two or more `feed()` calls — for example, `\x1b[3` arrives in one chunk and `1m` arrives in the next. If the parser were stateless, it would misinterpret the second chunk.

The `Grid` struct owns all parser state fields. `Grid.feed(bytes)` picks up exactly where the previous call left off. There is no requirement that any chunk contain a complete sequence.

## The Four Parser States

`ParseState` is an enum with four variants:

| State | Description |
| --- | --- |
| `ground` | Normal printable characters and C0 controls |
| `escape` | After seeing `ESC` (0x1b), before the next byte determines the sequence type |
| `csi` | Inside a CSI sequence (`ESC [`) — accumulating parameters |
| `osc` | Inside an OSC string (`ESC ]`) — consuming payload until a terminator |

The active state is stored in `Grid.parse_state`. `Grid.feedByte(byte)` dispatches on this field, calling `groundByte`, `escapeByte`, `csiByte`, or `oscByte` accordingly.

## UTF-8 Resumption

Plain UTF-8 text does not go through the `escape`/`csi`/`osc` states. It is handled entirely in `groundByte`. When a multi-byte scalar is split across `feed()` calls, the partial bytes are buffered in `Grid.utf8_buffer[4]`, `Grid.utf8_len` (bytes accumulated so far), and `Grid.utf8_need` (total bytes expected). `groundByte` resumes accumulation on the next call and emits the character only when all expected bytes have arrived.

## groundByte

`groundByte` handles the following byte ranges:

- `\n` (0x0a): line feed — advances cursor row, scrolls if at bottom of scroll region.
- `\r` (0x0d): carriage return — sets `cursor_x = 0`.
- `0x08` (BS): backspace — decrements `cursor_x` if non-zero.
- `0x09` (HT): horizontal tab — advances cursor to next tab stop.
- `0x1b` (ESC): transitions `parse_state` to `escape`.
- ASCII printables (0x20–0x7e): write character to current cell, advance cursor.
- Bytes with high bit set: start or continue a UTF-8 multi-byte scalar via `utf8_buffer`.

Other C0 controls are consumed without action in the current implementation.

## escapeByte

After `ESC`, the next byte determines the sequence type:

| Byte | Action |
| --- | --- |
| `[` (0x5b) | Transition to `csi`; clear `esc_buffer` and `esc_overflow` |
| `]` (0x5d) | Transition to `osc`; clear osc state |
| `7` | `saveCursor` — stores cursor position and style |
| `8` | `restoreCursor` — restores cursor position and style |
| `M` | Reverse index (RI) — scroll down one line if cursor is at top of scroll region |
| `D` | Index (IND) — line feed without CR |
| `E` | Next line (NEL) — `cursor_x = 0` then line feed |
| `c` | Hard reset (RIS) — clears grid, resets all parser and cursor state |
| anything else | Return to `ground` without action |

## csiByte

CSI sequences have the form `ESC [ <params> <final>`. The `csiByte` handler accumulates incoming bytes into `Grid.esc_buffer` (capacity 256 bytes). When the buffer would overflow, the `esc_overflow` flag is set. The sequence is discarded silently; the parser returns to `ground` on the next final byte (0x40–0x7e). A new `ESC` mid-CSI aborts the current sequence and re-enters `escape`.

When a final byte in the range 0x40–0x7e arrives and there was no overflow, `applyCsi` is called with the accumulated parameter bytes and the final byte.

## applyCsi: Supported Sequences

| Final byte | Sequence | Effect |
| --- | --- | --- |
| `@` | ICH | Insert `n` blank characters at cursor |
| `A` | CUU | Cursor up `n` rows |
| `B` | CUD | Cursor down `n` rows |
| `C` | CUF | Cursor forward `n` columns |
| `D` | CUB | Cursor back `n` columns |
| `H` / `f` | CUP | Move cursor to row/column |
| `J` | ED | Erase display by mode (0=below, 1=above, 2=all, 3=scrollback) |
| `K` | EL | Erase line by mode (0=to end, 1=to start, 2=all) |
| `L` | IL | Insert `n` blank lines |
| `M` | DL | Delete `n` lines |
| `P` | DCH | Delete `n` characters |
| `h` / `l` | DECSET/DECRST | Set or reset private mode (params must start with `?`) |
| `m` | SGR | Set graphics rendition (colors, attributes) |
| `r` | DECSTBM | Set scroll region (top and bottom margins, 1-based, stored as 0-based) |
| `s` | SCP | Save cursor position |
| `u` | RCP | Restore cursor position |

### Private Modes (DECSET/DECRST)

The `?` prefix in the parameter string signals a private mode. The `applyPrivateMode` function handles:

| Code | Effect |
| --- | --- |
| `1` | Application cursor keys on/off |
| `9` | X10 mouse tracking on/off |
| `47` / `1047` | Alternate screen buffer on/off (no cursor save/restore) |
| `1000` | Normal mouse button tracking on/off |
| `1002` | Button-event mouse tracking on/off |
| `1003` | Any-event mouse tracking on/off |
| `1005` | UTF-8 mouse encoding on/off |
| `1006` | SGR mouse encoding on/off |
| `1015` | URXVT mouse encoding on/off |
| `1048` | Save/restore cursor (without screen switch) |
| `1049` | Save cursor + switch to/from alternate screen (clears alt screen on enter) |
| `2004` | Bracketed paste mode on/off |

### SGR Codes

`applySgr` processes SGR parameter lists:

| Range | Effect |
| --- | --- |
| `0` | Reset all attributes and colors |
| `1`–`9`, `21`–`29` | Set/clear text attributes (bold, dim, italic, underline, blink, inverse, hidden, strikethrough) |
| `30`–`37` / `39` | Set named foreground color / default foreground |
| `38` | Extended foreground: `38;5;n` (256-color index) or `38;2;r;g;b` (24-bit RGB) |
| `40`–`47` / `49` | Set named background color / default background |
| `48` | Extended background: same sub-parameter forms as `38` |
| `53` / `55` | Overline on/off |
| `58` / `59` | Underline color / reset underline color |
| `90`–`97` | Bright foreground colors |
| `100`–`107` | Bright background colors |

## oscByte And OSC Handling

OSC strings (`ESC ]`) consist of a numeric command, `;`, and a payload, terminated by one of:

- `BEL` (0x07)
- `ESC \` (two bytes: 0x1b then `\`)
- `CAN` (0x18) or `SUB` (0x1a)

The `osc_saw_esc` flag handles the two-byte ST terminator: when `ESC` is seen inside an OSC, the flag is set; if the next byte is `\`, the sequence ends; if it is anything else, processing continues.

The grid layer currently consumes all OSC payloads without acting on them. Title, hyperlink, clipboard, and other OSC commands are silently discarded. This is intentional — OSC 777 shell-integration trust gating is open work tracked in `ALPHA_TASKS.md`.

## Scroll Regions (DECSTBM)

`Grid.scroll_top` and `Grid.scroll_bottom` are 0-based inclusive row indices, set by CSI `r`. The default region is the full screen (0 to rows−1).

Line feed and reverse index respect the region boundaries. When scrolling up within the region:

- If the region is full-screen, the top line is moved to the scrollback buffer (primary screen only, capped at `max_scrollback` which defaults to 10,000 lines).
- If the region is smaller than the screen, lines shift within the region and no scrollback entry is written.

`resize` resets the scroll region to the full new screen dimensions and also resets parser state.

## Primary And Alternate Screen Buffers

`Grid` maintains two `BufferState` structs (primary and alternate) with independent cell grids and cursor positions. Switching between them is triggered by private modes `1047`, `1049`, and `1048`. Scrollback history is only captured on the primary screen.

## How To Add A New Escape Sequence

1. Identify the sequence type: ESC-only (two bytes), CSI (ESC `[` params final), or OSC.

2. For ESC-only sequences, add a case in `escapeByte`:
   ```zig
   '<byte>' => {
       // implement behavior
       self.parse_state = .ground;
   },
   ```

3. For CSI sequences, add a case in `applyCsi` matching on the final byte. Parse parameters from `params` using the existing `parseParam` / `parseParams` helpers in the file.

4. For new private modes, add a case in `applyPrivateMode`.

5. Add a conformance test in `terminal.zig`:
   ```zig
   test "sequence description" {
       const alloc = std.testing.allocator;
       var grid = try Grid.init(alloc, 80, 24, 1000);
       defer grid.deinit(alloc);
       try grid.feed("\x1b[<params><final>");
       try std.testing.expectEqual(@as(u32, expected), grid.cursor_x);
   }
   ```
   The test should also verify byte-split invariance: feed the sequence in two chunks split at each possible byte boundary and assert the same result each time.

6. Run `zig build test` to confirm all tests pass.

## Open Work

The following VT areas are tracked as open in [ALPHA_TASKS.md](../vision/alpha-tasks.md):

- Origin mode (DECOM)
- Soft-wrap tracking
- Resize reflow
- Combining marks and grapheme clusters
- Emoji width and ambiguous-width policy
- Full xterm/SGR mouse button reports
- OSC 777 trust boundary
- A separate harness binary and renderer/grid snapshot tests
