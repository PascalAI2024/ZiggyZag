# Daily-Driver QA

Use this checklist when deciding whether ZiggyZag is safe enough to use as a main terminal for a day. It operationalizes the gates in [NEXT_20_FEATURES.md](NEXT_20_FEATURES.md) and is written for friends testing tomorrow.

This is stricter than the alpha smoke pass. A smoke pass means "the build starts and basic features work." A daily-driver pass means "the app stayed boring while a real person used it."

## Fast Start

From the repo root on Windows:

```powershell
.\scripts\daily-driver-qa.ps1 -Automated
```

To print the manual checklist without running builds:

```powershell
.\scripts\daily-driver-qa.ps1 -PrintOnly
```

To create a report template for a tester:

```powershell
.\scripts\daily-driver-qa.ps1 -PrintOnly -ReportPath .\daily-driver-report.md
```

On macOS/Linux, run the platform smoke commands in [QA_TOMORROW.md](QA_TOMORROW.md), then use the manual sections below. The current POSIX desktop artifact is a terminal-attached launcher, not a native graphical window.

## Entry Gate

Record:

- Tester name or handle:
- Date:
- OS and version:
- CPU architecture:
- Zig version:
- Commit:
- Artifact or local build path:
- Terminal used to launch ZiggyZag:

Before the long session, run:

```powershell
zig build
zig build test
.\scripts\smoke.ps1
.\scripts\qa-tomorrow.ps1
```

On macOS/Linux:

```sh
zig build
zig build test
./scripts/smoke.sh
./zig-out/bin/ziggyzag-agentd --describe-tools
printf '%s\n' '{"id":1,"method":"agent/health"}' | ./zig-out/bin/ziggyzag-agentd --stdio
printf 'exit\n' | zig build run-desktop
```

Expected:

- All commands exit cleanly.
- Windows desktop launch/close smoke passes.
- POSIX desktop launcher prints its backend and exits after `exit`.
- AgentD returns valid JSON for tool discovery and health.

## Main-Terminal Session

Run one interactive session for at least 2 hours. Prefer 4 hours if the tester can leave it open during normal work.

During the session:

- Open the shell or desktop host from the release artifact being tested.
- Resize the window at least 10 times, including very narrow and very wide sizes.
- Paste at least one multi-line command block.
- Copy visible terminal text and paste it into a separate editor.
- Run at least 25 normal commands across 3 directories.
- Close and reopen the app once, then confirm prompt state is sane and configured history still loads.

Pass:

- No crash, freeze, or runaway CPU.
- Prompt returns after every command.
- Resize does not corrupt the prompt beyond the current known rendering limitations.
- Close/reopen does not lose existing shell history when `HISTFILE` or `ZIGGYZAG_HISTORY_DB` is configured.

Fail:

- Any hang that requires killing the process.
- Any crash or window disappearing unexpectedly.
- Detached child processes survive after closing the desktop host.
- History is deleted or truncated unexpectedly.

## Large Output And Scrollback

Run inside ZiggyZag on Windows:

```powershell
powershell -NoProfile -Command "1..5000 | ForEach-Object { 'ziggyzag large output line ' + $_ }"
```

Run inside ZiggyZag on macOS/Linux:

```sh
seq 1 5000
```

Then:

- Scroll back to the first 100 lines.
- Scroll to the bottom.
- Run a short command such as `echo after-large-output`.
- Resize the window and confirm the prompt is still usable.

Pass:

- Output remains bounded and the app stays responsive.
- The prompt appears at the bottom after the large output.
- The next command runs normally.

## Ctrl+C And Ctrl+D

Run a long command:

```powershell
powershell -NoProfile -Command "Start-Sleep -Seconds 60"
```

On macOS/Linux:

```sh
sleep 60
```

Then:

- Press Ctrl+C and confirm the process stops.
- Start a fresh shell prompt.
- Press Ctrl+D on an empty line.

Pass:

- Ctrl+C interrupts the foreground command without closing the terminal host.
- Ctrl+D exits the shell cleanly only when the input line is empty.
- A later relaunch starts normally.

## Full-Screen TUIs

Try at least one full-screen app available on the tester machine:

- `vim`, `nvim`, `nano`, `less`, `top`, `htop`, `tig`, or `git log --oneline --graph --decorate --all`.

