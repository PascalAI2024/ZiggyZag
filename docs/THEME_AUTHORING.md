# Theme Authoring Guide

ZiggyZag desktop themes are compile-time Zig constants defined in `apps/desktop/src/theme.zig`. Adding or changing a theme means editing that file, adding your `Theme` constant to the `themes` array, and rebuilding. There is no runtime theme config file to edit.

## Color Type

```zig
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};
```

Colors are 24-bit RGB. `Color.fromHex` parses `"#rrggbb"` or `"rrggbb"` (the leading `#` is optional). Colors format as `"#rrggbb"` via their `format` method.

## Theme Struct

```zig
pub const Theme = struct {
    id:         []const u8,    // slug used for config lookup and cycling
    name:       []const u8,    // human-readable display name
    background: Color,
    foreground: Color,
    cursor:     Color,
    accent:     Color,
    panel:      Color,
    muted:      Color,
    ansi:       [16]Color,
};
```

| Field | Purpose |
| --- | --- |
| `id` | Slug used by `byName`, `maybeByName`, and `next`; stored in config; used for cycling |
| `name` | Display name shown in the UI and returned by `tools/list` |
| `background` | Default cell background |
| `foreground` | Default cell foreground / text |
| `cursor` | Cursor block color |
| `accent` | Highlight and selection color |
| `panel` | Panel and status-bar background |
| `muted` | Dimmed or secondary text |
| `ansi[16]` | The 16 ANSI palette entries |

### ANSI Palette Order

The `ansi` array maps to the standard ANSI/xterm palette:

| Index | Meaning |
| --- | --- |
| 0 | Black (normal) |
| 1 | Red (normal) |
| 2 | Green (normal) |
| 3 | Yellow (normal) |
| 4 | Blue (normal) |
| 5 | Magenta (normal) |
| 6 | Cyan (normal) |
| 7 | White (normal) |
| 8 | Bright black (dark gray) |
| 9 | Bright red |
| 10 | Bright green |
| 11 | Bright yellow |
| 12 | Bright blue |
| 13 | Bright magenta |
| 14 | Bright cyan |
| 15 | Bright white |

## Builder Methods

Each `Theme` provides builder methods that return a modified copy with one field changed. These are useful when defining a variant of an existing theme:

```zig
const my_variant = ziggy.withBackground(Color.fromHex("#1a1a2e"))
                        .withAccent(Color.fromHex("#e040fb"));
```

Available builders: `withBackground`, `withForeground`, `withCursor`, `withAccent`, `withPanel`, `withMuted`.

## Built-In Presets

All 13 presets are compile-time constants in `theme.zig`. The `themes` array holds all of them.

| ID | Display Name |
| --- | --- |
| `ziggy` | Ziggy |
| `catppuccin-mocha` | Catppuccin Mocha |
| `tokyo-night` | Tokyo Night |
| `dracula` | Dracula |
| `nord` | Nord |
| `rose-pine` | Rose Pine |
| `gruvbox-dark` | Gruvbox Dark |
| `everforest-dark` | Everforest Dark |
| `kanagawa-wave` | Kanagawa Wave |
| `solarized-dark` | Solarized Dark |
| `one-dark` | One Dark |
| `paper` | Paper |
| `ember` | Ember |

## Theme Lookup And Cycling

- `maybeByName(name)`: iterates `themes[]`, matches on `id` or `name` via `themeNameMatches`. Returns `null` if no match is found.
- `byName(name)`: calls `maybeByName`; falls back to the `ziggy` preset if no match.
- `next(current_id)`: finds the current theme by `id` and returns `themes[(index + 1) % themes.len]`, cycling through all presets.

### themeNameMatches

Matching is case-insensitive and separator-insensitive. Space, hyphen, and underscore are all treated as equivalent separators and are skipped simultaneously at both string pointers during comparison. This means `"tokyo-night"`, `"Tokyo Night"`, `"tokyo_night"`, and `"TokyoNight"` all match the same preset.

## How To Add A New Theme Preset

1. Open `apps/desktop/src/theme.zig`.

2. Define your colors and add a `const` for the new theme:
   ```zig
   const my_theme = Theme{
       .id         = "my-theme",
       .name       = "My Theme",
       .background = Color.fromHex("#1a1b26"),
       .foreground = Color.fromHex("#c0caf5"),
       .cursor     = Color.fromHex("#bb9af7"),
       .accent     = Color.fromHex("#7aa2f7"),
       .panel      = Color.fromHex("#16161e"),
       .muted      = Color.fromHex("#565f89"),
       .ansi       = .{
           Color.fromHex("#15161e"), // 0 black
           Color.fromHex("#f7768e"), // 1 red
           // ... fill remaining 14 entries
           Color.fromHex("#c0caf5"), // 15 bright white
       },
   };
   ```

3. Append your constant to the `themes` array (near the bottom of `theme.zig`):
   ```zig
   pub const themes = [_]Theme{
       ziggy,
       catppuccin_mocha,
       // ... existing presets ...
       my_theme,        // add here
   };
   ```

4. Run `zig build test` to confirm the build succeeds and no existing tests are broken.

5. Run `zig build run-desktop` and cycle themes with Ctrl+Shift+T (or the command palette) to visually verify your theme appears and cycles correctly.

6. Verify that `byName("my-theme")` and `byName("My Theme")` both resolve to your preset (you can add a short `test` block in `theme.zig` for this).

## Notes

- `Color.fromHex` panics on malformed hex strings during compilation (these are comptime constants). If you get a compile error, check that all hex strings are exactly 6 hex digits with an optional leading `#`.
- The `themes` array length is compiled in. The `next` function uses `themes.len`, so adding a preset to the array automatically includes it in cycling without any other changes.
- Theme IDs are matched in a separator-insensitive way, so prefer hyphens for readability in the `id` field (e.g. `"my-theme"` rather than `"my_theme"` or `"mytheme"`).
