# Render attributes (SGR) on the native window

The terminal parser (`apps/desktop/src/terminal.zig`) records every SGR
attribute it understands onto each cell's `Style`. The native hosts then draw
them. This note covers how the macOS Cocoa host
(`apps/desktop/src/macos_app.zig`) renders each attribute and how to eyeball
them. The Windows host (`windows_app.zig`) renders the same set via GDI.

## Supported attributes

| SGR | Attribute | macOS rendering |
| --- | --- | --- |
| `1` | bold | foreground brightened (+0.12 per channel) |
| `2` | dim | foreground scaled to 60% |
| `3` | italic | drawn with Menlo-Italic (falls back to regular if absent) |
| `4` | underline | thin filled rule just below the baseline |
| `21` | double underline | two stacked rules below the baseline |
| `7` | inverse | foreground/background swapped before other attrs |
| `8` | hidden | glyph omitted; background + decorations still draw |
| `9` | strikethrough | thin rule through the cell's vertical middle |
| `53` | overline | thin rule along the cell's top edge |
| `58` | underline color | overrides the underline rule color only |
| `30–37`, `90–97` | named fg | 16-color ANSI palette |
| `40–47`, `100–107` | named bg | 16-color ANSI palette |
| `38;5;n` / `48;5;n` | 256-color | 16 ANSI + 6×6×6 cube + 24-step grayscale |
| `38;2;r;g;b` / `48;2;r;g;b` | truecolor | direct 24-bit RGB |

Decorations are drawn as thin filled rectangles (no CoreGraphics stroke API is
needed) and span both columns of a wide (CJK/emoji) cell.

## Eyeballing it

Run the native window and paste this corpus (each line exercises one group):

```sh
printf '\033[1mbold\033[0m \033[2mdim\033[0m \033[3mitalic\033[0m\n'
printf '\033[4munderline\033[0m \033[21mdouble\033[0m \033[9mstrike\033[0m \033[53moverline\033[0m\n'
printf '\033[7minverse\033[0m \033[4;58;5;196munderline-red\033[0m\n'
printf '\033[38;5;208m256-orange\033[0m \033[48;5;22m256-bg-green\033[0m\n'
printf '\033[38;2;255;105;180mtruecolor-pink\033[0m \033[48;2;30;30;90mtruecolor-bg\033[0m\n'
```

Each should render distinctly. 256-color and truecolor resolve identically on
macOS and Windows (shared cube/grayscale math).

## Known gaps

- **Blink (`5`/`6`)** is parsed and stored but not animated.
- **Color emoji** needs CoreText font fallback (Menlo has no emoji glyph); see
  the S9 Unicode notes. Box-drawing, accents, and CJK render today.
