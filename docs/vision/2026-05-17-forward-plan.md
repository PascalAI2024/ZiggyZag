# Forward Plan — Post Windows-Fix (2026-05-17)

A synthesis filed after the Windows ConPTY bridge was repaired. The
[masterplan](masterplan.md) remains the strategic source of truth; this
document is the executable read of "what now" and is meant to be absorbed
into the masterplan at the next wave gate (per masterplan §"How this document
is maintained"). Companion record: [`../reviews/2026-05-17-windows-debug.md`](../reviews/2026-05-17-windows-debug.md).

## What actually changed

The Windows native desktop host was un-drivable for the project's whole life
— it spawned a shell but no bytes crossed the ConPTY bridge and typed
commands never executed. Four bugs were root-caused and fixed this session
and the host is now verified driving a live shell. This does not unlock
Wave 3; it makes the Windows host usable as the reference the cross-platform
work will be proven against.

## Step 0 — done (corrected 2026-05-18)

**Honesty correction.** An earlier revision of this doc (and the masterplan
Move 2 text) stated `pty.zig` was a non-wired stub with all backends
returning `error.NotImplemented` and ConPTY living inline in
`windows_app.zig`. That described the *committed* tree at the time it was
written, but it was filed as a forward fact without noting it was about to
change — and the "Step 0" it implied as unstarted work has since been
**completed and verified this session**. The brand is radical honesty,
including about our own planning docs: this section is rewritten to the
verified state, not left as an aspirational claim.

Current verified reality: `apps/desktop/src/pty.zig` exposes a real `Pty`
vtable; the **Windows ConPTY backend is fully wired** behind it
(`Pty.spawn` → `CreatePseudoConsole`, the session's three bug-fixes
preserved — `EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT`,
no `CREATE_NO_WINDOW`, `@ptrCast(hpc)` by value). `windows_app.zig` calls
`pty_module.Pty.spawn` and consumes via `pty.read`/`resize`/`deinit`; zero
inline Win32 PTY code remains. Reader-thread model: stays app-side
(it runs the integration parser, holds `app.mutex`, feeds the grid) — the
backend owns only the OS handles; documented in `pty.zig`. Verified: `zig
build test` 196/198, and a live no-regression run (title→`ok`, cwd updates
with single backslashes, shell has 0 child processes). The **POSIX
backends remain honest `error.NotImplemented` stubs** — that is the real
remaining Wave 3 work (native macOS/Linux), not the ConPTY wiring.

## Execution order (12h/week, masterplan-cited)

Effort is honest at the masterplan's solo 12h/week cap (masterplan §Risks).

| # | Item | Masterplan | Effort | Weeks | Top risk |
|---|---|---|---|---|---|
| **GIF** | Demo GIF from `scripts/demo.sh` | success metric (≤2MB/≤10s) | S (~2h) | ~0.2 | none — cheapest "10-second wow"; zero new code |
| **0** | ~~Lift ConPTY behind the `pty.Pty` vtable~~ — **DONE 2026-05-18** (verified green + no live regression) | prerequisite to Move 2 | — | done | reader-thread stays app-side (documented in `pty.zig`); POSIX backends still stubs |
| **3** | AgentD universal input (`Ctrl+Space` → NL → command preview, insert-not-execute) | Move 3 / W3 | M (~15h) | ~2 | LLM response quality; a tight `agent/suggest` system prompt; approval-sacred (Principle 4) holds — never auto-execute |
| **2a** | Native macOS host (Cocoa via Obj-C runtime, all-Zig, Principle 5) | Move 2 / W3 | L (~50h) | ~4–5 mo | Core Text font-metric vs grid cell-width mismatch |
| **2b** | Native Linux host (X11/Xlib; XWayland ok, native Wayland deferred) | Move 2 / W3 | M (~25h) | ~2 mo | XWayland clipboard/IME; Wayland-native = out of scope for W3 |
| **4** | SQLite history backend (spec complete: `../reference/history-backend.md`) | Move 4 / W4 | M (~15h) | ~2 | `zig build` time regression from the amalgamation (CI gate ≤30s) |
| **5** | Streaming pipelines + deadlock corpus | Move 5 / W4 | M (~15h) | ~2 | cross-platform pipe semantics divergence |
| **6** | Tabs + `Session` abstraction | Move 6 / W5 | L (~35h) | ~3 | `Pane`→`Session` refactor across a ~2500-line file |
| **7** | 1.0 friend-cohort sign-off | Move 7 / W6 | — | blocked | the 5-tester daily-driver gate cannot be met before the POSIX hosts exist |

Wave 3, done honestly, is roughly **six months of 12h weeks**. "Wave 3 by
end of 2026" is honest; sooner is not.

With Step 0 done, the next immediately-actionable items are the demo GIF
(already a masterplan success metric, zero code, closes the "10-second wow"
gap) and the copy/paste + QoL quick wins surfaced by the feature research
(multi-line paste guard, trailing-newline trim, right-click paste, Ctrl+scroll
zoom) — all small, config-toggleable, masterplan-compliant. The real Wave 3
weight is now the POSIX native backends (2a/2b), unblocked by the wired vtable.

## Scope discipline — temptations rejected

Surfaced during research and declined, each against a masterplan constraint:
GPU rendering (Principle 5 — Core Graphics/XRender first), Warp-style
auto-execute (Principle 4 — insert-not-execute is the hard line), Lua/scripting
config (SCOPE.md), cloud history sync / accounts (non-goals), SSH multiplexing
(non-goals), Kitty/Sixel graphics (not in scope), native Wayland in W3
(deferred), plugin marketplace (non-goals), external agent/MCP surface
(AgentD is local-only), auto-update (no wave gate commits to it). Per the
masterplan, any scope addition requires a corresponding deletion.

## Competitive read (2026, for positioning only)

Ghostty (Zig, GPU, native Cocoa) is the strongest technical comparator —
ZiggyZag does not compete on render speed; it competes on shell-as-source-of-
truth, a codebase readable in a weekend, and approval-aware AgentD. Warp is
cloud-first/account-required and auto-executes; ZiggyZag is local-first and
insert-not-execute. WezTerm is the daily-driver baseline with no AI. Wave is
Electron. None combine all-Zig + local-first + approval-sacred + readable —
that is the defensible position. Sources: ghostty.org, warp.dev, wezterm.org,
waveterm.dev (retrieved 2026-05).
