# Masterplan

The single document that anchors ZiggyZag's path from current alpha to a portfolio-grade open-source product worth showing off and worth using daily.

Companion documents: [`waves.md`](waves.md) is the release plan, [`references.md`](references.md) is the competitive study, [`brand.md`](../reference/brand.md) is the visual identity, [`scope.md`](scope.md) is the boundary, [`alpha-tasks.md`](alpha-tasks.md) is the line-by-line task ledger.

## Thesis

A modern terminal experience does not require a new shell, a new renderer, or a new account. It requires a small set of components that *feel like one product*: a readable shell, a native terminal host, and a local AI sidecar that respects the user's approval. Zig is the right language because the entire stack stays inspectable in a weekend. Cross-platform parity is the right bar because portfolio impact depends on a screenshot working on someone else's machine.

ZiggyZag will be successful when a developer who has never heard of it can:

1. Install in under 60 seconds with a one-liner.
2. See something visually distinctive in the first 10 seconds of running.
3. Find one feature they wish their current terminal had, within 5 minutes.
4. Continue using it as their daily terminal a week later.

Everything in this document is in service of those four sentences.

## Principles

1. **Local first.** No account, no cloud, no telemetry-by-default. Sync is a 2.0 conversation.
2. **Honest defaults.** Zero-config should look intentional. Every default value is a design decision, not an accident.
3. **One product, three binaries.** The shell, the desktop host, and AgentD share theme, events, and approval semantics — never duplicate state.
4. **Approval is sacred.** Any action that mutates the terminal, filesystem, or build state requires explicit human approval. No exceptions, no "trusted mode."
5. **All-Zig until profiled otherwise.** No JavaScript, no Rust, no Lua. Inline Win32/Cocoa/X11 bindings beat third-party wrappers.
6. **Documentation as a product surface.** Docs ship with releases, are linked from the UI, and are accurate to the binary.

## Strategic moves (in priority order)

These are the moves that change ZiggyZag's standing as a portfolio piece and as a usable tool. Tactical TODOs continue to live in `NEXT_20_FEATURES.md`; this list is *strategic*.

### Move 1 — Unified theme protocol (✓ shipped in Wave 2 · tagged `alpha.3`)

One config key drives the desktop palette AND the shell prompt colors. Implemented via env var (`ZIGGYZAG_THEME`) for child-process startup; v2 (OSC 7777 live updates) is also shipped — the desktop's `cycleTheme` broadcasts an OSC 7777 sequence and the shell's `handleOscSequence` applies it without a restart. See [`theme-protocol.md`](../reference/theme-protocol.md). Twenty themes ship today, every one audited for WCAG AA contrast — [`accessibility.md`](../reference/accessibility.md).

### Move 1.5 — Windows host I/O (✓ fixed 2026-05-17, post-`alpha.3`)

At the time `alpha.3` was tagged the Windows ConPTY host was structurally broken: it spawned the shell but typed commands never executed. Four bugs: a stale-config resolver, a missing `CREATE_UNICODE_ENVIRONMENT` flag, a dead ConPTY bridge (`CREATE_NO_WINDOW` orphaned the child to a private conhost), and a no-op `TerminalMode` stub that left the shell in cooked line-input mode. All four were root-caused and fixed this session. The host is now empirically drivable — three independent signals: per-keystroke manual-echo redraws, a post-Enter command-output burst, and integration `status: ok`. Full record: [`../reviews/2026-05-17-windows-debug.md`](../reviews/2026-05-17-windows-debug.md).

### Move 2 — Cross-platform parity (Wave 3)

Native Linux and macOS desktop hosts. The `Pty` abstraction in `apps/desktop/src/pty.zig` is real and the **Windows ConPTY backend is wired behind it** (`windows_app.zig` calls `Pty.spawn`; verified 2026-05-18, no inline Win32 PTY code remains) — that prerequisite is done. What remains for this move is the **POSIX backends** (`spawnNativePosix`/`spawnScriptPosix`/`spawnDirectPosix` still return `error.NotImplemented`) plus the native macOS (Cocoa) and Linux (X11) windows built on them. Today macOS/Linux get a terminal-attached launcher, not a native window. At 12 hours/week the remaining native-host work is roughly a half-year, not a near-term deliverable. Until native hosts ship, every screenshot in the README must be honestly labeled `Windows / macOS / Linux`.

