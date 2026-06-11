# ZiggyZag — PLAN.md

> Structured task tracker for the J.A.R.V.I.S. team building ZiggyZag, an all-Zig
> personal terminal: shell (`apps/shell`), desktop host (`apps/desktop`, Win32 +
> macOS Cocoa), AgentD AI sidecar (`apps/agentd`).
>
> **North star:** make this the best personal terminal — Fish's shell
> helpfulness, Ghostty's terminal correctness, Warp's modern AI UX. Stay all-Zig.
> Borrow ideas, never code.
>
> **Active wave:** Wave 3 — Cross-platform (macOS native window shipped 2026-06-10).
> Wave 4 (durable history / streaming pipelines) items may be pulled forward when cheap.
>
> **Build:** `zig build` · **Test:** `zig build test` · **Native macOS window:** `ZIGGYZAG_NATIVE_WINDOW=1`
>
> Source docs distilled here: `docs/vision/alpha-tasks.md`, `docs/vision/next-20-features.md`, `docs/vision/waves.md`.

---

## Owners

| Owner | Domain | Primary paths |
| --- | --- | --- |
| terminal-core | VT correctness, macOS/Linux native window, renderer, PTY | `apps/desktop/src/terminal.zig`, `macos_app.zig`, `windows_app.zig`, `pty.zig`, `posix_pty.zig` |
| shell-fish | Interactive shell UX (Fish-grade) — completions, suggestions, history, pipelines | `apps/shell/src/main.zig` |
| agentd-warp | AgentD AI sidecar + desktop panel (Warp-grade) | `apps/agentd/src/*`, `apps/desktop/src/integration.zig` |
| qa | Continuous build/test, maintainability, docs hygiene | repo-wide |
| stark-product | Product feel, PLAN.md, wave priorities, taste verdicts | docs + product |

---

## Sprint 1 — Wave 3 close-out + cheap Wave 4 pull-forward — CLOSED ✓

**Convergence gate: ALL GREEN** (b4b1576). Build clean, full test suite passes,
vt-conformance 12/12, smoke-desktop passes, `zig fmt` clean, every task committed
by its owner. Sprint 1 closed by stark-product.

