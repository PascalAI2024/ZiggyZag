# QA Tomorrow

Date: 2026-05-15
Machine: Windows, PowerShell
Repo: `C:\Users\pasca\dev\ZiggyZag\codecrafters-shell-zig`
Zig version: `0.16.0`

This is the Windows-first checklist for a friend-test build. It assumes the current all-Zig lane is primary: shell, native desktop host, and AgentD.

## Fast Rerun

Run this from the repo root:

```powershell
.\scripts\qa-tomorrow.ps1
```

The script keeps running after failures, summarizes each step, and detects the WinGet Zig install when `zig` is not on `PATH`.

## Readiness Gate

Do not hand the repo to friends until these pass on the tester machine:

```powershell
zig build
zig build test
.\scripts\smoke.ps1
.\scripts\qa-tomorrow.ps1
```

If `zig` is not recognized after installing Zig, open a fresh PowerShell window or add the Zig 0.16.0 directory to `PATH`.

## Latest Local Verification

Latest run:

```powershell
.\scripts\qa-tomorrow.ps1
```

Result: all checks passed on Windows with Zig 0.16.0.

The AgentD health check returned valid `ok:true` JSON. The real provider call returned a structured `provider_error` because Ollama was not reachable on `127.0.0.1:11434`; that is acceptable for protocol testing and is covered by the script.

## Manual Friend-Test Script

Use this order after the scripted checks:

1. Run `.\zig-out\bin\ziggyzag.exe`.
2. Try `help`, `doctor`, `history --stats`, `project`, and `exit`.
3. Launch the desktop host with `zig build run-desktop`.
4. Confirm a prompt appears in the native window.
5. Type `help`, edit with Backspace, and press Enter.
6. Paste with Ctrl+V and Shift+Insert.
7. Start a long-running command and use Ctrl+C as interrupt.
8. Copy visible terminal text with Ctrl+Shift+C and paste it into Notepad.
9. Resize the window smaller and larger.
10. Produce enough output to scroll, then use the mouse wheel.
11. Close the window and confirm it exits cleanly.

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

- Windows version and terminal used to launch commands.
- Whether `zig version` prints `0.16.0`.
- Any build or smoke failures.
- Whether the desktop prompt appears.
- Whether Ctrl+C interrupts and Ctrl+Shift+C copies visible text.
- Whether AgentD returns valid JSON for `--describe-tools`, `agent/health`, and provider fallback.

## Known Edges

- The primary desktop host is Windows-native today; POSIX desktop PTY support is later.
- Desktop config parsing exists, but persisted config loading into the Win32 host is still a near-term integration task.
- Mouse selection is not yet implemented; copy-visible uses Ctrl+Shift+C.
- Deeper Unicode width, ligatures, GPU rendering, and broader ANSI/xterm coverage are future hardening work.
