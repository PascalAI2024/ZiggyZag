# Sessions, Tabs, Panes

A `Session` abstraction that unifies the desktop host's tabs and splits behind one type hierarchy. This is a Wave 5 deliverable per [`waves.md`](../vision/waves.md). The desktop currently exposes a flat `Pane` array (`apps/desktop/src/windows_app.zig`, line 425), capped at `MAX_PANES = 6` (line 107), each pane owning its own PTY, terminal grid, scrollback buffer, and status state. Wave 5 adds tabs. Tabs are conceptually "many groups of panes" — the same primitive at a different nesting level. This doc names that primitive and pins down the invariants.

The mental model is borrowed from WezTerm [1]: **Window → Tab → Pane**, where each level owns the lifecycle of the level below. iTerm2 [2] and kitty [3] use similar hierarchies; Ghostty [4] is close but currently flattens tabs into Windows for technical reasons unrelated to ours. We follow WezTerm.

## 1. Type hierarchy

```zig
pub const Window = struct {
    hwnd: HWND,
    tabs: std.ArrayList(*Tab),
    active_tab: usize,
    position: WindowPosition,  // for persistence
    ...
};

pub const Tab = struct {
    id: u32,                  // monotonic, unique per Window lifetime
    title: [128]u8,
    title_len: usize,
    root: SplitNode,          // binary tree, leaf nodes are Panes
    focused_leaf: *SplitNode,
    ...
};

pub const Pane = struct {     // existing struct, mostly unchanged
    grid: terminal.Grid,
    pseudoconsole: ?HPCON,
    status: Status,
    ...
};
```

`Window` owns its `Tab` slice. `Tab.deinit` walks `root` post-order and frees every `Pane`. `Pane.deinit` closes its PTY handles and frees grid memory. Closing the last `Tab` of a `Window` closes the `Window`; closing the last `Window` exits the app. None of this changes the existing `Pane` ownership contract — we just add an outer level.

