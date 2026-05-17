# Research Library

This page is the source-backed research index for the feature plan in [next-20-features.md](next-20-features.md). It captures the official Ghostty and WezTerm reference signals used there and maps them to ZiggyZag tasks so implementation work can trace back to product and terminal-compatibility rationale.

Last verified: 2026-05-16.

Task flow lives in [task-system.md](../reference/task-system.md), alpha remaining work lives in [alpha-tasks.md](alpha-tasks.md), and QA/release evidence lives in [data-map.md](../reference/data-map.md).

## Source Library

| Source | Official URL | Signals Used |
| --- | --- | --- |
| Ghostty features | <https://ghostty.org/docs/features> | Native UI expectations, windows/tabs/splits, GPU rendering, themes, ligatures, grapheme clustering, Kitty graphics, xterm/protocol-origin compatibility principles. |
| Ghostty configuration | <https://ghostty.org/docs/config> | Zero-configuration defaults, simple text config, optional config files, runtime reload, offline reference docs. |
| Ghostty keybindings | <https://ghostty.org/docs/config/keybind> | Flexible trigger/action bindings, modifiers, Unicode triggers, performable/unconsumed behavior, listable defaults. |
| Ghostty themes | <https://ghostty.org/docs/features/theme> | Built-in theme library, one-line theme selection, light/dark theme pairing, custom theme files, theme safety review. |
| WezTerm features | <https://wezterm.org/features.html> | Cross-platform baseline, panes/tabs/windows, native mouse and scrollback, ligatures, color emoji, font fallback, truecolor, hyperlinks, searchable scrollback, bracketed paste, SGR mouse reporting, render attributes, hot-reloaded config. |
| WezTerm shell integration | <https://wezterm.org/shell-integration.html> | OSC 7 cwd, OSC 133 prompt/input/output zones, OSC 1337 user vars, prompt navigation, command-output selection, per-pane shell state. |
| WezTerm command palette | <https://wezterm.org/config/lua/keyassignment/ActivateCommandPalette.html> | Discoverable modal action launcher, default Ctrl+Shift+P binding, fuzzy matching, frecency ranking, keyboard navigation. |
| WezTerm quick select | <https://wezterm.org/quickselect.html> | Pattern-based selection for URLs, paths, hashes, IP addresses, numbers, copy and copy-paste flows. |
| WezTerm copy mode | <https://wezterm.org/copymode.html> | Keyboard-driven scrollback navigation and selection, cell/line/rectangular selection modes, copy-and-exit workflow. |
| WezTerm split panes | <https://wezterm.org/config/lua/keyassignment/SplitPane.html> | Directional pane splitting, command spawning into new panes, split sizing, CLI-backed split behavior. |

## What We Borrow

- Compatibility bar: use Ghostty's xterm-first and protocol-origin principles as the decision frame for VT parser behavior, malformed-sequence recovery, and modern protocol adoption.
- Terminal correctness features: copy Ghostty and WezTerm's expectation that graphemes, wide characters, emoji, ligatures, color attributes, bracketed paste, SGR mouse, scrollback, alternate screen, and hyperlinks are daily-driver baseline behavior rather than polish.
- Interaction model: use WezTerm's command palette, quick select, copy mode, searchable scrollback, panes, tabs, and shell-aware prompt navigation as the benchmark for discoverability and speed.
- Configuration shape: borrow Ghostty's low-friction defaults and inspectable text config, plus WezTerm/Ghostty runtime reload expectations.
- Theme expectations: borrow Ghostty's built-in theme breadth, one-line selection, custom theme files, and dark/light switching model.
- Shell integration: borrow WezTerm's OSC 7, OSC 133, and user-var model as evidence that shell state should be first-party terminal UX, not scraped text.

## What We Do Differently

- Keep ZiggyZag all-Zig and first-party: the goal is not to embed WezTerm, wrap Ghostty, or make another terminal the host. External projects set the quality bar; ZiggyZag owns the shell, terminal grid, desktop host, and AgentD path.
- Treat ZiggyZag shell context as native data: prompt, git status, history metadata, command ranges, approvals, and AgentD state should flow through explicit ZiggyZag events and storage instead of only generic terminal escape conventions.
- Ship honesty before breadth: `TERM`, color capability claims, protocol support, and UI affordances should match implemented behavior. Partial support must remain documented until tests prove it.
- Prefer small, auditable APIs: when borrowing ideas such as user vars, shell zones, quick select, or palette actions, expose the smallest interface that unlocks the ZiggyZag task instead of cloning the full reference surface.
- Make agent actions approval-aware by design: WezTerm/Ghostty establish terminal UX expectations; ZiggyZag adds an agent workflow where write/build/terminal mutations require explicit approval and auditability.

