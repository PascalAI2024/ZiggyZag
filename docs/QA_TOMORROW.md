# Alpha QA Checklist

Date: 2026-05-15
Primary verification machine: Windows, PowerShell
Repo: `C:\Users\pasca\dev\ZiggyZag\codecrafters-shell-zig`
Zig version: `0.16.0`

This checklist is for the current alpha line. Windows testers get the full native desktop host. macOS/Linux testers get the ZiggyZag shell, AgentD, smoke script, and a terminal-attached desktop launcher that uses the native POSIX PTY relay when available, then `script(1)`, then direct stdio; a native POSIX graphical window is not expected yet.

For main-terminal readiness, use [DAILY_DRIVER_QA.md](DAILY_DRIVER_QA.md) after this alpha smoke checklist passes. That pass covers multi-hour sessions, large output, Ctrl+C/Ctrl+D, full-screen TUIs, background jobs, prompt latency, crash recovery, install/rollback, AgentD approval safety, and platform runtime expectations.

## Fast Rerun On Windows

Run this from the repo root:

```powershell
.\scripts\qa-tomorrow.ps1
```

The script keeps running after failures, summarizes each step, and detects the WinGet Zig install when `zig` is not on `PATH`.

For release artifacts, set `$Version` to the release tag you are validating:

```powershell
$Version = "v0.1.0-alpha.2"
.\scripts\build-release.ps1 -Version $Version
.\scripts\qa-release-artifacts.ps1 -Version $Version
```

Use a temporary version such as `v0.1.0-alpha.2-local-qa` when validating packaging without touching the published artifact directory.

## Fast Rerun On macOS/Linux

Run this from the repo root:

```sh
zig build
zig build test
./scripts/smoke.sh
./zig-out/bin/ziggyzag-agentd --describe-tools
printf '%s\n' '{"id":1,"method":"agent/health"}' | ./zig-out/bin/ziggyzag-agentd --stdio
printf 'exit\n' | zig build run-desktop
```

Expected POSIX desktop result: `zig build run-desktop` prints `ZiggyZag Desktop (POSIX PTY)`, launches ZiggyZag in the calling terminal through the native POSIX PTY relay when available, consumes `exit`, and exits cleanly. It does not open a separate terminal window in this alpha. If native PTY setup fails, the launcher should fall back to `script(1)` and then direct stdio.

## Readiness Gate

Do not hand the Windows build to friends until these pass on the tester machine:

```powershell
zig build
zig build test
.\scripts\smoke.ps1
.\scripts\qa-tomorrow.ps1
```

If `zig` is not recognized after installing Zig, open a fresh PowerShell window or add the Zig 0.16.0 directory to `PATH`.

Do not hand macOS/Linux artifacts to friends until these pass on that platform:

```sh
zig build
zig build test
./scripts/smoke.sh
./zig-out/bin/ziggyzag-agentd --describe-tools
```

## Cross-Build And Archive QA

Run from the repo root on Windows:

```powershell
$Version = "v0.1.0-alpha.2"
.\scripts\build-release.ps1 -Version $Version
.\scripts\qa-release-artifacts.ps1 -Version $Version
```

Expected artifact names:

- `ZiggyZag-$Version-windows-x86_64.zip`
- `ZiggyZag-$Version-linux-x86_64.zip`
- `ZiggyZag-$Version-linux-aarch64.zip`
- `ZiggyZag-$Version-macos-x86_64.zip`
- `ZiggyZag-$Version-macos-aarch64.zip`
- `checksums.sha256`
- `release-manifest.json`

The archive QA script checks:

- All five expected zips exist.
- Each zip expands cleanly.
- Each artifact contains a top-level `ZiggyZag` launcher, `bin/ziggyzag-launcher`, `bin/ziggyzag`, `bin/ziggyzag-agentd`, and `bin/ziggyzag-desktop` with `.exe` suffixes for Windows.
- Linux binaries have ELF headers, macOS binaries have Mach-O headers, and Windows binaries have PE/MZ headers.
- The extracted Windows zip can run shell help, AgentD tool discovery, top-level launcher smoke, and desktop launch/close smoke.

The build script writes `checksums.sha256` and `release-manifest.json` next to the zips. Use those files when uploading or verifying release downloads.

The Windows host cannot execute Linux or macOS binaries directly. Those runtime smokes must happen on real Linux/macOS machines or CI runners using the release-zip commands below.

## Latest Local Verification

Latest run:

```powershell
.\scripts\qa-tomorrow.ps1
```

Result: all checks passed on Windows with Zig 0.16.0.

The AgentD health check returned valid `ok:true` JSON. The real provider call returned a structured `provider_error` because Ollama was not reachable on `127.0.0.1:11434`; that is acceptable for protocol testing and is covered by the script.

Latest release artifact run:

```powershell
.\scripts\build-release.ps1 -Version "v0.1.0-alpha.2-local-qa"
.\scripts\qa-release-artifacts.ps1 -Version "v0.1.0-alpha.2-local-qa"
```

