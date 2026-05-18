# Windows Debug Session — 2026-05-17

Status: **ConPTY I/O bridge fixed; one input issue still open.** The three
startup/bridge bugs are root-caused and fixed: the desktop spawns the shell,
the shell attaches to the pseudoconsole, bytes flow bidirectionally over the
ConPTY bridge, and the integration handshake is parsed (`status: ready`).
Verified empirically (process tree, byte traces, clean instrumentation-free
build, tests green). **However, typed commands do not yet execute end-to-end**
— Enter (WM_CHAR=13 → CR→LF translation) does not submit a command because the
Windows shell runs under ConPTY cooked line-input mode (`TerminalMode.enable()`
is a no-op stub on Windows). That is a real, separate bug, scoped below.
**`alpha-launch-only` stays in place** until typed-command execution is
verified — the bridge works, but the shell is not yet drivable for real work.

## TL;DR

| # | Symptom | Root cause | Status |
|---|---------|-----------|--------|
| 1 | `Error: CreateProcessFailed` shown in the first pane at launch, no matter how clean the install was | `resolveShellPath`/`resolveAgentPath` returned configured paths (`profile.shell` in `desktop.conf`, `ZIGGYZAG_SHELL_PATH`, `ZIGGYZAG_AGENTD_PATH`) **without checking they existed**, so a stale path fed `CreateProcessW` garbage | Fixed: `existingDup` helper falls through to the next channel when a configured path is missing |
| 2 | Even on a clean install with no config, `CreateProcessW` returned 0 with `GetLastError = 87 (ERROR_INVALID_PARAMETER)` | The desktop builds a UTF-16 environment block via `child_env.createWindowsBlock`, but the creation flags passed to `CreateProcessW` did **not** include `CREATE_UNICODE_ENVIRONMENT` (0x400). Without it, Windows tries to parse the block as ANSI, sees every other byte as NUL, and rejects the call | Fixed: flag added to `dwCreationFlags` in `startPtyForPane` |
| 3 | After both fixes, `CreateProcessW` succeeds, both processes are alive, but the desktop window stays on `starting shell / status:waiting` indefinitely. Typing into the window produces no echo, no characters appear in the pane, and the shell never transitions to `ready` | `dwCreationFlags` included **`CREATE_NO_WINDOW` (0x08000000)**, a console-allocation flag incompatible with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`. The child allocated its *own* hidden conhost instead of attaching to our pseudoconsole's headless conhost; `CreateProcessW` still returned success, and the child's writes succeeded into its private (orphan) console, so no bytes crossed our pipes. A second defect (`UpdateProcThreadAttribute` passed `&hpc` instead of the `hpc` value) was also fixed — isolation-tested as a *separate, milder* failure (handshake stalls but the child still attaches), not identical to the `CREATE_NO_WINDOW` one | **Fixed** (bridge bidirectional). Typed-command execution end-to-end is a **separate open issue** — see "Resolution" |

## What landed in this branch

### Real fixes
- `apps/desktop/src/windows_app.zig` — `existingDup` helper + existence-check
  on every configured path channel in both `resolveShellPath` and
  `resolveAgentPath`.
- `apps/desktop/src/windows_app.zig` — `CREATE_UNICODE_ENVIRONMENT`
  (0x00000400) ORed into the `dwCreationFlags` argument to `CreateProcessW`
  in `startPtyForPane`. Comment block on the constant points back here.
- `apps/desktop/src/windows_app.zig` — **`CREATE_NO_WINDOW` removed** from the
  `dwCreationFlags` argument to `CreateProcessW` in `startPtyForPane`; flags are
  now `EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT`. Comment block
  on the corrected line points back here.
- `apps/desktop/src/windows_app.zig` — `UpdateProcThreadAttribute` now passes
  the `hpc` **value** (`@ptrCast(hpc)`) as `lpValue`, not `&hpc_value`. Matches
  the MS "Creating a Pseudoconsole session" `PrepareStartupInformation` sample
  and Windows Terminal's `ConptyConnection`. Comment block points back here.
- `scripts/doctor-desktop.ps1` — diagnoses and repairs a ZiggyZag install:
  inventories `zig-out/bin`, locates `desktop.conf`, comments out any
  `profile.shell`/`profile.cwd` line whose target doesn't exist (with a
  timestamped `.bak` backup), validates `ZIGGYZAG_*` env overrides, prints
  a coloured summary. Idempotent. `-DryRun` reports only. `-Launch` starts
  `ziggyzag-desktop.exe` after diagnosis. Pure ASCII so it parses under
  Windows PowerShell 5.1's legacy Windows-1252 codepage.

### Debug scaffolding (removed before commit)
During the investigation the desktop and shell were instrumented with file
loggers that wrote step-by-step traces to `%TEMP%\ziggyzag-startup.log` and
`%TEMP%\ziggyzag-shell-boot.log`. They were stripped before commit — the
fixes above stand on their own. If the remaining bug is picked up again,
re-adding similar instrumentation is the fastest path back to the failure
point.

## Resolution — PTY I/O bridge fixed

### Root cause

`CreateProcessW` was called with
`EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT`.
**`CREATE_NO_WINDOW` (0x08000000) is a console-allocation flag and is
incompatible with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`.** When both are
present, Windows honours the console-allocation flag: the child gets its own
fresh (hidden) conhost instead of being wired to our pseudoconsole's headless
conhost. `CreateProcessW` *still returns success*, the child's stdout writes
*still succeed* — into its private orphan console that nothing reads — so the
desktop's `readLoop` never sees a byte and the window sits on
`status:waiting` forever. Microsoft's "Creating a Pseudoconsole session" doc
and the Win32 "Process Creation Flags" reference both state plainly that
`CREATE_NEW_CONSOLE`/`CREATE_NO_WINDOW` must not be combined with a
pseudoconsole; the MS EchoCon sample uses **only** `EXTENDED_STARTUPINFO_PRESENT`.

