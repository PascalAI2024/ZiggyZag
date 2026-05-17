# Reference Study

Four tools we study, what we lift from each, and what we deliberately reject. The point is not to clone — it is to learn from the best decisions in adjacent products without inheriting their complexity.

For each tool: the lesson, the concrete artifact in ZiggyZag, and the trap we avoid.

## Warp — block-based UX and AI-as-input

[warp.dev](https://www.warp.dev/) · [Warp docs](https://docs.warp.dev/)

**What is brilliant.** Warp treats each command as a discrete *block* — input, output, exit status, timing — that can be selected, copied, shared, and navigated as a unit. Universal Input fuses command typing with natural-language assistance: hit a key, ask "rebase onto main and force push," get a preview, run or discard. The command palette is the primary navigation surface, not an afterthought.

**What we lift.**

1. **Semantic blocks.** Our OSC 777 shell-integration protocol already emits `command-start` and `command-finish` events. Extend to block-aware selection: pressing a hotkey selects the full block from prompt to last byte of output. Add prompt-jump (`Ctrl+Shift+Up/Down`) that uses these events to move by block.
2. **AgentD-as-input.** Today AgentD lives in a side panel. Add a keybinding (proposed: `Ctrl+Space`) that opens an inline overlay above the prompt — the user types a request, sees a previewed shell command, presses Enter to insert it into the prompt buffer (not execute). This is the Warp move that turns AI from a chatbot into a typing accelerator.
3. **Block actions.** From any selected block: copy, copy-as-markdown (input + output fenced), share-as-URL (later), or "ask AgentD about this output."

**What we reject.** Warp's account-required model and proprietary Rust stack. ZiggyZag stays local-first, no account, MIT-licensed.

## Ghostty — the all-Zig terminal we are most likely confused with

[ghostty.org](https://ghostty.org/) · [features](https://ghostty.org/docs/features) · [config](https://ghostty.org/docs/config)

**What is brilliant.** Ghostty starts with zero config and is gorgeous out of the box. Native UI on each platform (Cocoa on macOS, GTK on Linux), GPU-accelerated rendering, hundreds of built-in themes, ligatures, grapheme clustering, Kitty graphics protocol, keybindings that hot-reload, an inspectable config file. The author (Mitchell Hashimoto) treats terminal correctness as a non-negotiable baseline.

**What we lift.**

1. **Zero-config first run.** First launch should look identical for everyone — `ziggy` theme, default keybindings, useful prompt. No setup wizard, no required env vars. Config is an enhancement, not a prerequisite. *Today this is mostly true; verify by running `ziggyzag-desktop.exe` on a fresh Windows VM with no `desktop.conf`.*
2. **Inspectable single-file config.** Our `desktop.conf` is already shaped this way. Match Ghostty's discipline: every key documented in-file with a comment, sensible defaults visible, `desktop.conf --validate` builtin.
3. **Theme breadth as a feature.** Ghostty ships ~300 themes. We ship 13. Target: 30 by 1.0 — every popular palette (Solarized Light, Catppuccin Latte/Frappé/Macchiato, Tokyo Night Storm, Material, etc.) and three originals (Ziggy, Ember, plus one light theme worth using).
4. **Conformance harness as a binary.** Ghostty has a separate VT conformance program. Build one for ZiggyZag (`scripts/vt-conformance.zig`) that emits sequences and asserts on grid state, runnable in CI.

**What we reject.** Ghostty's GPU renderer. Our GDI/CPU renderer is enough for an alpha and is easier to debug. Revisit at 1.0 only if frame times warrant it. Also: Ghostty's plugin-free posture — we will eventually allow shell-side plugins via the AgentD tool registry, but never UI-extension plugins (that road leads to xterm.js).

## WezTerm — the daily-driver baseline

[wezterm.org](https://wezterm.org/) · [features](https://wezterm.org/features.html) · [shell integration](https://wezterm.org/shell-integration.html)

**What is brilliant.** WezTerm is the "everything terminal" — multiplexing, SSH domains, Lua config, shell integration via OSC sequences, copy mode with vim keybindings, quick select for URLs, hyperlinks, ligatures, ImageProtocol, sixel. The shell integration spec is the *de facto* standard for command-lifecycle reporting.

**What we lift.**

1. **OSC sequences as the shell↔terminal protocol.** We already do this with OSC 777. Align our event names with WezTerm's (`SetCwd`, `SemanticPrompt zones A/B/C/D`) where compatible, so users of other shell-integration scripts can switch shells without losing their terminal's awareness. Document this in `docs/AGENTD_PROTOCOL.md`'s sibling `docs/SHELL_INTEGRATION.md` (new).
2. **Quick select with leader-then-letter.** WezTerm's quick select assigns letters to detected entities and lets you pick by letter. Our `Ctrl+Shift+O` quick select copies the first URL it finds — upgrade it to a leader-letter overlay so multiple URLs/paths in view are pickable.
3. **Copy mode keybindings.** Vim-style `h/j/k/l/w/b/e/v/y` movement and selection inside scrollback. Higher effort but a power-user moat.
4. **Hyperlinks (OSC 8).** Listed as P1 in our roadmap; this is the simplest huge-win item — every modern `ls`, `grep --hyperlink`, and CI tool emits OSC 8.

**What we reject.** WezTerm's Lua config surface. ZiggyZag's config is INI-style and that is good — Lua creates a permanent compatibility surface and a meaningful learning curve. Also: WezTerm's SSH multiplexer. SCOPE.md correctly puts this out of scope; do not regret that.

## fish + Starship + Atuin — the shell UX trinity

[fishshell.com](https://fishshell.com/) · [starship.rs](https://starship.rs/) · [atuin.sh](https://atuin.sh/)

**What is brilliant.** Three projects, one combined philosophy: shells should feel *fast and observant.* fish makes autosuggestions and abbreviations first-class. Starship makes prompts modular, configurable, and lightning-fast (cached, async git status). Atuin makes history a queryable database that survives shells, machines, and forgetfulness.

**What we lift.**

1. **Autosuggestion render quality.** fish renders the suggestion as ghost text in the same line, the same font, the right color (`comment` foreground). Our current implementation renders correctly in some prompt modes — audit all five prompt themes and verify suggestion contrast hits WCAG AA against every theme background. Add a `prompt --check-contrast` builtin to do this from the shell.
2. **Starship-style prompt segments.** Our `smart`/`dev`/`dashboard` prompts are good. Make them composable: a `[prompt.modules]` section in the config selects which segments appear and in what order. Each segment is a tiny function (`cwd`, `git_branch`, `git_status`, `duration`, `exit_status`, `jobs`, `time`, `python_venv`, `node_version`, `zig_version`, `aws_profile`, …).
3. **Atuin's queryable history shape.** P0 item in our roadmap. The schema we want: `(id, command, cwd, hostname, exit_status, duration_ms, started_at, shell_session_id)`. SQLite over file, queryable by `history --where 'exit_status != 0 AND cwd LIKE "%/dev/%"'`. The migration story from current `HISTFILE` is: import on first run, keep `HISTFILE` as export target.
4. **Abbreviations as the abbreviation pattern.** fish's abbreviation system shows the expanded command before Enter — already in ZiggyZag. Polish: animate the replacement (200ms fade) so it is visually obvious what happened. Cheap, satisfying.

**What we reject.** fish's incompatibility with POSIX scripts. ZiggyZag falls back to `/bin/sh` for complex syntax — keep doing this. Also: Atuin's sync server. Sync is out of scope for 1.0; the schema is borrowed, the cloud sync is not.

## Synthesis — the ZiggyZag operating thesis

After studying all four:

1. **Adopt the standard protocols** (OSC 777 aligned with WezTerm's semantic prompt, OSC 8 hyperlinks, xterm SGR mouse) so ZiggyZag composes with the existing terminal ecosystem.
2. **Compete on the integration surface**, not on raw features. The unique thing ZiggyZag can do that none of the four can is *make the shell, the terminal host, and the agent feel like one product* with shared themes, shared events, and shared approval flows.
3. **Stay all-Zig** as Ghostty has shown is possible, but keep the renderer simple (GDI/CPU) until profiling demands more.
4. **Make AgentD into Warp's Universal Input.** Local-only, approval-aware, no account. This is the differentiator most likely to land in someone's screenshot.
5. **Defer multiplayer and sync.** Friend testers want a great local terminal first. Sync is a 2.0 conversation.

## Action items pulled directly out of this study

These are now tracked in `docs/MASTERPLAN.md` and `docs/NEXT_20_FEATURES.md`:

- AgentD inline overlay invoked by `Ctrl+Space` (Warp-style universal input)
- Prompt-jump `Ctrl+Shift+Up/Down` using OSC 777 events (WezTerm-style)
- Quick select leader-letter overlay (WezTerm-style)
- OSC 8 hyperlink support
- Theme count target: 30 by 1.0 (Ghostty-style breadth)
- VT conformance binary in CI (Ghostty-style discipline)
- Composable Starship-style prompt segments
- SQLite history backend with Atuin-style schema
- WCAG AA contrast audit across all themes
- Abbreviation expansion animation (fish-style polish)

Each item maps to one or more entries in [`next-20-features.md`](next-20-features.md). Where overlap exists, this document is the *why* and that document is the *what*.
