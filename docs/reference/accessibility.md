# Theme accessibility audit

WCAG 2.1 defines a contrast ratio between two colors as `(L_lighter + 0.05) / (L_darker + 0.05)`, where each `L` is the relative luminance of the sRGB color after gamma decoding. The scale runs from `1:1` (no contrast) to `21:1` (black on white). WCAG AA requires `>= 4.5:1` for normal body text and `>= 3:1` for large text or non-text UI. ZiggyZag targets AA across every shipped theme: **4.5:1** for `foreground/background`, **4.5:1** for `accent/background` (used for prompts and links), **4.5:1** for `ansi[1]` red on background (error visibility), and **3:1** for `muted/background` since `muted` is documented as secondary text. AAA (`7:1` normal, `4.5:1` large) is a stretch goal, not a release gate.

Audited **20 themes**: 11 pass AA on all four pairs, 9 need work.

## Summary

| Theme | fg/bg | accent/bg | muted/bg | red/bg | Status |
| --- | --- | --- | --- | --- | --- |
| Ziggy (`ziggy`) | 16.35:1 | 12.12:1 | 3.70:1 | 5.88:1 | PASS |
| Catppuccin Mocha (`catppuccin-mocha`) | 11.34:1 | 7.79:1 | 7.37:1 | 7.08:1 | PASS |
| Tokyo Night (`tokyo-night`) | 10.59:1 | 6.79:1 | 8.10:1 | 6.46:1 | PASS |
| Dracula (`dracula`) | 13.36:1 | 5.90:1 | 3.03:1 | 4.53:1 | PASS |
| Nord (`nord`) | 9.25:1 | 6.24:1 | 4.64:1 | 3.05:1 (fail) | NEEDS WORK |
| Rose Pine (`rose-pine`) | 13.39:1 | 8.43:1 | 5.48:1 | 6.07:1 | PASS |
| Gruvbox Dark (`gruvbox-dark`) | 10.75:1 | 5.84:1 | 4.02:1 | 2.69:1 (fail) | NEEDS WORK |
| Everforest Dark (`everforest-dark`) | 7.60:1 | 6.42:1 | 5.27:1 | 4.68:1 | PASS |
| Kanagawa Wave (`kanagawa-wave`) | 11.26:1 | 5.94:1 | 3.33:1 | 3.22:1 (fail) | NEEDS WORK |
| Solarized Dark (`solarized-dark`) | 4.75:1 | 4.08:1 (fail) | 2.79:1 (fail) | 3.25:1 (fail) | NEEDS WORK |
| One Dark (`one-dark`) | 6.57:1 | 5.92:1 | 2.32:1 (fail) | 4.38:1 (fail) | NEEDS WORK |
| Paper (`paper`) | 13.62:1 | 5.44:1 | 4.23:1 | 4.12:1 (fail) | NEEDS WORK |
| Ember (`ember`) | 15.03:1 | 7.86:1 | 6.09:1 | 6.06:1 | PASS |
| Catppuccin Frappé (`catppuccin-frappe`) | 8.06:1 | 5.34:1 | 6.75:1 | 4.65:1 | PASS |
| Catppuccin Macchiato (`catppuccin-macchiato`) | 9.92:1 | 6.57:1 | 8.17:1 | 5.96:1 | PASS |
| Tokyo Night Storm (`tokyo-night-storm`) | 9.02:1 | 5.78:1 | 6.00:1 | 5.51:1 | PASS |
| Ayu Dark (`ayu-dark`) | 10.27:1 | 10.13:1 | 2.84:1 (fail) | 6.34:1 | NEEDS WORK |
| Catppuccin Latte (`catppuccin-latte`) | 7.06:1 | 4.34:1 (fail) | 4.37:1 | 4.80:1 | NEEDS WORK |
| Solarized Light (`solarized-light`) | 4.13:1 (fail) | 3.41:1 (fail) | 2.48:1 (fail) | 4.29:1 (fail) | NEEDS WORK |
| GitHub Light (`github-light`) | 14.67:1 | 5.42:1 | 4.82:1 | 4.57:1 | PASS |