A second defect was fixed in the same pass: `UpdateProcThreadAttribute` was
passed `&hpc_value` (a pointer to the HPCON) as `lpValue`. The MS sample and
Windows Terminal's `ConptyConnection` both pass `hpc` directly. This was
**tested in isolation** (revert to `&hpc_value`, keep `CREATE_NO_WINDOW`
removed, rebuild, inspect process tree): the result was *not* the same as the
`CREATE_NO_WINDOW` failure. With `&hpc_value` the child **still attached** to
the pseudoconsole (0 child conhost processes), but the integration handshake
did **not** reach `status: ready` within the observation window, whereas the
canonical `@ptrCast(hpc)` form reached `ready` reliably across repeated runs.
So `&hpc_value` was genuinely wrong and worth fixing — but the earlier
characterisation that it "would have broken the bridge identically" was an
unverified guess and is now corrected: its failure mode is a stalled
handshake, not a dead bridge. The canonical form is what we ship.

### How it was diagnosed

A two-pronged instrumentation (file loggers to `%TEMP%\ziggyzag-startup.log`
and `%TEMP%\ziggyzag-shell-boot.log`, since stripped) made it decisive:

1. **Shell side:** a *raw* `WriteFile` to `GetStdHandle(STD_OUTPUT_HANDLE)`
   before any `std.Io.Writer` exists. It reported `ok=true written=22` —
   yet the desktop `readLoop` logged `available=0` forever. Because even the
   raw OS write (bypassing all Zig std I/O) didn't cross, the Zig
   positional-writer theory was ruled out and the bug was localised to the
   ConPTY bridge itself, not either process's logic.
2. **Process-tree analysis** (`Get-CimInstance Win32_Process`) was the clincher:
   the pseudoconsole's headless conhost spawned correctly
   (`conhost.exe --headless --width 120 --height 32`, matching the grid), but
   `ziggyzag.exe` had its **own separate** `conhost.exe …\conhost.exe 0x4`
   child — proof the child allocated a private console instead of attaching
   to the pseudoconsole.