| ID | Task | Owner | Status | Acceptance Criteria | Result |
| --- | --- | --- | --- | --- | --- |
| S1 | Verify the in-flight macOS native window compiles clean and runs | terminal-core | ✅ Completed | `zig build` green on macOS; `ZIGGYZAG_NATIVE_WINDOW=1 ./zig-out/bin/ziggyzag-desktop` opens a Cocoa window, renders a prompt, accepts typed input, survives a window resize, and closes without a crash. Working-tree changes to `macos_app.zig` are committed once verified. | Committed. Runtime confirmed by stark-product: window + PTY shell + pre-forked agentd all healthy, clean shutdown reaps both children (no orphans). Re-verified empirically by terminal-core via screenshots through the ZiggyZag.app bundle (com.ziggyzag.desktop): prompt renders, typed `echo` echoes + outputs with green syntax highlight, `seq 1 40` scrolls, wheel-up shows the scrollback indicator, corner-drag resize reflows the grid cleanly, Cmd+V pastes from the clipboard, and `exit` closes with zero orphan processes. |
| S2 | macOS desktop launch/close smoke test in CI-runnable form | qa | ✅ Completed | A scripted smoke run launches the native window, writes one command, reads output, and exits 0; recorded in `scripts/` alongside the existing smoke scripts. No detached thread touches freed state on close. | smoke-desktop passes in the convergence gate. |
| S3 | VT conformance harness binary + grid snapshot diff | terminal-core | ✅ Completed | A standalone `zig build` step (e.g. `zig build vt-conformance`) feeds a fixed CSI/OSC/erase/scroll-region/alt-screen corpus and asserts grid state; failures print a readable diff. Wires the existing in-file conformance tests into a runnable binary. | `vt-conformance` 12/12 green; `apps/desktop/src/vt_conformance.zig` shipped. |
| S4 | Completion engine v2 — cursor-aware + quoted/escaped paths | shell-fish | ✅ Completed | Tab completion completes the token *at the cursor* (not just end-of-line); paths containing spaces complete with correct quoting/escaping on POSIX; ≥3 new tests in `apps/shell/src/main.zig` cover mid-line completion and a spaced path. `completionTokenStart` honors cursor position. | Committed; tests green in suite. |
| S5 | Syntax highlighting on the interactive prompt (Fish-grade) | shell-fish | ✅ Completed | As the user types, valid command heads render in one color and unknown/invalid commands in an error color; quoted strings and operators are distinct. Toggleable via config; ≥2 tests assert the colorizer classification. Builds on the existing autosuggestion render path. | Committed; colorizer tests green. |
| S6 | Durable metadata history backend on by default (Wave 4 pull-forward) | shell-fish | ✅ Completed | History persists across restarts by default and reloads on startup; `history` lists prior-session entries; `HISTFILE` import on first run and export retained; storage path documented in `docs/QUICK_START.md`. Secrets redacted before persistence. | Committed; durable backend default-on. |
| S7 | AgentD universal-input polish — provider-absent + safety copy | agentd-warp | ✅ Completed | `Ctrl+Space` overlay (macOS + Windows) shows a clear "no provider configured" state with next steps when no key is set; a previewed command is **inserted, never executed** (no path inserts an Enter); one regression test asserts no auto-execute. | Committed (b4b1576 — macOS overlay approval gate + error states + protocol fix). |
| S8 | Taste pass on macOS native window once S1 lands | stark-product | ✅ Completed | stark-product runs the native window and reports a written verdict to team-lead on: theme coherence, prompt latency feel, glyph rendering crispness, and overlay UX. At least one concrete improvement filed as a task. | Verdict delivered to team-lead. Scores: theme 4/5, latency 4/5, glyph 3/5, overlay 4/5. Runtime verified empirically. Filed B1 (Unicode glyph `?` fallback) as the taste-blocker and B15 (app bundle, board #14) to unblock pixel QA. Pixel screenshot was blocked: bare ASN-registered exe with NULL bundleID. |

### S8 taste-pass rubric (pre-staged — runs the moment S1 reports green + committed)

**Launch:** `zig build` then `ZIGGYZAG_NATIVE_WINDOW=1 ./zig-out/bin/ziggyzag-desktop`. Default theme is `Ziggy` (bg `#111315`, fg `#eef2e2`, accent `#9be28f`); 20 themes cycle with `Ctrl+Shift+T`.

Score each 1–5, note one concrete fix:

1. **Theme coherence** — Does the shell prompt accent match the window palette accent? Cycle `Ctrl+Shift+T` through Ziggy → Tokyo Night → Catppuccin → Dracula → Nord; does the prompt re-tint live (OSC 7777) without a stale frame?
2. **Prompt latency feel** — Keystroke-to-glyph and Enter-to-output: instant, or is there a perceptible lag? Paste a 200-line block (`Cmd+V`) and watch for jank/tearing.
3. **Glyph rendering crispness** — Are ASCII glyphs sharp at the default font size? **Known edge (→ B1):** the renderer falls back to `?` for any codepoint outside `0x20–0x7E` (`macos_app.zig` glyph path), so Unicode prompt symbols, box-drawing, and emoji will be mojibake until the Unicode/grapheme cell model lands. Confirm severity in real use; do *not* re-file as new — it's already B1.
4. **Overlay UX** — `Ctrl+Shift+P` palette (fuzzy match feel, selected-row contrast), `Ctrl+Shift+F` search, `Ctrl+Shift+O` quick select, `Ctrl+,` settings, `Ctrl+Space` AgentD universal input (does it *insert* not execute? provider-absent state legible? — overlaps S7). `Esc` closes cleanly.

**Verdict format to team-lead:** one-line headline ("feels first-party" / "rough edges X, Y"), the four scores, and the single highest-leverage fix filed as a board task.

---

## Sprint 2 — "Boringly correct, then first-party feel" (Wave 3/4) — PARTIAL, session wound down

**Theme.** Close the single biggest correctness gap (Unicode glyphs — the S8
taste-blocker) and the visual work that completes the glyph story, then make the
shell feel first-party with semantic navigation and quick-select open actions.
Tabs/sessions (Wave 5, large) and Linux native window (no Linux runtime to verify
here) are deliberately held for a later sprint to keep this one convergent.

**Resting state (session wind-down):** S9, S10, S11, S13 landed and are committed —
the Unicode taste-blocker is closed. S12 and S14 were not started and are returned
to the Backlog as pending. S15 (the Sprint 2 taste pass) was cancelled for this
session by owner order; re-scope it next session once B15 (`ZiggyZag.app` bundle)
is in tree so a real pixel screenshot can confirm the glyph fix.

| ID | Task | Owner | Status | Acceptance Criteria | Result |
| --- | --- | --- | --- | --- | --- |
| S9 | Unicode/grapheme cell model — kill the `?` fallback (B1, taste-blocker) | terminal-core | ✅ Completed | Cell carries width metadata; renderer draws codepoints beyond `0x20–0x7E` instead of `?`: Latin-1/accents, box-drawing, BMP. CJK = 2 cells; combining marks attach to base cell. macOS CoreText glyph path renders a real Unicode string. ≥4 tests. | Committed. The S8 taste-blocker is closed — the `?` glyph fallback is gone. (Exact-combining-mark fidelity tracked forward as B18 per-cell grapheme buffer.) |
| S10 | Visual render attributes draw on macOS — underline/italic/strike/double-underline | terminal-core | ✅ Completed | CoreText/CG renderer visibly draws underline, double underline, italic, strikethrough, overline; truecolor + 256-color SGR render on macOS as on Windows. | Committed; attributes render on the macOS path. |
| S11 | Semantic prompt zones + prompt-jump navigation (OSC 7777) | terminal-core | ✅ Completed | Shell emits zone markers (prompt/command/output/exit-status) over OSC 7777; desktop records per-command ranges + keyboard prompt-jump. ≥2 tests. Documented in `docs/SHELL_INTEGRATION.md`. | Committed; semantic navigation shipped. |
| S12 | Quick-select open actions + OSC 8 hyperlinks (#16) | terminal-core | ⏸ Backlog (not started) | `Ctrl+Shift+O` gains an *open* action for URLs/paths; OSC 8 hyperlinks parsed into the cell model and openable. Depends on S9 (now done). | Returned to Backlog as B8. S9 dependency is now satisfied, so it's ready to claim next session. |
| S13 | Streaming native pipelines — real OS pipe chain + deadlock test (#10, Wave 4 pull-forward) | shell-fish | ✅ Completed | Common pipeline case uses real OS pipe handles (no temp-file handoff); bounded captures; documented deadlock test passes in CI. | Committed; streaming pipe chain + deadlock test landed. |
| S14 | Theme/prompt sync hardening — light/dark pairs + bidirectional select (#19 slice) | shell-fish + terminal-core | ⏸ Backlog (not started) | Theme pick on either side updates the other within one frame; light/dark variants; ≥2 round-trip tests. | Returned to Backlog as B10 (theme-sync slice). Ready to claim next session. |
| S15 | Sprint 2 taste pass + B15 visual-QA unblock check | stark-product | ✖ Cancelled (this session) | Re-run the macOS taste pass; if B15 bundle is in tree, capture a real pixel screenshot to verify glyphs render with no `?`. | Cancelled by owner wind-down order. Re-scope next session — sequence it AFTER B15 (#14) so the glyph fix can be confirmed visually, not just from source. |

**Already in flight (tracked, not re-scoped here):** terminal-core #13 (mouse
selection + selection-aware copy) and #14/B15 (app bundle); agentd-warp #15 (tool
cancellation + Windows panel parity). These continue under their owners and feed
the next convergence gate alongside S9–S15.

---

## Backlog — ordered by daily-driver impact

Pulled into a sprint when the current sprint clears. IDs map to `next-20-features.md`.

| ID | Task | Owner | Wave | Acceptance Criteria |
| --- | --- | --- | --- | --- |
| B1 | Unicode/grapheme cell model (#2) | terminal-core | 3/4 | ✅ DONE as S9 — `?` fallback killed, box-drawing/Latin-1/BMP/CJK render. Exact combining-mark fidelity continues as B18. |
| B2 | Truecolor + visual render attributes (#3) | terminal-core | 3/4 | ✅ DONE as S10 — underline/double/italic/strike/overline draw on macOS; truecolor + 256-color render. `TERM` capability profile note still worth a follow-up. |
| B3 | Soft-wrap tracking + reflow-aware resize (#4) | terminal-core | 4 | Resizing the window reflows wrapped lines instead of truncating; origin mode + auto-wrap already done; ≥2 reflow tests. |
| B4 | Streaming native pipelines + deadlock tests (#10) | shell-fish | 4 | ✅ DONE as S13 — real OS pipe handles between stages, bounded captures, deadlock test in CI. |
| B5 | Linux native window | terminal-core | 3 | A native Linux desktop window opens, hosts a PTY, renders the grid with the same overlay system as macOS/Windows; shared `Pty` abstraction in `pty.zig` used by all three hosts. |
| B6 | Keyboard + mouse protocol completion (#5) | terminal-core | 4 | Modifier-aware function keys, Alt/meta input, application keypad, focus events, full xterm/SGR mouse button + wheel reports across normal and alt screen; tests per encoding. |
| B7 | Copy mode + selection-aware copy (#15) | terminal-core | 4/5 | Keyboard copy mode with selection, `Ctrl+Shift+F` search jump, prompt-jump via integration events, OSC 8 hyperlink parsing once the cell model supports it. |
| B8 | Quick-select open actions + OSC 8 (#16) | terminal-core | 4/5 | (= returned S12, not started) `Ctrl+Shift+O` adds open actions for URLs/paths/issue keys (not just copy); IPs and command ranges detected; OSC 8 hyperlinks clickable. S9 cell model dependency now satisfied — ready to claim. |
| B9 | Tabs + richer session restore (#17) | terminal-core | 5 | `Session` object = one PTY+grid+scrollback+cwd per tab/split; tab create/close/navigate by keyboard; persisted titles; cwd inheritance on new tab. |
| B10 | Profiles, keybindings, settings UI, theme/prompt sync (#19) | terminal-core / shell-fish | 5 | (theme-sync slice = returned S14, not started) `desktop.conf` `[keybindings]` section honored; settings overlay edits persist; light/dark theme pairs; picking a theme on either shell or desktop updates the other within one frame; ≥2 round-trip tests. Ready to claim. |
| B11 | AgentD hardening — read-only browsing, audit export, build-action approval, provider streaming (#20) | agentd-warp | 4 | Build actions require explicit approval; audit log exportable; provider responses stream into the panel; OSC 777 remains UI context only (not a trust boundary), with a spoofing regression test. |
| B12 | Windows raw interactive input for the shell (#8) | shell-fish | 4 | Cursor editing, redraw, suggestions, tab UX, Ctrl-R, manual echo are first-class when ZiggyZag runs directly inside a Windows terminal. |
| B13 | Install / uninstall / rollback paths for testers | qa / terminal-core | 3 | Documented install + clean-uninstall + rollback that preserve config and history; a tester can roll back without losing shell history. |
| B14 | Cross-platform background job hardening (#11) | shell-fish | 4 | Nonblocking child status hardened on Windows/macOS/Linux; documented which process-group semantics are intentionally absent. |
| B15 | macOS app bundle wrapper (`ZiggyZag.app` + Info.plist + bundle ID) | terminal-core | 3 | (started — `scripts/make-macos-bundle.sh` exists in tree) `zig build` (or a packaging step) emits a `.app` bundle with `CFBundleIdentifier` (e.g. `com.ziggyzag.desktop`), `CFBundleName`, and `LSUIElement=false`. The window registers a real bundle ID instead of NULL, so screen-recording/automation tools and friend-tester support can target it by name. Unblocks the S15 visual QA pass — finish this BEFORE re-scoping S15. |
| B16 | **Split `agent_overlay.zig`** — resolve terminal-core/agentd-warp file collision (TOP process fix) | terminal-core + agentd-warp | 3/4 | **Top process recommendation.** `agent_overlay.zig` is edited by both terminal-core (render/keys) and agentd-warp (protocol/approval), causing collisions. Split into a clear seam: rendering/input layer (terminal-core) vs. AgentD protocol/approval layer (agentd-warp), with a narrow typed interface between them. Define ownership in the file header. Unblocks B17. Do this first next session. |
| B17 | AgentD S7 Enter-guard pure-function test (parked behind B16) | agentd-warp | 3/4 | Extract the "previewed command is inserted, never executed" guard into a pure function and assert it directly (no path appends `\n`/Enter). Parked behind the B16 split so the test targets a stable seam. |
| B18 | Per-cell grapheme buffer for exact combining-mark rendering | terminal-core | 4 | Builds on S9. Each cell holds a small grapheme buffer (base + combining marks) so multi-codepoint clusters render exactly rather than approximately; copy/search respect cluster boundaries. Closes the fidelity gap S9 left open. |

| C | Owner task #23 — CoreText font fallback in `drawGlyph` for color emoji (macOS) | terminal-core (owner) | 3 | IN PROGRESS as board #23, being finished now. drawGlyph gains CoreText font fallback so color emoji render on the macOS path. **Record result here when terminal-core lands it.** Completes the glyph story alongside S9. |

---

## Gates (do not claim "daily-driver ready" until green)

- `zig build`, `zig build test`, shell smoke, desktop launch/close, release artifact QA all pass on the target platform.
- A multi-hour session survives resize, paste, copy, Ctrl+C, large output, full-screen TUI apps, background jobs, and close/reopen.
- Bounded scrollback, clean PTY shutdown, no detached thread using freed state.
- A user can uninstall/roll back without losing shell history.
- Every AgentD action requires explicit approval before touching terminal, filesystem, or build state.

## Anti-goals (this alpha line)

Remote SSH, cloud sync, multiplayer/team features, app-store packaging, embedding/wrapping WezTerm or any non-Zig terminal. Borrow the quality bar, keep the codebase all-Zig.
