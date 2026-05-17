# ZiggyZag AgentD

`apps/agentd` is the slim Zig-native agent runtime for the terminal host.

It is intentionally small:

- one Zig binary named `ziggyzag-agentd`
- JSON-lines over stdin/stdout for terminal integration
- flat, host-friendly tool calls
- OpenAI-compatible and Ollama request shaping plus a tiny curl-backed transport
- a health method the desktop host can poll before showing agent controls
- no Node runtime and no embedded web framework

See also: [desktop terminal strategy](../../docs/reference/terminal-app.md), [alpha task list](../../docs/vision/alpha-tasks.md), [task system](../../docs/reference/task-system.md), and [data/QA map](../../docs/reference/data-map.md).

## Commands

Run from the repository root:

```sh
zig build run-agentd -- --help
zig build run-agentd -- --describe-tools
zig build run-agentd -- --stdio
zig build run-agentd -- --oneshot "summarize this workspace"
zig build run-agentd -- --provider-request "draft a plan"
```

The installed binary path after `zig build` is:

```sh
./zig-out/bin/ziggyzag-agentd --describe-tools
```

On Windows PowerShell:

```powershell
.\zig-out\bin\ziggyzag-agentd.exe --describe-tools
```

On macOS/Linux:

```sh
./zig-out/bin/ziggyzag-agentd --describe-tools
printf '%s\n' '{"id":1,"method":"agent/health"}' | ./zig-out/bin/ziggyzag-agentd --stdio
```

## Provider Environment

Ollama is the friendliest local default:

```sh
ZIGGYZAG_AGENT_PROVIDER=ollama
ZIGGYZAG_AGENT_BASE_URL=http://127.0.0.1:11434
ZIGGYZAG_AGENT_MODEL=qwen2.5-coder:1.5b
ZIGGYZAG_AGENT_STREAM=1
```

`agent/run` and `--oneshot` try the configured provider through `curl`. If `curl` is missing, the API key is missing, or the provider is not reachable, AgentD still returns a structured fallback response so the terminal UI can keep working.

That fallback is expected during local friend tests when Ollama is not running. `tools/list`, local read/search/git tools, `terminal.write` host actions, and `agent/health` should still work even when provider calls return `provider_error`. A release artifact smoke should treat structured provider failure as acceptable protocol behavior, not as a crash.

For OpenAI-compatible providers:

```sh
ZIGGYZAG_AGENT_PROVIDER=openai-compatible
ZIGGYZAG_AGENT_BASE_URL=https://api.openai.com
ZIGGYZAG_AGENT_MODEL=gpt-4.1-mini
ZIGGYZAG_AGENT_API_KEY=...
```

## Zig Tool Resolution

The `zig.build` tool resolves Zig conservatively:

1. `ZIGGYZAG_ZIG_PATH`
2. `ZIG_EXE`
3. `zig` on `PATH`
4. known Windows install locations for Winget, Scoop, Chocolatey, and `C:\Program Files\Zig`

If Zig cannot be found, AgentD returns a structured tool error instead of crashing. On macOS/Linux, keep `zig` on `PATH` or set `ZIGGYZAG_ZIG_PATH`/`ZIG_EXE` to the absolute Zig executable path.

In release zips, `ziggyzag-agentd` is packaged beside `ziggyzag` and `ziggyzag-desktop` under `bin/`. Windows uses `ziggyzag-agentd.exe`; Linux/macOS use `ziggyzag-agentd`.

## Protocol

The terminal side should spawn `ziggyzag-agentd --stdio` and exchange newline-delimited JSON.

```json
{"id":0,"method":"agent/health"}
{"id":1,"method":"tools/list"}
{"id":2,"method":"tools/call","tool":"project.info"}
{"id":3,"method":"tools/call","tool":"file.read","path":"README.md"}
{"id":4,"method":"tools/call","tool":"rg.search","query":"terminal"}
{"id":5,"method":"tools/call","tool":"terminal.write","text":"zig build\n"}
{"id":6,"method":"agent/run","prompt":"what should I do next?"}
```

Responses are envelopes:

```json
{"id":0,"ok":true,"result":{"provider":"ollama","model":"qwen2.5-coder:1.5b","endpoint":"http://127.0.0.1:11434/api/chat","health_endpoint":"http://127.0.0.1:11434/api/tags","stream":false,"curl":"available","api_key":"not_required","provider_status":"reachable","ready":true}}
{"id":2,"ok":false,"error":{"code":"UnknownTool","message":"unknown tool name"}}
```

`agent/health` is a readiness check, not just a config echo. It reports `curl`, `api_key`, `provider_status`, and `ready`. Expected `provider_status` values include `reachable`, `unreachable`, `missing_api_key`, and `curl_unavailable`.

`terminal.write` returns a host action instead of touching the PTY directly. The desktop app should treat that action as an approval-gated request before writing into the active terminal.

## Safety Notes

- Requests must be valid one-line JSON objects.
- Error envelopes preserve only safe string, number, or null request ids; malformed ids fall back to `null`.
- Escaped JSON strings are decoded, so `"text":"zig build\n"` becomes an actual newline for `terminal.write`.
- `file.read` only accepts relative paths inside the current workspace and rejects `..`, absolute paths, drive-style paths, alternate data stream syntax, and NUL bytes.
- `rg.search` rejects empty, NUL-containing, or oversized queries and passes patterns after `--` so dash-prefixed searches are treated as patterns.
- `zig.build` only accepts the default build or `"command":"test"` and should be host-approved before execution.
- `terminal.write` rejects empty, NUL-containing, and oversized text.
- `agent/run` rejects NUL-containing or very large prompts before contacting the provider.

## Quick Local Protocol Test

PowerShell:

```powershell
'{"id":1,"method":"tools/list"}' | .\zig-out\bin\ziggyzag-agentd.exe --stdio
```

POSIX shell:

```sh
printf '%s\n' '{"id":1,"method":"tools/list"}' | ./zig-out/bin/ziggyzag-agentd --stdio
```

Expected result: a JSON envelope with `"ok":true` and a `tools` array.

## Approval Model

AgentD only describes or requests actions. The terminal host stays responsible for applying policy:

| Tool | Default policy | Reason |
| --- | --- | --- |
| `project.info` | allow | Read-only workspace summary. |
| `file.read` | allow | Read-only file inspection. |
| `rg.search` | allow | Read-only search. |
| `git.diff` | allow | Read-only review context. |
| `zig.build` | ask | Runs a local build process. |
| `terminal.write` | host | Requests text to be written into the active terminal. |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `ziggyzag-agentd` is missing | Run `zig build` from the repo root. |
| `zig.build` cannot find Zig | Set `ZIGGYZAG_ZIG_PATH` or `ZIG_EXE` to the full Zig executable path, or open a fresh terminal after adding Zig 0.16.0 to `PATH`. |
| `--oneshot` returns `provider_error` | Start Ollama or configure an OpenAI-compatible provider. This is a provider problem, not a protocol crash. |
| Ollama says the model is missing | Run `ollama pull qwen2.5-coder:1.5b` or set `ZIGGYZAG_AGENT_MODEL` to a model already installed locally. |
| OpenAI-compatible calls fail with auth errors | Set `ZIGGYZAG_AGENT_API_KEY` in the same terminal session before launching AgentD. |
| `--stdio` appears to hang | It is waiting for newline-delimited JSON on stdin. Send one request per line. |