### Move 3 — AgentD universal input (Wave 3)

`Ctrl+Space` opens an inline overlay above the prompt. User types a natural-language request. AgentD shapes it into a shell command preview. Enter inserts into the prompt buffer (not execute). This is the Warp-influenced move that turns AgentD from "panel" to "the way you type."

### Move 4 — Durable history backend (Wave 4)

SQLite-backed history with Atuin-style schema. Queryable by `history --where`. Imports existing `HISTFILE` on first run. Unlocks "what did I run last Tuesday in this directory" as a single command.

### Move 5 — Streaming pipelines (Wave 4)

Replace the stage-buffered native pipeline with true OS pipe handles, concurrent stdout/stderr draining, bounded captures, deadlock tests. Removes the asterisk in every pipeline mention in our docs.

### Move 6 — Tabs and richer session restore (Wave 5)

`Session` abstraction over PTY/grid. Per-tab title, cwd inheritance, close confirmation, layout restore. Last big visual-product gap.

### Move 7 — 1.0 release with friend cohort sign-off (Wave 6)

All five gates in `NEXT_20_FEATURES.md#main-terminal-gate` pass on Windows, macOS, and Linux. At least three friend testers have used ZiggyZag as their daily driver for two weeks each. CHANGELOG documents the journey.

## Success metrics

Pre-1.0, deliberately small. Vanity metrics distort priorities.

| Metric | Target by 1.0 |
| --- | --- |
| GitHub stars | Not a target. If the work is good they will arrive. |
| Daily-driver friend testers | 5, each having logged 2+ weeks |
| Issues closed within 7 days | ≥80% |
| CI pass rate on `master` | ≥95% over trailing 30 days |
| Time from `git clone` to running shell | ≤2 minutes on a fresh machine |
| Time from `git clone` to running desktop | ≤5 minutes on a fresh Windows machine |
| Demo GIF in README | Yes, ≤2 MB, ≤10 seconds, ≤200ms first frame |
| Themes shipped | 30 |
| `zig build test` runtime | ≤30 seconds on a 2024 laptop |

## Risks and how we handle them

**Solo maintainer burnout.** ZiggyZag is a one-person project. Burnout will end it before any feature does. Mitigation: a fixed weekly cap (no more than 12 hours/week after Wave 2). Wave gates are designed so that pausing for two weeks does not destabilize anything.

**Cross-platform drift.** Windows is far ahead. Without macOS/Linux in CI, every Windows-specific fix risks breaking POSIX silently. Mitigation: macOS in CI before Wave 3, mandatory POSIX smoke before tagging.

**Scope creep into "yet another terminal."** The temptation to add SSH multiplexing, plugins, sync, image protocols. Mitigation: SCOPE.md is binding. Any addition to scope requires a corresponding deletion of something else.

**Security incident in AgentD.** A path-traversal escape or approval-bypass would be the single most damaging thing that could happen. Mitigation: `SECURITY.md`, fuzz target for the sandbox, no expansion of AgentD tool surface without a written threat-model update.

**The agent panel sitting silent for users without Ollama.** Documented today. Mitigation: in Wave 2, ship a "no provider configured" inline state with a one-click "install Ollama" link and recommended-model `ollama pull` command, plus a tiny built-in fallback that can do trivial completions (alias expansion, `cd <project>`, history search) using only local data.

## The non-goals

What this masterplan deliberately does not pursue:

- A web version, an Electron version, or a mobile app.
- Cloud history sync, account systems, or team features.
- A plugin marketplace for UI extensions.
- Compatibility with every TUI app on first try (we will get most, document the rest as known edges).
- Replacing zsh/bash/fish as anyone's primary login shell.
- Becoming a CodeCrafters showcase. ZiggyZag has outgrown that frame.

## How this document is maintained

Reviewed every wave gate. Updated when a strategic move ships or when a new strategic move displaces one in the list. Tactical changes go in `NEXT_20_FEATURES.md` and `ALPHA_TASKS.md`. If those two documents start to disagree with this one, this document is the source of truth and the others are updated.

The previous review document, [`docs/reviews/2026-05-17-baseline.md`](../reviews/2026-05-17-baseline.md), is the baseline this masterplan responds to. Future external reviews should be filed alongside it and referenced here when they change the plan.