## Research-To-Task Traceability

| Research Signal | ZiggyZag Task(s) | Implementation Implication |
| --- | --- | --- |
| Ghostty xterm/protocol-origin compatibility principles | 1, 4, 5 | Build a conformance harness before expanding parser scope; choose behavior from xterm/protocol precedent where specs are ambiguous. |
| Ghostty grapheme clustering and WezTerm ligatures/color emoji/font fallback | 2 | Extend the Unicode cell model beyond scalars to grapheme clusters, combining marks, emoji width, fallback fonts, and renderer verification. |
| WezTerm truecolor and rich render attributes | 3 | Finish SGR storage/rendering parity: underline variants, italic, inverse, strikethrough, blink policy, and honest capability profiles. |
| WezTerm bracketed paste and SGR mouse reporting | 5 | Complete keyboard/mouse protocols, modifier/function keys, IME/dead-key behavior, focus events, wheel and button reports. |
| Ghostty and WezTerm panes/tabs/windows | 17 | Continue from split panes to tab objects, close confirmation, per-pane cwd/title/session restore, and last-layout persistence. |
| WezTerm searchable scrollback and copy mode | 15 | Add keyboard copy mode, selection-aware copy, prompt-jump, and later rectangular selection on top of bounded scrollback/search. |
| WezTerm quick select | 16 | Expand quick select from copy-only viewport tokens to open actions, IPs, command ranges, OSC 8 hyperlinks, and paste/search actions. |
| WezTerm command palette | 18 | Keep palette actions discoverable and keyboard-first; add tabs and frecency after the first action registry is stable. |
| Ghostty config/keybind docs and WezTerm hot reload | 19 | Grow config into profiles, keybindings, settings editing, live reload, and safe defaults. |
| Ghostty theme docs and WezTerm dynamic color expectations | 19 | Add light/dark pairs, theme editing/import, prompt/terminal color sync, and documented theme lookup/safety rules. |
| WezTerm shell integration OSC 7/133/1337 | 13, 15, 16, 17, 20 | Use explicit shell events for cwd inheritance, prompt-jump, command-output selection, durable metadata, and AgentD context. |
| WezTerm cross-platform support and Ghostty native UI posture | 7 | Turn PTY backends into a shared interface and add real macOS/Linux graphical hosting rather than launcher-only behavior. |
| Ghostty zero-configuration philosophy | 6, 12, 19 | Keep startup, prompt, defaults, reload, and recovery paths usable before asking users to configure anything. |

## Open Research Questions

- Terminal conformance: which exact public test corpus should become ZiggyZag's VT regression suite, and which gaps require custom fixtures?
- Parser boundary: should ZiggyZag continue growing its local parser, or should `libghostty-vt` be evaluated behind a narrow adapter once task 1 exposes the compatibility matrix?
- Grapheme engine: which Zig-native Unicode/grapheme-width data source should back combining marks, emoji ZWJ sequences, East Asian width, and ambiguous-width policy?
- Renderer model: what Windows font fallback and shaping APIs are sufficient for emoji, CJK, box drawing, ligatures, and grapheme clusters without losing the current simple host architecture?
- Shell integration contract: should ZiggyZag emit and consume standard OSC 7/133/1337, a ZiggyZag-specific OSC channel, or both?
- Capability truthing: what `TERM` value, terminfo entry, and protocol-advertising strategy best reflects partial support during alpha?
- Theme sourcing: should built-in themes be curated manually, imported from an upstream theme repository, or generated from a constrained theme schema?
- Keybinding portability: how should a cross-platform key model represent Windows, macOS, Linux, Unicode triggers, IME/dead keys, and application-keypad modes?
- Agent context safety: where is the boundary between shell integration data that AgentD can trust and terminal text that must remain untrusted UI context?