Check:

- Alternate-screen entry and exit.
- Arrow keys, Enter, Escape, Backspace.
- Mouse wheel if the app supports it.
- Window resize while the TUI is open.
- Return to a usable prompt after quitting.

Pass:

- The TUI can be used and exited without trapping the terminal in an unusable state.
- The main scrollback and prompt are still usable after exit.

## Background Jobs

Run:

```powershell
powershell -NoProfile -Command "Start-Sleep -Seconds 5; Write-Output done" &
jobs
```

On macOS/Linux:

```sh
sleep 5 &
jobs
```

Then:

- Wait for the job to finish.
- Run `jobs` again.
- Start another background job and close/reopen the terminal host after it completes.

Pass:

- Jobs appear while running.
- Completed jobs are reaped.
- Prompt latency stays normal while a background job exists.

## Prompt Latency

Check prompt responsiveness in:

- A small directory.
- The repo root.
- A large git checkout if the tester has one.
- A network or synced folder if available.

Use:

```text
timeit prompt
```

If `timeit prompt` is not supported on the current build, use a stopwatch and press Enter on an empty prompt 20 times.

Pass:

- Normal prompt draws feel instant.
- Slow project/git status never blocks interaction for more than 1 second without a visible reason.
- Prompt remains responsive after a failed command and after Ctrl+C.

## Crash Recovery

Do not intentionally corrupt user data. Use a disposable test directory.

Check:

- Close the window while a foreground command is idle.
- Close the window after a large-output command finishes.
- Close the window while a background job exists.
- Relaunch and run `history --stats`, `doctor`, and `pwd`. For history persistence checks, set `HISTFILE` or `ZIGGYZAG_HISTORY_DB` to a disposable path before the test.

Pass:

- Relaunch works without manual cleanup.
- History remains present.
- Temporary files or child processes do not pile up.

## Install And Rollback

For release artifacts:

- Expand the new zip into a fresh directory.
- Run shell, AgentD, and desktop smoke commands from that directory.
- Keep the previous zip expanded in a separate directory.
- Launch the previous version after testing the new version.
- Confirm both versions can be removed by deleting their extracted directories.

Pass:

- New and previous versions can run side by side from separate folders.
- Deleting the extracted app folder does not delete user history stored outside the artifact directory through `HISTFILE` or `ZIGGYZAG_HISTORY_DB`.
- Rollback to the previous extracted version works without changing global machine state.

## AgentD Approval Safety

Run:

```powershell
zig build run-agentd -- --describe-tools
```

Then:

```powershell
@'
{"id":1,"method":"tools/list"}
{"id":2,"method":"tools/call","tool":"terminal.write","text":"echo approval-check\n"}
'@ | .\zig-out\bin\ziggyzag-agentd.exe --stdio
```

Expected:

- `terminal.write` is listed as a tool.
- `terminal.write` returns a host action or approval-shaped response.
- It does not directly write into the terminal by itself.

Pass:

- Read-only tools can return data.
- Terminal writes, builds, filesystem writes, and similar state-changing actions require explicit host/user approval before taking effect.
- The exact text or command is visible before it is applied.

## Platform Runtime Smoke Expectations

Windows:

- `.\zig-out\bin\ziggyzag.exe` runs help and exits.
- `.\zig-out\bin\ziggyzag-agentd.exe --describe-tools` lists tools.
- `.\zig-out\bin\ziggyzag-desktop.exe` opens a native window and closes cleanly.
- `.\zig-out\bin\ziggyzag-launcher.exe` opens the friendly launcher path and closes cleanly.

macOS/Linux:

- `./zig-out/bin/ziggyzag` runs help and exits.
- `./zig-out/bin/ziggyzag-agentd --describe-tools` lists tools.
- `printf 'exit\n' | zig build run-desktop` starts the terminal-attached launcher, prints the selected backend, and exits cleanly.
- A native graphical POSIX desktop window is not expected in this alpha.

## Report Template

Use this result line for each section:

```text
Section:
Result: PASS / WARN / FAIL / SKIP
Notes:
Repro command:
Screenshot or log path:
```

Daily-driver ready means every entry gate passes, every platform runtime smoke expectation for the target platform passes, and the main-terminal session has no FAIL result.