A web check against current Microsoft Learn docs and corroborating sources
confirmed `CREATE_NO_WINDOW` + pseudoconsole as the documented incompatibility
— this is a known pitfall others have hit, not a ConPTY or Zig bug.

### Verified fixed — the bridge (clean, instrumentation-free build)

- `readLoop`: 239-byte ConPTY emission received within ~1s of `CreateProcessW`
  (raw marker + VT init + `session.ready` + prompt), then idle — the shell→
  desktop path works.
- Sent `echo hi` via `WM_CHAR`: `readLoop` saw exactly 7 single-byte echoes
  — bytes reach the pseudoconsole's input pipe and the cooked-mode console
  echoes them back. Whether the shell's stdin reader has consumed any of
  them before Enter is not separately verified (in cooked mode the console
  buffers the line until CR, so likely it has not).
- Window title transitions `ZiggyZag - starting - starting` →
  `ZiggyZag - starting - ready` (confirmed reliable across repeated runs of
  the canonical build): the integration handshake is parsed.
- Process tree: `ziggyzag.exe` has **0 child processes** — attached to the
  pseudoconsole's headless conhost, no private conhost.
- `zig build test --summary all`: 193 pass, 2 skip, 0 fail, after fixes and
  after all instrumentation was removed.

### Open issue — typed commands do not execute end-to-end (NOT cosmetic)

This blocks calling the Windows host "drivable" and is why
`alpha-launch-only` stays. Scoped here as the next bug, not hand-waved:

- **Symptom:** sending `echo hi` then Enter via `WM_CHAR` echoed the 7 chars
  but produced **no command output and no new prompt**. The bridge carried
  the bytes (echo proves it); the *command* never ran.
- **Root cause (identified, not yet fixed):** on Windows
  `TerminalMode.enable()` is a no-op stub returning `null`, so the shell
  never switches the console to raw mode. ConPTY therefore runs the shell
  in **cooked line-input mode** (`ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT`).
  The desktop's `handleChar` translates the Enter key CR→LF
  (`'\r' => app.writeInput("\n")`, windows_app.zig:2461) — correct for a
  raw-mode VT app, but cooked-mode console line input terminates on **CR**,
  not LF, so the line is never delivered to the shell and the char-by-char
  `readLine` never sees a submit. (The exact interaction — synthetic
  `PostMessageW` delivery vs. real keystroke vs. console mode — was not
  exhaustively isolated; cause is strongly indicated but the fix is
  unverified.)
- **Likely fix directions** (next session): either (a) implement a real
  Windows `TerminalMode.enable()` that sets the ConPTY client into raw mode
  (clear `ENABLE_LINE_INPUT|ENABLE_ECHO_INPUT|ENABLE_PROCESSED_INPUT`,
  matching the POSIX raw-mode path so the shell's own line editor + manual
  echo drive the line), or (b) if staying cooked, stop the CR→LF rewrite so
  Enter delivers CR. (a) is the consistent choice (the shell's `readLine`
  is built for raw mode and already does its own editing/echo).
- **Verification owed:** a human opens the window and types a real command;
  it must execute and a new prompt must render. Synthetic `WM_CHAR` is not
  sufficient proof.

### Secondary cosmetic items (do not block)

- `ziggyzag-desktop.exe` is itself a *console* subsystem binary, so it spawns
  a `conhost.exe …0x4` of its own (possible brief console flash). Fix: link
  the desktop as the `windows` subsystem.
- The title's first segment still reads `starting` (the per-command/pane
  label) even though `status` is `ready`. Display-only.

---

## Appendix — original investigation notes (kept for provenance)

### Trace recovered before instrumentation removal

The final captured boot trace (`%TEMP%\ziggyzag-startup.log` +
`%TEMP%\ziggyzag-shell-boot.log`) — `2026-05-17 20:36`:

```
--- DESKTOP startup log ---
[resolveShellPath] returned: C:\Users\pasca\dev\ZiggyZag\zig-out\bin\ziggyzag.exe
[startPtyForPane] CreateProcessW: shell='...\ziggyzag.exe' cwd='C:\Users\pasca\dev\ZiggyZag'
[startPtyForPane] CreateProcessW OK

--- SHELL boot log ---
=== shell main() entered ===
shell.init() returned
=== shell run() entered ===
stdin/stdout wired
after loadStartupConfig
after rememberCurrentDirectory
after TerminalMode.enable
before writeIntegrationSessionReady
after writeIntegrationSessionReady
before writePrompt
after writePrompt
```

The shell ran every boot step cleanly. **Both `writeIntegrationSessionReady`
and `writePrompt` returned without throwing — the writes succeeded.** The
shell is now blocked on `readLine(&stdin.interface, …)` waiting for stdin
input that never arrives.

Yet the desktop's pane is empty. So bytes leave the shell, but they never
appear on the desktop's `output_read` handle. The bug is in the bridge
between the two processes — ConPTY, the pipes, or the handle inheritance —
not in either process's logic.

### What we know
- `CreateProcessW` returns success (logged "OK" before instrumentation was
  removed; verified with `GetLastError` returning 0).
- `Get-Process ziggyzag*` shows both processes alive: `ziggyzag-desktop`
  hosting the window and `ziggyzag` as the spawned shell.
- `ziggyzag-agentd` is **not** running, which is correct — AgentD is started
  lazily from `openAgentPanel`/`writeAgentLine`, not at boot.
- The window title reads `ZiggyZag - starting - starting` and the status bar
  reads `starting shell | status:waiting | last:n/a`. The title transitions
  out of `starting` only when the shell emits an integration handshake the
  desktop's parser recognizes.
- Typing into the window via `computer-use` produced no visible effect — no
  character echo, no pane redraw, status bar unchanged.

### What's known to be correct
- The resolver returns the right path:
  `C:\Users\pasca\dev\ZiggyZag\zig-out\bin\ziggyzag.exe`. Verified via the
  removed startup log.
- The cwd handed to `CreateProcessW` is sensible:
  `C:\Users\pasca\dev\ZiggyZag`.
- On Windows, `TerminalMode.enable()` is a no-op stub (returns `null`), so
  the shell does not block on terminal-mode setup.
- The shell's `init()` is trivial struct setup, no I/O. It's not stuck there.
- The desktop's `readLoop` is a clean `PeekNamedPipe`/`ReadFile` loop with
  a 16ms sleep on empty, terminating on `pane.running` going false. It's
  alive and waiting — it just never sees bytes.
- `WM_CHAR` → `handleChar` → `app.writeInput` → `WriteFile(pane.input_write, …)`
  is a straight path with no obvious failure. The handle is non-null because
  `CreatePipe` succeeded before `CreateProcessW` ran.

### Likely failure points (ranked)
1. **`CreatePipe` produced non-inheritable handles.** `CreatePipe` defaults
   to non-inheritable. For ConPTY the pipe handles are not inherited directly
   — they're handed to `CreatePseudoConsole` instead, which manages its own
   inheritance via `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`. **This is probably
   not the problem,** but it's worth double-checking that ConPTY actually
   wires the child's stdin/stdout to our pipes and isn't silently dropping
   data because of a flag mismatch.
2. **`CreatePseudoConsole` size is zero or invalid at boot.** The size is
   `@min(pane.grid.width, 300), @min(pane.grid.height, 120)`. If `pane.grid`
   hasn't been sized yet at PTY-start time (e.g., the WM_SIZE handler hasn't
   fired before `startPty`), the PTY could be created at 0×0 and ConPTY may
   refuse to flush. Check `pane.grid.width/height` immediately before
   `CreatePseudoConsole`.
3. **`pty_input_read` is closed too early.** The desktop closes
   `pty_input_read` and `pty_output_write` after `CreateProcessW` returns
   (lines 791-792). That's correct — ConPTY duplicated them into the child's
   handle table. But if there's an ordering bug, the child could end up with
   broken stdin/stdout.