The single-tab single-pane case (today's behaviour) collapses to `Window{ tabs: [Tab{ root: leaf(Pane) }] }`. Existing code paths that take `*Pane` continue to work; they now reach the active pane via `app.window.tabs[app.window.active_tab].focused_leaf.pane`.

## 2. Layout

Each tab holds a **binary tree of splits**. Internal nodes carry an orientation and a ratio; leaves are panes.

```zig
pub const SplitNode = union(enum) {
    leaf: *Pane,
    branch: struct {
        orientation: SplitOrientation,  // .vertical | .horizontal
        ratio: f32,                     // 0.1 .. 0.9, share of parent extent for `first`
        first: *SplitNode,
        second: *SplitNode,
    },
};
```

A new split takes the focused leaf, replaces it with a `branch` whose `first` is the old leaf and `second` is a fresh leaf. `ratio` defaults to 0.5 but is editable via drag-to-resize on the splitter. The splitter is a 4-pixel gutter rendered between panes; clicking it captures the mouse and updates `ratio` on motion.

Focus history is a per-tab stack: `focus_history: std.BoundedArray(*SplitNode, 16)`. Closing the focused leaf pops the stack until it finds a still-live leaf or falls back to the leftmost leaf. This matches WezTerm's "focus the most-recent neighbour" behaviour.

The `MAX_PANES = 6` constant becomes `MAX_PANES_PER_TAB = 6`, preserving the per-tab memory ceiling. With six tabs that gives a thirty-six-pane working maximum per window, which we cap at `MAX_PANES_PER_WINDOW = 24` so resource exhaustion is bounded.

## 3. State persistence

On `WM_CLOSE`, the app serialises `Window` state to `%APPDATA%\ZiggyZag\session.json` and restores it on next launch.

```json
{
  "version": 1,
  "window": {
    "x": 200, "y": 150, "width": 1280, "height": 800, "maximized": false,
    "active_tab": 1,
    "tabs": [
      {
        "title": "build",
        "root": {
          "branch": {
            "orientation": "vertical",
            "ratio": 0.6,
            "first":  { "leaf": { "cwd": "C:\\dev\\ZiggyZag" } },
            "second": { "leaf": { "cwd": "C:\\dev\\ZiggyZag\\apps" } }
          }
        }
      },
      { "title": "scratch", "root": { "leaf": { "cwd": "%USERPROFILE%" } } }
    ]
  }
}
```

**Soft restore.** If a leaf's `cwd` no longer exists (deleted, unmounted, network drive offline), the pane is spawned in `%USERPROFILE%` instead. The session.json is rewritten with the fallback cwd so the next launch is stable.

**Not restored.** In-flight commands. A pane that was running `cargo build` at shutdown comes back to an idle shell. The terminal scrollback is not persisted either — restoring a buffer of partly-rendered output without the running process that produced it would be misleading. If the user wants scrollback durability, that's a separate feature.

If `session.json` is missing or fails to parse, the app launches with a single default Window holding a single default Tab holding a single Pane at `%USERPROFILE%` — exactly today's startup.

## 4. Keybindings

| Binding | Action | Conflict |
| --- | --- | --- |
| `Ctrl+Shift+T` | Open new tab in current window | **Currently bound to "cycle theme"** — moves to `Ctrl+Shift+Y`. |
| `Ctrl+Tab` | Next tab | None. |
| `Ctrl+Shift+Tab` | Previous tab | None. |
| `Ctrl+1` .. `Ctrl+9` | Jump to tab N | None. The shell already passes digit keys through; the app intercepts only when modified by Ctrl. |
| `Ctrl+Shift+W` | Close active pane | **Already exists**, keeps current meaning. Closing the last pane of a tab closes the tab. |
| `Ctrl+Shift+Q` | Close active tab (all its panes) | None. Includes a confirmation dialog when more than one pane is active. |

The `Ctrl+Shift+T` reassignment is the only behavioural break. The theme cycle moves to `Ctrl+Shift+Y` (mnemonic: "stYle"). Settings overlay (`Ctrl+,`) and palette (`Ctrl+Shift+P`) are unaffected. AgentD overlay (`Ctrl+Shift+A`) is unaffected.

A future `[keybindings]` section in `desktop.conf` will let users remap any of the above. That section ships in the same wave; this doc just names the defaults.

## 5. Render order

Top to bottom inside the window's client area:

1. **Tab strip** — `tab_strip_height = char_height + 8` pixels. Horizontal row of tab buttons, each labelled with its `title`, the active tab outlined in `theme.accent`. Tab strip is hidden when only one tab exists, to preserve the current "no chrome" look.
2. **Active tab body** — fills the remaining height minus the status bar. Recursively renders the focused tab's `SplitNode` tree, with splitter gutters between leaves.
3. **Status bar** — `status_height = 28` pixels, current value preserved. Shows the active pane's cwd, last command status, and AgentD indicator.

Repaint scope is per-region: a keystroke in the focused pane invalidates only that pane's rect, not the tab strip or status bar.

## 6. Memory

Each pane allocates roughly:

```
pane_bytes = scrollback_lines * width * sizeof(Cell)
```

`Cell` is 8 bytes today (one byte `ch`, four-byte `codepoint`, one byte `width`, two bytes `style`). With the default `scrollback_lines = 10_000`, a 200-column pane uses `10_000 * 200 * 8 = 16 MB`. Six panes per tab × four tabs = 24 panes × 16 MB = **384 MB** at the spec maximum, which is the working ceiling we document.

`desktop.conf` already exposes `scrollback.lines` for users who want to trim it. The bound check in `config.zig` (line 230) rejects values above 250 000 lines; we keep that limit, which puts the per-pane worst case at 400 MB on its own and is left to the user's discretion.

## 7. Migration

The current single-tab layout becomes the **default Tab** of a new Window. Concretely:

1. The first launch after this change reads no `session.json` and constructs `Window{ tabs: [Tab{ root: leaf(Pane(spawn_at(profile.cwd))) }] }` — visually identical to today.
2. Existing `desktop.conf` keys stay valid. `profile.cwd` is the cwd of the default pane's default tab. `scrollback.lines` applies to every pane in every tab.
3. A new optional key `session.restore = true | false` (default `true`) lets users opt out of session persistence and get a fresh window every launch.
4. The CLI `--no-restore` flag overrides `session.restore` for one run, useful when a corrupt `session.json` is suspected.

No existing test breaks. The `Pane` struct gains a `cwd` field for persistence but its current callers don't read it. Existing pane-split keybindings (`Ctrl+Shift+D`, `Ctrl+Shift+E`, `Ctrl+Shift+N`) keep their current behaviour — they operate on the active tab's split tree.

## What this doc does not specify

- **Tab tear-out.** Dragging a tab out of the strip to make it a new Window is a real feature that other terminals ship, and we are not doing it in this wave. The hierarchy supports it cleanly (move a `*Tab` from one `Window.tabs` to another), but the drag-detect, drop-target, and animation paths are work we defer.
- **Multi-window.** This spec mentions `Window` as a top-level type but Wave 5 ships with `windows.len == 1`. The plural form is for future-proofing the JSON schema, not for "open second window" on day one.
- **Session sharing.** Two ZiggyZag processes pointing at the same `session.json` is undefined behaviour. We do not lock the file, do not merge edits, do not warn. The user is one user and runs one app.
- **Cross-platform parity.** Tabs ship on Windows first. The POSIX desktop launcher (`apps/desktop/src/posix_app.zig`) gets the abstraction but not the render path until POSIX native windowing lands (Wave 6 candidate).
- **Tab reordering by drag.** Tabs reorder programmatically (via keybindings) only. Mouse drag-reorder is a Wave 6 polish item.
- **Per-tab themes.** Themes remain window-wide. Per-tab themes would require multiplying the theme-protocol surface and is deferred until users ask.

## Sources

[1] WezTerm Lua API, "Window / Tab / Pane" — https://wezterm.org/config/lua/window/. Three-level hierarchy with explicit ownership, `SpawnTab` and friends.
[2] iTerm2 documentation, "Tabs and Windows" — https://iterm2.com/documentation-preferences-tabs.html. Tab-then-pane model, focus history, drag-tear-out.
[3] kitty documentation, "Tabs" — https://sw.kovidgoyal.net/kitty/overview/#tabs. OS-window holds tab-bar, tabs hold layouts, layouts hold windows-the-kitty-sense (= panes).
[4] Ghostty handbook, "Splits and tabs" — https://ghostty.org/docs/features/splits. Currently uses native OS tabs on macOS and flattens on Linux; useful for understanding what we explicitly do not copy.