Result: all five cross-built zips were produced; archive expansion, expected-binary checks, binary-header checks, extracted Windows shell smoke, extracted Windows AgentD smoke, and extracted Windows desktop launch/close smoke passed.

## Manual Windows Friend-Test Script

Use this order after the scripted checks:

1. Run `.\zig-out\bin\ziggyzag.exe`.
2. Try `help`, `doctor`, `history --stats`, `project`, and `exit`.
3. Launch the desktop host with `.\zig-out\bin\ziggyzag-launcher.exe`.
4. Confirm a prompt appears in the native window.
5. Type `help`, edit with Backspace, and press Enter.
6. Paste with Ctrl+V and Shift+Insert.
7. Start a long-running command and use Ctrl+C as interrupt.
8. Copy visible terminal text with Ctrl+Shift+C and paste it into Notepad.
9. Resize the window smaller and larger.
10. Produce enough output to scroll, then use the mouse wheel.
11. Close the window and confirm it exits cleanly.

## Manual macOS/Linux Friend-Test Script

Use this order after the scripted checks:

1. Run `./zig-out/bin/ziggyzag`.
2. Try `help`, `doctor`, `history --stats`, `project`, and `exit`.
3. Run `./scripts/smoke.sh`.
4. Run `./zig-out/bin/ziggyzag-agentd --describe-tools`.
5. Run `printf '%s\n' '{"id":1,"method":"agent/health"}' | ./zig-out/bin/ziggyzag-agentd --stdio`.
6. Run `printf 'exit\n' | zig build run-desktop`.
7. Confirm the desktop command prints `ZiggyZag Desktop (POSIX PTY)`, launches a shell prompt, and exits cleanly. If native PTY setup fails, a `script(1)` or direct-stdio fallback is acceptable. Do not expect a native graphical window yet.

## AgentD Friend-Test Script

Tool discovery:

```powershell
zig build run-agentd -- --describe-tools
```

Expected tools:

- `project.info`
- `file.read`
- `rg.search`
- `git.diff`
- `zig.build`
- `terminal.write`

Stdio health and a host action:

```powershell
@'
{"id":1,"method":"agent/health"}
{"id":2,"method":"tools/list"}
{"id":3,"method":"tools/call","tool":"terminal.write","text":"echo hello-from-agentd\n"}
'@ | .\zig-out\bin\ziggyzag-agentd.exe --stdio
```

`terminal.write` should return a host action. It should not write directly to the PTY without the desktop host approving and applying it.

## Release Zip Smoke Commands

### Windows x86_64

Use PowerShell:

```powershell
$Version = "v0.1.0-alpha.2"
$Zip = "ZiggyZag-$Version-windows-x86_64.zip"
$Dest = "$env:TEMP\ziggyzag-$Version-windows-x86_64"
Remove-Item -Recurse -Force $Dest -ErrorAction SilentlyContinue
Expand-Archive -Path $Zip -DestinationPath $Dest -Force
Set-Location $Dest

"help`nexit`n" | .\bin\ziggyzag.exe
.\bin\ziggyzag-agentd.exe --describe-tools
'{"id":1,"method":"agent/health"}' | .\bin\ziggyzag-agentd.exe --stdio
.\ZiggyZag.exe
```

Expected:

- Shell prints help and exits with code 0.
- AgentD lists `terminal.write`.
- `agent/health` returns JSON with `"ok":true`.
- The top-level launcher opens a native Windows terminal window; close button exits cleanly.

### Linux x86_64

Use a Linux x86_64 host or runner:

```sh
VERSION=v0.1.0-alpha.2
ZIP=ZiggyZag-$VERSION-linux-x86_64.zip
DEST=/tmp/ziggyzag-$VERSION-linux-x86_64
rm -rf "$DEST"
unzip "$ZIP" -d "$DEST"
cd "$DEST"
chmod +x ZiggyZag bin/ziggyzag-launcher bin/ziggyzag bin/ziggyzag-agentd bin/ziggyzag-desktop

printf 'help\nexit\n' | ./bin/ziggyzag
./bin/ziggyzag-agentd --describe-tools
printf '{"id":1,"method":"agent/health"}\n' | ./bin/ziggyzag-agentd --stdio
printf 'exit\n' | ./bin/ziggyzag-desktop
```

Expected:

- Shell prints help and exits with code 0.
- AgentD lists `terminal.write`.
- `agent/health` returns JSON with `"ok":true`.
- POSIX desktop launcher prints the selected PTY backend and launches the bundled shell in the current terminal, using native POSIX PTY first, then `script(1)`, then direct stdio. It is not a native graphical Linux window yet.

### Linux aarch64

Use a Linux aarch64 host or runner. The commands match Linux x86_64 except the zip name and destination:

