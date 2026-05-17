# OSC 8 Hyperlinks

How `ESC ] 8 ; params ; URL ST` hyperlink sequences integrate into ZiggyZag's terminal grid and Windows renderer. The grid currently consumes OSC payloads without acting on them (see [`reference/terminal-parser.md`](terminal-parser.md), section "oscByte And OSC Handling"). This spec adds a minimal, safe activation path for OSC 8 specifically — link-aware cells, a renderer underline, and a click handler — without expanding the OSC 0/1/2/777 surfaces.

OSC 8 is the de-facto standard introduced by VTE in 2017 and adopted by WezTerm, iTerm2, kitty, foot, gnome-terminal, and others [1]. The canonical syntax is:

```
ESC ] 8 ; <params> ; <URI> ST
```

Where `<params>` is zero or more colon-separated `key=value` pairs (currently only `id=...` is defined by the spec) and `ST` is either `BEL` (0x07) or `ESC \` (0x1b 0x5c). An empty URI (`ESC ] 8 ; ; ST`) closes the current hyperlink [1]. The grid already consumes both terminators correctly; this spec adds payload parsing.

## 1. Cell-model change

A `Cell` gains one optional field. The link payload itself does not live on the cell — only an index into a per-grid table — so the common case (no link) costs four bytes per cell and the linked case still amortises one heap allocation per distinct URL.

```zig
pub const Cell = struct {
    ch: u8 = ' ',
    codepoint: u21 = ' ',
    width: CellWidth = .narrow,
    style: Style = .{},
    hyperlink_id: ?u32 = null,   // new — index into Grid.hyperlinks
};
```

The grid owns the link table:

```zig
pub const Hyperlink = struct {
    params: []const u8,   // the verbatim "id=foo:..." string, may be ""
    target: []const u8,   // the resolved URL (already scheme-validated)
};

// On Grid:
hyperlinks: std.ArrayList(Hyperlink) = .empty,
current_hyperlink_id: ?u32 = null,  // applied to printed cells, like current_style
```

`hyperlinks` is append-only within a buffer lifetime; deduplication is a future optimisation. `Grid.deinit` frees each entry's owned slices. The alternate screen shares the same table — links survive screen switches, which matches xterm behaviour.

Resize, hard reset (`ESC c`), and the existing `resetParser` all clear `current_hyperlink_id` but preserve the table; cells in the scrollback that point at it remain valid.

## 2. Parser change

A new branch in `oscByte` recognises the `8;` prefix. The grid already accumulates an OSC string until `BEL`/`ESC\`/`CAN`/`SUB`; we just stop discarding it for OSC 8.

```
ESC ] 8 ; params ; URL ST
```

decomposes into command (`8`), params, and URL. The parser splits on the first two semicolons and runs the URL through `validateLinkTarget` (section 4). On accept, it appends a `Hyperlink` to the table, stores the new id in `current_hyperlink_id`, and continues. On reject, the sequence is consumed without setting an id — the grid simply renders the inner text as plain cells.

The reset form `ESC ] 8 ; ; ST` is the empty-URL case: it sets `current_hyperlink_id = null` without touching the table.

```zig
fn applyOsc(self: *Grid, payload: []const u8) void {
    // payload is everything between "]" and the ST terminator
    if (std.mem.startsWith(u8, payload, "8;")) {
        const rest = payload[2..];
        const sep = std.mem.indexOfScalar(u8, rest, ';') orelse return;
        const params = rest[0..sep];
        const url = rest[sep + 1 ..];
        if (url.len == 0) {
            self.current_hyperlink_id = null;
            return;
        }
        if (!validateLinkTarget(url)) return;
        const id = self.appendHyperlink(params, url) catch return;
        self.current_hyperlink_id = id;
    }
    // OSC 0/1/2/777 etc. continue to be consumed silently as before.
}
```

The 256-byte OSC buffer cap from `csi_buffer_cap` applies; an overlong URL is dropped. This matches the existing `esc_overflow` discipline.

## 3. Renderer change

In `apps/desktop/src/windows_app.zig`, `paintCellRun` already groups cells by `Style`. The grouping key extends to include `hyperlink_id`, so adjacent linked cells coalesce into one underlined run.

When a run has a non-null `hyperlink_id`:

1. Force `underline = true` on the run's style (without mutating the original cell — overlay only).
2. Use `theme.accent` for the foreground when the cell's own foreground is default; preserve explicit per-cell SGR colors otherwise.
3. Record the screen-space rectangle of the run in a per-pane `link_hits` list, keyed by id.

```zig
// inside paintCellRun, when building each run:
const link_id = cells[col].hyperlink_id;
var paint_style = style;
if (link_id != null) paint_style.underline = true;
// ... existing FillRect / TextOutW ...
if (link_id) |id| {
    self.recordLinkHit(.{
        .id = id,
        .rect = run_rect,
        .pane = self.active_pane_index,
    });
}
```

On `WM_LBUTTONUP`, the app looks up the hit by `(x, y)`, fetches the target from the grid's `hyperlinks` table, and calls Windows `ShellExecuteW` with `lpOperation = L"open"` and the validated URL.

```zig
extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND,
    op: LPCWSTR,
    file: LPCWSTR,
    params: ?LPCWSTR,
    dir: ?LPCWSTR,
    show: i32,
) callconv(.winapi) HINSTANCE;