4. **The shell's `std.Io.File.stdout()` writer is buffering with no flush.**
   The shell opens stdout with `writer(self.io, &.{})` (empty buffer) which
   *should* be unbuffered, but Zig 0.16's `std.Io.Writer` semantics are
   evolving — verify that a write through `stdout.interface.writeAll(…)`
   actually reaches the underlying file handle synchronously.
5. **ConPTY is holding output until a screen-state change.** ConPTY's known
   behaviour is to only emit VT sequences when its internal screen buffer
   changes meaningfully. If the shell prints something that doesn't move
   the cursor (e.g., a zero-width OSC sequence the parser doesn't recognise
   as cursor-relevant), ConPTY might genuinely sit on it. Long shot but
   worth ruling out with a forced `\r\n` write at boot.

### Suggested next steps (Mac-first or anyone)
1. **Don't keep debugging Windows ConPTY through Cowork.** The path-mapping
   between the sandbox and the user's real filesystem, plus the need for
   `.bat` wrappers triggered by Run/File Explorer, makes the loop too slow.
   Run `zig build` from a real terminal and read `%TEMP%\…` logs directly.
2. **Pivot to macOS.** `apps/desktop/src/posix_app.zig`'s `runNativeWindow`
   is a scaffold returning `error.NotImplemented`. Implementing the native
   macOS path (Cocoa via the Objective-C runtime, or a cross-platform layer
   like webview) sidesteps every Windows-specific quirk above.
3. **If returning to Windows:** re-add the instrumentation in this doc's
   "What we know" section and watch which `boot_log.write(…)` line is the
   last one to appear in `%TEMP%\ziggyzag-shell-boot.log`. The bug is
   either before that line in the shell, or — more likely — the desktop
   never receives the bytes the shell did write.

## Tests still green
All three fixes are in ConPTY runtime paths that the `zig build test` suite
doesn't exercise (it doesn't spawn pseudoconsole children), so the suite is
unaffected: **193 passed, 2 skipped, 0 failed** (`zig build test --summary
all`) after the fixes and after instrumentation removal. Validation is
empirical, per fix:
- Resolver fix: doctor script run on a synthetic stale `desktop.conf`
  produces a backup and comments out the stale line; runs idempotent
  thereafter.
- `CREATE_UNICODE_ENVIRONMENT` fix: `CreateProcessW` GetLastError goes from
  87 (ERROR_INVALID_PARAMETER) to 0 (success).
- `CREATE_NO_WINDOW` removal + HPCON-value fix: see "Verified fixed" above —
  bytes flow bidirectionally, handshake parsed, shell attached to the
  pseudoconsole (0 child processes), in a clean instrumentation-free build.

## Honesty
Honest about both wins and losses, per the brand:
- **Wins:** the three startup/bridge bugs are genuinely fixed. #1 would have
  hit every friend upgrading an old install; #2 was dormant on any clean
  Windows machine; #3 (`CREATE_NO_WINDOW`) made the bridge silently dead. The
  ConPTY bridge now carries bytes bidirectionally, proven empirically in a
  clean build with the test suite green.
- **Loss / not done:** typed commands do not execute end-to-end yet. Enter
  doesn't submit (cooked-mode vs. CR→LF, root cause identified, fix not
  written or verified). A terminal where you can't run a command is **not a
  usable shell**, so `alpha-launch-only` **stays** and this is not shipped as
  "working". The bridge being fixed is real progress; claiming the host is
  drivable would be the overstatement this section exists to catch.
- **Process honesty:** the `&hpc → hpc` change was initially asserted (by me
  and the advisor) to be a bridge-killer "identical" to `CREATE_NO_WINDOW`.
  That was an untested pattern-match against the MS sample. The first build
  with only that change applied did **not** fix the bridge — `CREATE_NO_WINDOW`
  did. Isolation testing afterward showed `&hpc_value` is wrong but milder
  (stalled handshake, child still attaches). The doc and code comment now
  state the tested behaviour, not the guess.
- The shell, AgentD, and the POSIX launcher remain solid; the Windows native
  host's bridge was the broken piece and is fixed — input semantics are the
  next piece.
