# Windows Debug Session — 2026-05-17

Status: two real bugs fixed and shipped, one bug remaining. Pausing Windows
work to focus on the macOS implementation; this doc captures the state of the
investigation so it can be resumed without re-deriving everything.

## TL;DR

| # | Symptom | Root cause | Status |
|---|---------|-----------|--------|
| 1 | `Error: CreateProcessFailed` shown in the first pane at launch, no matter how clean the install was | `resolveShellPath`/`resolveAgentPath` returned configured paths (`profile.shell` in `desktop.conf`, `ZIGGYZAG_SHELL_PATH`, `ZIGGYZAG_AGENTD_PATH`) **without checking they existed**, so a stale path fed `CreateProcessW` garbage | Fixed: `existingDup` helper falls through to the next channel when a configured path is missing |
| 2 | Even on a clean install with no config, `CreateProcessW` returned 0 with `GetLastError = 87 (ERROR_INVALID_PARAMETER)` | The desktop builds a UTF-16 environment block via `child_env.createWindowsBlock`, but the creation flags passed to `CreateProcessW` did **not** include `CREATE_UNICODE_ENVIRONMENT` (0x400). Without it, Windows tries to parse the block as ANSI, sees every other byte as NUL, and rejects the call | Fixed: flag added to `dwCreationFlags` in `startPtyForPane` |
| 3 | After both fixes, `CreateProcessW` succeeds, both processes are alive, but the desktop window stays on `starting shell / status:waiting` indefinitely. Typing into the window produces no echo, no characters appear in the pane, and the shell never transitions to `ready` | The shell is launched, but I/O over the ConPTY pipe is not flowing in either direction. The desktop's `readLoop` never sees the shell's `writeIntegrationSessionReady` output, and the shell's stdin doesn't see characters from `WM_CHAR` forwarded via `pane.input_write` | **Open** — see "Remaining bug" below |

## What landed in this branch

### Real fixes
- `apps/desktop/src/windows_app.zig` — `existingDup` helper + existence-check
  on every configured path channel in both `resolveShellPath` and
  `resolveAgentPath`.
- `apps/desktop/src/windows_app.zig` — `CREATE_UNICODE_ENVIRONMENT`
  (0x00000400) ORed into the `dwCreationFlags` argument to `CreateProcessW`
  in `startPtyForPane`. Comment block on the constant points back here.
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

## Remaining bug — PTY I/O bridge not flowing

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
Both fixes are in code paths that the `zig build test` suite doesn't exercise
(test suite doesn't spawn ConPTY children), so the test suite reports the
same green it always has. The fixes are validated by:
- Resolver fix: doctor script run on a synthetic stale `desktop.conf`
  produces a backup and comments out the stale line; runs idempotent
  thereafter.
- `CREATE_UNICODE_ENVIRONMENT` fix: `CreateProcessW` GetLastError goes from
  87 (ERROR_INVALID_PARAMETER) to 0 (success). Both processes appear in
  `Get-Process ziggyzag*` afterwards.

## Honesty
Honest about both wins and losses, per the brand:
- **Wins:** two real bugs root-caused and fixed. The first would have hit
  every friend who tried to upgrade an old install; the second was a
  dormant bug that would have shown up on any clean Windows machine the
  moment someone tried to run it.
- **Loss:** the PTY I/O bridge bug isn't fixed yet. The desktop builds, the
  shell launches, no `CreateProcessFailed` ever appears — but the window
  doesn't actually become usable. Marking Windows desktop as
  **"alpha-launch-only"** in the docs until the I/O bridge is sorted is the
  right move. Don't ship it as "working".
