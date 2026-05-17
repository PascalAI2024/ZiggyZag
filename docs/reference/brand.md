# Brand & Visual Identity

This document is the source of truth for what ZiggyZag looks like and how it sounds. Every screenshot, README, landing page, and terminal theme references the tokens here.

## The mark

The logo is an angular double-Z carved through a terminal panel. The Z form is built from straight strokes that change direction sharply — the "zig" and "zag" of the name. The gradient travels from a Zig-orange `#F7A41D` (a nod to the language) through teal `#35D0BA` (signal, life) to violet `#8B5CF6` (calm, depth). The panel evokes a window chrome. A green arrow on the bottom-left echoes the shell prompt.

The mark lives at `assets/ziggyzag-logo.svg`. A horizontal lockup with wordmark is at `assets/ziggyzag-wordmark.svg` (created in this push). Both are MIT-licensed with the rest of the project.

**Clear space.** Reserve at least 1/8 of the mark's height as clear space on every side. Do not crop, recolor outside the documented tokens, or place over busy photography.

**Minimum size.** 24 px square for the mark, 120 px wide for the wordmark.

## Color tokens

The color system uses the *Ziggy* theme as the canonical reference. Every other built-in theme is a re-skin against the same semantic slots.

### Semantic tokens

| Token | Hex | Use |
| --- | --- | --- |
| `--zz-bg` | `#111315` | Window background, page background on dark surfaces |
| `--zz-bg-panel` | `#191C1D` | Inset panels, code blocks, status bars |
| `--zz-fg` | `#EEF2E2` | Primary text on dark |
| `--zz-fg-muted` | `#6A7072` | Secondary text, captions, separators |
| `--zz-accent` | `#9BE28F` | Primary accent — links, focus rings, highlights |
| `--zz-accent-strong` | `#B6F09C` | Hover/active accent, cursor |
| `--zz-warn` | `#F2CD76` | Warnings, slow-command annotations |
| `--zz-danger` | `#E66A6A` | Errors, destructive actions |
| `--zz-info` | `#7AB7FF` | Informational chips, links to docs |
| `--zz-violet` | `#CF9BFF` | Reserved for the agent surface |

### Brand gradient

For hero marks only, never for body text or large fills:

```
linear-gradient(135deg, #F7A41D 0%, #35D0BA 52%, #8B5CF6 100%)
```

The same stops appear in the logo. Use sparingly — once per page, on the largest element.

### Light theme (`paper`)

| Token | Hex |
| --- | --- |
| `--zz-bg` | `#F8F6EF` |
| `--zz-bg-panel` | `#EBE7DC` |
| `--zz-fg` | `#262925` |
| `--zz-fg-muted` | `#73776D` |
| `--zz-accent` | `#2F6F62` |

A light landing page should use `paper`; a dark landing page should use `ziggy`. Do not mix tokens across themes in the same surface.

## Typography

Two families. No third.

**Display & UI:** [Inter](https://rsms.me/inter/) — `Inter, ui-sans-serif, system-ui, sans-serif`. Weights used: 400, 500, 600, 700. Inter is the default GitHub README rendering, gives us continuity from repo page → landing → screenshots.

**Code & terminal:** [Cascadia Mono](https://github.com/microsoft/cascadia-code) — `"Cascadia Mono", "JetBrains Mono", Menlo, Consolas, monospace`. Already the default in `desktop.conf`. Cascadia ships with Windows; the fallbacks cover macOS and Linux without an install.

**Type scale (px):**

| Token | Size | Line-height | Weight | Use |
| --- | --- | --- | --- | --- |
| `t-hero` | 64 | 1.05 | 700 | Hero headline |
| `t-h1` | 40 | 1.15 | 700 | Section heads |
| `t-h2` | 28 | 1.25 | 600 | Sub-section heads |
| `t-h3` | 20 | 1.35 | 600 | Card titles |
| `t-body` | 16 | 1.6 | 400 | Body copy |
| `t-meta` | 13 | 1.45 | 500 | Captions, badges |
| `t-mono` | 14 | 1.5 | 400 | Inline code, terminal |

## Spacing & layout

A 4-px base unit. Common values: 4, 8, 12, 16, 24, 32, 48, 64, 96. No magic numbers in stylesheets — every spacing value is a multiple of 4. Border radii: 6 (chips), 12 (cards), 24 (panels), 999 (pills).

Maximum content width on the landing page: 1100 px. Hero may bleed full-width with a centered 1100 px inner column.

## Voice

The voice is calm, dry, technical, occasionally funny. Never breathless. Never apologetic. Read everything aloud — if it sounds like a marketing person wrote it, rewrite it.

Three rules:

1. **Earn every adjective.** "Fast" is earned by a benchmark, "secure" is earned by a sandbox spec, "modern" is earned by a feature list. Adjectives without earning get cut.
2. **Honesty over enthusiasm.** "Windows native, macOS/Linux launcher" is better than "Cross-platform!" with an asterisk somewhere.
3. **No emoji in code or terminal contexts.** The README and landing page may use a small set (✓ ✗ → ↳) sparingly. Never in the terminal itself.

## Imagery

**Screenshots.** Use the desktop host at 1440×900 with `ziggy` theme on dark surfaces and `paper` on light. Show real commands and real output. Faked screenshots are forbidden. Include a 1-pixel `#2B3447` border around every screenshot.

**Hero asset.** `assets/hero.svg` (built in this push). Animated SVG showing a typewriter effect demonstrating theme cycling. Roughly 6 seconds, loops. Used on the landing page hero and in the README.

**Demo GIF.** Captured from a real session at 1280×720, 24fps, ≤2 MB. Built later — recommend Peek (Linux), Kap (macOS), ScreenToGif (Windows). Place at `assets/demo.gif`. Reference but do not require for the first portfolio sweep.

## File map

| Asset | Path | Status |
| --- | --- | --- |
| Square logo | `assets/ziggyzag-logo.svg` | Exists |
| Wordmark lockup | `assets/ziggyzag-wordmark.svg` | Created in this push |
| Hero animation | `assets/hero.svg` | Created in this push |
| Theme gallery composite | `assets/theme-gallery.svg` | Created in this push |
| Demo GIF | `assets/demo.gif` | TODO — record from real session |
| Favicon (32×32) | `assets/favicon.png` | TODO — export from logo |
| Open Graph image | `assets/og.png` | TODO — 1200×630 hero composite |

## Quick check

Before merging anything user-facing, run through this:

- Colors used appear in this document.
- Type sizes match the scale.
- Spacing is a multiple of 4.
- Voice rules are followed.
- Logo has its clear space.
- Light/dark variants exist if the surface supports both.

A failing check is not a blocker — it is a conversation. If the project needs a new token, add it here first, then ship.