fn openHyperlink(self: *App, url: []const u8) void {
    var wide: [2048]u16 = undefined;
    const len = utf8ToUtf16Z(url, &wide) catch return;
    _ = ShellExecuteW(self.hwnd, L("open"), wide[0..len].ptr, null, null, 1);
}
```

Modifier-key requirement (Ctrl+click vs plain click) is a deferred UX decision — see the bottom section.

## 4. Security

Terminal hyperlinks are an attack surface. The 2024 iTerm2 / Hyper CVEs demonstrated that letting an OSC 8 sequence pass arbitrary URL schemes through to the OS handler can lead to code execution via `ssh://`, `x-man-page://`, `file://` with crafted paths, and similar [2]. WezTerm restricts schemes to an allowlist and validates `file://` targets before launching [3]. ZiggyZag does the same, more strictly:

- `http://` and `https://` — always allowed.
- `file://` — allowed only if the path is inside the user's home directory (`%USERPROFILE%` on Windows) OR inside the current workspace root (the desktop's `profile.cwd`, when set). Symbolic links are not resolved before the check; a `..` segment causes rejection.
- Every other scheme — rejected. This includes `ssh://`, `mailto:`, `vscode://`, `javascript:`, and any unknown scheme. A future `desktop.conf` key (`hyperlink.allow_schemes`) can opt in to additional schemes when the threat model is understood; the default is the closed set above.

Validation runs in the grid (`validateLinkTarget`) before a `Hyperlink` ever enters the table. That way the renderer never sees an unsafe id and a copy-paste of the visible text cannot smuggle a link into another pane.

```zig
fn validateLinkTarget(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "http://")) return true;
    if (std.mem.startsWith(u8, url, "https://")) return true;
    if (std.mem.startsWith(u8, url, "file://")) return isAllowedFilePath(url[7..]);
    return false;
}
```

URLs are required to be ASCII 0x20–0x7e per the OSC 8 spec [1]; non-ASCII bytes fail validation. The 256-byte payload cap already bounds the worst case.

## 5. Five test cases

```zig
// 1. Basic link is registered and applied to following cells.
test "osc8: link is set on cells between open and close" {
    var grid = try Grid.init(std.testing.allocator, 16, 1);
    defer grid.deinit();
    grid.feed("\x1b]8;;https://example.com\x1b\\AB\x1b]8;;\x1b\\C");
    try std.testing.expect(grid.cells[0].hyperlink_id != null);
    try std.testing.expect(grid.cells[1].hyperlink_id != null);
    try std.testing.expectEqual(grid.cells[0].hyperlink_id, grid.cells[1].hyperlink_id);
    try std.testing.expectEqual(@as(?u32, null), grid.cells[2].hyperlink_id);
}
```

```zig
// 2. BEL terminator works identically to ESC \.
test "osc8: BEL-terminated open and close" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("\x1b]8;;https://a.test\x07X\x1b]8;;\x07Y");
    try std.testing.expect(grid.cells[0].hyperlink_id != null);
    try std.testing.expectEqual(@as(?u32, null), grid.cells[1].hyperlink_id);
}
```

```zig
// 3. Disallowed scheme is rejected; cells remain unlinked.
test "osc8: ssh scheme is rejected" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("\x1b]8;;ssh://attacker\x1b\\Z");
    try std.testing.expectEqual(@as(?u32, null), grid.cells[0].hyperlink_id);
    try std.testing.expectEqual(@as(u8, 'Z'), grid.cells[0].ch);
    try std.testing.expectEqual(@as(usize, 0), grid.hyperlinks.items.len);
}
```

```zig
// 4. Split across feed boundaries: the link still resolves.
test "osc8: open sequence split across feeds resumes correctly" {
    var grid = try Grid.init(std.testing.allocator, 8, 1);
    defer grid.deinit();
    grid.feed("\x1b]8;;https://exa");
    grid.feed("mple.com\x1b\\Q");
    try std.testing.expect(grid.cells[0].hyperlink_id != null);
}
```

```zig
// 5. file:// outside the home/workspace root is rejected.
test "osc8: file:// outside allowed roots is rejected" {
    var grid = try Grid.init(std.testing.allocator, 16, 1);
    defer grid.deinit();
    grid.feed("\x1b]8;;file:///etc/passwd\x1b\\!");
    try std.testing.expectEqual(@as(?u32, null), grid.cells[0].hyperlink_id);
}
```

## What this doc does not specify

- Click semantics: plain click vs Ctrl+click vs middle-click. The renderer records hits unconditionally; the desktop layer chooses the gesture. Default proposal is Ctrl+click on Windows, deferred until UX review.
- Hover affordances. The accent underline is paint-time; mouse hover state (e.g. brighter accent, status-bar URL preview) is intentionally out of scope.
- Copy behaviour: when a user selects text that includes a linked region, is the URL preserved in the OS clipboard's HTML flavor? Deferred — the current clipboard path only emits plain text.
- macOS and Linux renderers. `posix_app.zig` does not yet render its own grid; when it does, it will get an equivalent path with `xdg-open` or `open(1)` in place of `ShellExecuteW`.
- Deduplication of the per-grid `hyperlinks` table. The current spec appends unconditionally; a long-running session that emits many duplicate URLs will grow the table. Deferred until measurement shows it matters.

## Sources

[1] Egmont Koblinger, "Hyperlinks in Terminal Emulators" — https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda. Canonical syntax, the `id=` parameter, and the 32–126 ASCII restriction on URLs.
[2] Vin01, "Abusing url handling in iTerm2 and Hyper for code execution" (2024) — https://vin01.github.io/piptagole/escape-sequences/iterm2/hyper/url-handlers/code-execution/2024/05/21/arbitrary-url-schemes-terminal-emulators.html. The concrete attack pattern that drives the scheme allowlist.
[3] WezTerm escape-sequence reference — https://wezterm.org/escape-sequences.html. Precedent for scheme restriction and the `http(s)` + bounded `file://` policy.
