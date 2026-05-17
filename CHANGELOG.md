# Changelog

All notable changes to ZiggyZag. The format is loosely [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/) once we hit 1.0. Until then, every `0.1.0-alpha.N` is its own coherent snapshot.

## [Unreleased] — Wave 2

### Added
- **Unified theme protocol v1.** A single `ZIGGYZAG_THEME` environment variable now drives both the desktop terminal palette and the shell prompt accent. The desktop sets it when spawning the shell child; the shell reads it at startup. See [`docs/reference/theme-protocol.md`](docs/reference/theme-protocol.md).
- `theme` shell builtin: `theme`, `theme list`, `theme <id>`, `theme --json`. Switches this session's active theme and reports the current one.
- The shell now exposes `current_theme` on `Shell` and falls back to `ziggy` when the env var is unset or unknown.
- Six new unit tests for theme env-var initialisation and the builtin (`zig build test`).
- `docs/MASTERPLAN.md` — strategic vision and wave plan anchored against `REVIEW.md`.
- `docs/REFERENCES.md` — competitive study of Warp, Ghostty, WezTerm, fish/Starship/Atuin, with action items lifted out.
- `docs/BRAND.md` — semantic color tokens, type scale, voice rules.
- `docs/WAVES.md` — release-by-release plan with explicit entry gates and rollback criteria.
- `docs/index.html` — GitHub Pages-ready landing page with theme gallery, install one-liner, wave timeline, AgentD architecture preview.
- `assets/ziggyzag-wordmark.svg`, `assets/hero.svg`, `assets/theme-gallery.svg`.
- `CHANGELOG.md` (this file).
- `SECURITY.md` with a disclosure policy.
- `scripts/install.sh` and `scripts/install.ps1` — one-line install scripts that download the latest release zip and place binaries on PATH.
- `.github/workflows/release.yml` — tag-triggered release packaging that runs on Windows, smoke-tests extracted zips on Ubuntu and macOS, and attaches artifacts to a draft GitHub Release.
- Three light-mode themes: `catppuccin-latte`, `solarized-light`, `github-light`. Registry → 16.
- Four more dark variants from canonical upstream specs: `catppuccin-frappe`, `catppuccin-macchiato`, `tokyo-night-storm`, `ayu-dark`. Registry → 20. Sources cited in-file; the theme-count regression test in `theme.zig` was bumped to expect 20.
- `docs/reference/accessibility.md` — WCAG 2.1 AA contrast audit across every built-in theme. Methodology covers fg/bg, accent/bg, muted/bg, and ANSI red on bg (the "is the error readable?" pair). 8 themes pass on all four pairs; 8 have at least one failure documented honestly.
- `scripts/audit_contrast.py` — the Python script that produced the audit. Re-runs on demand and exits non-zero on any AA failure, suitable for CI.
- `docs/guides/vt-conformance.md` — design spec for a new `ziggyzag-conformance` binary that emits VT/CSI/OSC sequences and asserts grid state. TAP output for CI integration, corpus organised by sequence family, five concrete sample test cases. Implementation deferred to Wave 3.
- `docs/reference/osc8-hyperlinks.md` — design spec for `ESC ] 8` hyperlink support. Cell-model change (`hyperlink_id: ?u32` plus a flat per-grid link table), parser branch, renderer with `ShellExecuteW`, scheme allowlist (http(s) always, file:// only inside home/workspace, all else rejected per the iTerm2/Hyper CVE precedent). Implementation deferred to Wave 3.
- `assets/agent-panel.svg` and `assets/split-panes.svg` — animated SVG mockups showing the AgentD approval flow and the three-pane split layout. Round out the landing-page visual story.
- `docs/reference/history-backend.md` — Wave 4 spec for a vendored SQLite history backend with an Atuin-shaped schema, idempotent TSV import, fallback-to-TSV path, restricted-grammar `--where`/`--since`/`--cwd-prefix`/`--json` query API, and a 50 ms first-prompt budget.
- `docs/reference/sessions.md` — Wave 5 spec for a `Window → Tab → Pane` hierarchy with binary-tree `SplitNode` layout, `%APPDATA%\ZiggyZag\session.json` persistence with soft cwd-restore, full keybinding set (callsout the `Ctrl+Shift+T` collision and reassigns theme cycle to `Ctrl+Shift+Y`), and the per-pane memory budget at 10k scrollback.
- `docs/guides/friend-testing.md` — onboarding brief for the Wave 3 cohort of three friend testers (Windows / macOS / Linux). Covers the two-week contract, exact rollback commands, issue-template names with attach/don't-attach lists, and the 14-day reaction milestone.
- `docs/guides/faq.md` — first-five-minutes FAQ. 12 sections answering the questions every first-time visitor asks: is this another terminal, is it ready, what does AgentD send anywhere, where are tabs / SSH, how do I install on macOS / Linux, what's the difference between the shell and the desktop host, how do I contribute.
- `assets/theme-gallery-v2.svg` — full 20-theme gallery (5 rows × 4 columns) replacing the older 12-theme image. README and landing page point at the new asset.
- `assets/command-palette.svg`, `assets/prompt-themes.svg` — landing-page mockups for `Ctrl+Shift+P` palette and the five shell prompt themes side-by-side.
- `assets/favicon.svg` (32×32 brand mark) and `assets/og.svg` (1200×630 social card). The landing page's `<link rel=icon>` and `og:image` are pointed at them.
- `scripts/demo.sh` — canonical feature walkthrough that pipes a coherent command sequence into a running shell. Foundation for the eventual demo GIF/asciinema cast. Sequence covers REPL, builtins, expansion, completion, project awareness, history queries, all five prompt themes, the theme protocol (with live cycle), convenience builtins, AgentD health check.
- `unescapeTsvFieldAlloc` helper in the shell — the round-trip companion to `appendTsvField`. Used by the new metadata-history loader. Round-trip test added.
- Three regression tests added during the polish pass: TSV field round-trip, JSON encoder control-byte handling, `isConfigDirective("theme")`.

### Changed
- `build.zig` factors a shared `theme_module` and exposes it under the import name `theme` to the shell binary and the shell test target.
- `apps/desktop/src/windows_app.zig` and `apps/desktop/src/posix_app.zig` set `ZIGGYZAG_THEME` in the spawned shell's environment.
- `README.md` rewritten for portfolio impact: tighter hero, single-image theme gallery, install-in-60-seconds block, honest status section, link to the masterplan.
- CI now runs on `ubuntu-latest`, `windows-latest`, **and `macos-latest`** with the same `zig build && zig build test && smoke` flow.
- `README.md` hero alt-text and theme list updated to reflect the 20-theme registry. `docs/index.html` stats panel adds a "20 built-in themes" tile and links to the new accessibility audit.

### Fixed
- **AgentD watchdog deadlock** in `commandJsonAlloc` (`apps/agentd/src/tools.zig`). Every `rg.search` and `git.diff` call blocked for the full 30-second timeout and then returned `error.ToolTimedOut`, because the watchdog's `std.Io.sleep` was uncancellable and `fired` was set unconditionally after the sleep. The watchdog now polls in 100 ms ticks and exits as soon as the main thread reaps the child via a new `main_done` atomic flag. Fast commands now return in roughly their natural runtime. No test exercised the success path, which is why this shipped in alpha.2 — follow-up work is to add the integration test.
- **`theme` directive silently ignored in `~/.ziggyzagrc`** (`apps/shell/src/main.zig`). The runtime config loader and `isConfigDirective` predicate did not recognise the new `theme` builtin as a config-time command. Fixed in both places; test added.
- **Invalid JSON for sub-0x20 control bytes** (`apps/shell/src/main.zig`). The shell's `appendJsonString` only escaped `\n`, `\r`, `\t`, so values containing NUL, BEL, VT, etc. produced output that did not satisfy RFC 8259. Brought to parity with AgentD's correct implementation: short forms for the five common escapes plus `\u00XX` for every remaining sub-0x20 byte. Regression test added.
- **History metadata never loaded on startup** (`apps/shell/src/main.zig`). `ZIGGYZAG_HISTORY_DB` was written at process exit but never read at process start, so `history --stats`, `--slow`, `--cwd`, and `--failed` could only see the current session. Added `readHistoryMetaFile` paired with the existing write path, plus the `unescapeTsvFieldAlloc` helper to invert `appendTsvField`. Wired the load call after `readHistoryFile` in `run()`.
- **`dir_index` mutated before `chdir` succeeded** (`apps/shell/src/main.zig`). `back`, `forward`, and `jump` set `self.dir_index = target` *before* calling `goToDirectoryIndex`, which then ran `setCurrentPath`. If chdir failed, `dir_index` was left pointing at a now-invalid slot. `goToDirectoryIndex` now takes the desired index as a parameter and updates state only after success.
- Doc reorganisation: 27 markdown files moved into `docs/{guides,reference,vision,reviews}/` with kebab-case names, a single hub at `docs/README.md`, fresh nav in `docs/index.html`. All 131 cross-link targets and 114 display labels rewritten. Verifier confirms zero broken intra-repo links.
- `.gitignore` now excludes `.opencode/`, `.worktrees/`, and `.mavis/` — previously they were untracked-by-accident and at risk of leaking into commits.

## [0.1.0-alpha.2] — 2026-05-15

### Added
- Native simple pipelines with concurrent stdout/stderr draining per stage and temp-file handoff for large stage output.
- Windows desktop alpha: `Ctrl+,` settings overlay, `Ctrl+Shift+P` command palette, `Ctrl+Shift+F` scrollback search, `Ctrl+Shift+O` quick-select, `Ctrl+Shift+D/E/N/W` split-pane controls, `Ctrl+Shift+A` AgentD panel, `Ctrl+Shift+T` live theme cycle.
- AgentD desktop panel: spawns `ziggyzag-agentd --stdio`, renders bounded transcript, previews `terminal.write`, requires explicit approval before writing to the active PTY.
- 13 built-in themes: `ziggy`, `catppuccin-mocha`, `tokyo-night`, `dracula`, `nord`, `rose-pine`, `gruvbox-dark`, `everforest-dark`, `kanagawa-wave`, `solarized-dark`, `one-dark`, `paper`, `ember`.
- Visual prompt themes for the shell: `classic`, `smart`, `compact`, `dev`, `dashboard`.
- Project-aware `run` builtin, abbreviation expansion, autosuggestion hooks (`Ctrl+F` accept), fuzzy `Ctrl+R` recall, syntax highlighting in `smart` prompt mode.
- POSIX desktop launcher: native PTY relay first, `script(1)` fallback, then direct stdio.
- Cross-built release zips for `windows-x86_64`, `linux-x86_64`, `linux-aarch64`, `macos-x86_64`, `macos-aarch64` with `checksums.sha256` and `release-manifest.json`.
- Interlinked docs system: `ROADMAP.md`, `FEATURES.md`, `NEXT_20_FEATURES.md`, `ALPHA_TASKS.md`, `RESEARCH.md`, `ARCHITECTURE.md`, `TASK_SYSTEM.md`, `DATA_MAP.md`, `SCOPE.md`, `TERMINAL_APP.md`, `ALL_ZIG_TERMINAL.md`, `QUICK_START.md`, `DAILY_DRIVER_QA.md`, `QA_TOMORROW.md`, contributing tour, terminal parser guide, AgentD protocol guide, theme authoring guide, release checklist.

### Changed
- Removed the Tauri / xterm.js desktop spike. The all-Zig host is the only desktop lane going forward.
- Restructured the repository as a standalone open-source workspace, separating the CodeCrafters origin from the current product direction.

### Security
- Hardened `file.read` sandbox in AgentD with a three-layer check: lexical filter, final-component `lstat` for symlinks, and a canonicalising `realpath` workspace-containment guard. Regression tests cover sibling-prefix escapes (`/home/u/ws-evil/secret`), Windows ADS streams (`README.md:ads`), directory-symlink escapes, and final-symlink escapes.
- Fixed a provider-call deadlock in the AgentD process tools.
- Terminal core consumes OSC strings (BEL/ST/CAN/SUB-terminated) without acting on payloads from untrusted sources.

## [0.1.0-alpha.1] — 2026-05-15

### Added
- First public alpha tag.
- Shell REPL, builtins (`about`, `alias`, `cd`, `complete`, `doctor`, `echo`, `env`, `exit`, `export`, `history`, `inspect`, `jobs`, `prompt`, `pwd`, `repeat`, `run`, `source`, `timeit`, `type`, `which`, more), redirection, native simple pipelines (`/bin/sh` fallback for complex), `HISTFILE` persistence, metadata history, background jobs.
- Quoting, parameter expansion (`$VAR`, `${VAR}`), backslash escapes, programmable completion with descriptions.
- Windows Win32 + ConPTY desktop host MVP with terminal grid rendering, ESC parser, bounded scrollback, alternate screen, 256/RGB color support, bracketed paste.
- `ziggyzag-agentd` JSON-lines sidecar with tool discovery (`project.info`, `file.read`, `rg.search`, `git.diff`, `zig.build`, `terminal.write`), Ollama and OpenAI-compatible provider hooks.
- Cross-platform builds via `zig build` with Windows-only desktop linkage.
- GitHub Actions CI on Ubuntu and Windows: `zig build` + `zig build test` + smoke script.

[Unreleased]: https://github.com/PascalAI2024/ZiggyZag/compare/v0.1.0-alpha.2...HEAD
[0.1.0-alpha.2]: https://github.com/PascalAI2024/ZiggyZag/compare/v0.1.0-alpha.1...v0.1.0-alpha.2
[0.1.0-alpha.1]: https://github.com/PascalAI2024/ZiggyZag/releases/tag/v0.1.0-alpha.1