```sh
VERSION=v0.1.0-alpha.2
ZIP=ZiggyZag-$VERSION-linux-aarch64.zip
DEST=/tmp/ziggyzag-$VERSION-linux-aarch64
rm -rf "$DEST"
unzip "$ZIP" -d "$DEST"
cd "$DEST"
chmod +x ZiggyZag bin/ziggyzag-launcher bin/ziggyzag bin/ziggyzag-agentd bin/ziggyzag-desktop

printf 'help\nexit\n' | ./bin/ziggyzag
./bin/ziggyzag-agentd --describe-tools
printf '{"id":1,"method":"agent/health"}\n' | ./bin/ziggyzag-agentd --stdio
printf 'exit\n' | ./bin/ziggyzag-desktop
```

### macOS x86_64

Use an Intel macOS host:

```sh
VERSION=v0.1.0-alpha.2
ZIP=ZiggyZag-$VERSION-macos-x86_64.zip
DEST=/tmp/ziggyzag-$VERSION-macos-x86_64
rm -rf "$DEST"
unzip "$ZIP" -d "$DEST"
cd "$DEST"
chmod +x ZiggyZag bin/ziggyzag-launcher bin/ziggyzag bin/ziggyzag-agentd bin/ziggyzag-desktop
xattr -dr com.apple.quarantine . 2>/dev/null || true

printf 'help\nexit\n' | ./bin/ziggyzag
./bin/ziggyzag-agentd --describe-tools
printf '{"id":1,"method":"agent/health"}\n' | ./bin/ziggyzag-agentd --stdio
printf 'exit\n' | ./bin/ziggyzag-desktop
```

Expected behavior matches Linux: shell and AgentD should run; POSIX desktop launcher uses the current terminal rather than a native macOS window, with native POSIX PTY preferred when available.

### macOS aarch64

Use an Apple Silicon macOS host. The commands match macOS x86_64 except the zip name and destination:

```sh
VERSION=v0.1.0-alpha.2
ZIP=ZiggyZag-$VERSION-macos-aarch64.zip
DEST=/tmp/ziggyzag-$VERSION-macos-aarch64
rm -rf "$DEST"
unzip "$ZIP" -d "$DEST"
cd "$DEST"
chmod +x ZiggyZag bin/ziggyzag-launcher bin/ziggyzag bin/ziggyzag-agentd bin/ziggyzag-desktop
xattr -dr com.apple.quarantine . 2>/dev/null || true

printf 'help\nexit\n' | ./bin/ziggyzag
./bin/ziggyzag-agentd --describe-tools
printf '{"id":1,"method":"agent/health"}\n' | ./bin/ziggyzag-agentd --stdio
printf 'exit\n' | ./bin/ziggyzag-desktop
```

## Provider Fallback

AgentD defaults to Ollama:

```powershell
$env:ZIGGYZAG_AGENT_PROVIDER = "ollama"
$env:ZIGGYZAG_AGENT_BASE_URL = "http://127.0.0.1:11434"
$env:ZIGGYZAG_AGENT_MODEL = "qwen2.5-coder:1.5b"
```

If Ollama is not running, this command may return `provider_error`:

```powershell
zig build run-agentd -- --oneshot "Return one short sentence for QA."
```

That is acceptable for tomorrow as long as the response is structured JSON and AgentD does not crash. Tool listing, local file/search/git tools, `agent/health`, and `terminal.write` should still work without a running provider.

For OpenAI-compatible providers, set:

```powershell
$env:ZIGGYZAG_AGENT_PROVIDER = "openai-compatible"
$env:ZIGGYZAG_AGENT_BASE_URL = "https://api.openai.com"
$env:ZIGGYZAG_AGENT_MODEL = "gpt-4.1-mini"
$env:ZIGGYZAG_AGENT_API_KEY = "<key>"
```

## What To Record

Ask testers to note:

- Operating system version and terminal used to launch commands.
- Whether `zig version` prints `0.16.0`.
- Any build or smoke failures.
- On Windows, whether `ZiggyZag.exe` opens the desktop prompt.
- On macOS/Linux, whether `zig build run-desktop` launches ZiggyZag in the current terminal.
- Whether Ctrl+C interrupts and Ctrl+Shift+C copies visible text.
- Whether AgentD returns valid JSON for `--describe-tools`, `agent/health`, and provider fallback.

## Known Edges

- The native graphical desktop host is Windows-only in this alpha. macOS/Linux desktop support is currently a terminal-attached launcher, plus fully usable shell and AgentD binaries.
- Split panes and the desktop AgentD panel are expected in the Windows alpha. Tabs and full process/session restore are not expected yet; test `ziggyzag-agentd` both from the panel and as a standalone sidecar.
- Linux/macOS release zips may need `chmod +x ZiggyZag bin/ziggyzag-launcher bin/ziggyzag bin/ziggyzag-agentd bin/ziggyzag-desktop` after unzip because the zips are produced on Windows.
- macOS browser downloads may be quarantined; the smoke commands include `xattr -dr com.apple.quarantine .`.
- Desktop config loading is implemented for the Win32 host, but there is not yet a graphical settings editor that writes `desktop.conf`.
- Mouse selection is not yet implemented; copy-visible uses Ctrl+Shift+C.
- Deeper Unicode width, ligatures, GPU rendering, and broader ANSI/xterm coverage are future hardening work.