## Needs work

### Nord (`nord`)

- background `#2e3440`, foreground `#d8dee9`, accent `#88c0d0`, muted `#81a1c1`, ansi[1] `#bf616a`
- `ansi[1] red/background` is 3.05:1 (`#bf616a` on `#2e3440`), AA target 4.5:1

### Gruvbox Dark (`gruvbox-dark`)

- background `#282828`, foreground `#ebdbb2`, accent `#fe8019`, muted `#928374`, ansi[1] `#cc241d`
- `ansi[1] red/background` is 2.69:1 (`#cc241d` on `#282828`), AA target 4.5:1

### Kanagawa Wave (`kanagawa-wave`)

- background `#1f1f28`, foreground `#dcd7ba`, accent `#7e9cd8`, muted `#727169`, ansi[1] `#c34043`
- `ansi[1] red/background` is 3.22:1 (`#c34043` on `#1f1f28`), AA target 4.5:1

### Solarized Dark (`solarized-dark`)

- background `#002b36`, foreground `#839496`, accent `#268bd2`, muted `#586e75`, ansi[1] `#dc322f`
- `accent/background` is 4.08:1 (`#268bd2` on `#002b36`), AA target 4.5:1
- `muted/background` is 2.79:1 (`#586e75` on `#002b36`), AA target 3.0:1
- `ansi[1] red/background` is 3.25:1 (`#dc322f` on `#002b36`), AA target 4.5:1

### One Dark (`one-dark`)

- background `#282c34`, foreground `#abb2bf`, accent `#61afef`, muted `#5c6370`, ansi[1] `#e06c75`
- `muted/background` is 2.32:1 (`#5c6370` on `#282c34`), AA target 3.0:1
- `ansi[1] red/background` is 4.38:1 (`#e06c75` on `#282c34`), AA target 4.5:1

### Paper (`paper`)

- background `#f8f6ef`, foreground `#262925`, accent `#2f6f62`, muted `#73776d`, ansi[1] `#b95c50`
- `ansi[1] red/background` is 4.12:1 (`#b95c50` on `#f8f6ef`), AA target 4.5:1

### Ayu Dark (`ayu-dark`)

- background `#0b0e14`, foreground `#bfbdb6`, accent `#e6b450`, muted `#565b66`, ansi[1] `#ea6c73`
- `muted/background` is 2.84:1 (`#565b66` on `#0b0e14`), AA target 3.0:1

### Catppuccin Latte (`catppuccin-latte`)

- background `#eff1f5`, foreground `#4c4f69`, accent `#1e66f5`, muted `#6c6f85`, ansi[1] `#d20f39`
- `accent/background` is 4.34:1 (`#1e66f5` on `#eff1f5`), AA target 4.5:1

### Solarized Light (`solarized-light`)

- background `#fdf6e3`, foreground `#657b83`, accent `#268bd2`, muted `#93a1a1`, ansi[1] `#dc322f`
- `foreground/background` is 4.13:1 (`#657b83` on `#fdf6e3`), AA target 4.5:1
- `accent/background` is 3.41:1 (`#268bd2` on `#fdf6e3`), AA target 4.5:1
- `muted/background` is 2.48:1 (`#93a1a1` on `#fdf6e3`), AA target 3.0:1
- `ansi[1] red/background` is 4.29:1 (`#dc322f` on `#fdf6e3`), AA target 4.5:1

## Methodology

Ratios are computed by `scripts/audit_contrast.py`, which parses `apps/desktop/src/theme.zig` with a small regex pass (no Zig toolchain needed) and applies the WCAG 2.1 relative-luminance formula. Re-run it after any theme change:

```sh
python scripts/audit_contrast.py --write-report
```

The script uses only the Python standard library and rewrites this file in place when `--write-report` is passed.

Last audit: 2026-05-17 against `apps/desktop/src/theme.zig` revision `51e0a2b`. Re-run via `python scripts/audit_contrast.py --write-report`.
