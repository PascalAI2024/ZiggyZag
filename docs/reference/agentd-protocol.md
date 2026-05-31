# AgentD Protocol Guide

`ziggyzag-agentd` is a slim sidecar process that exposes a JSON-lines protocol over stdio. The desktop host spawns it, sends requests over its stdin, and reads responses from its stdout. This guide covers the wire format, every method, the tool registry, the approval model, sandbox guarantees, and a worked example session.

## Launch Modes

`ziggyzag-agentd` accepts several CLI flags:

| Flag | Purpose |
| --- | --- |
| `--stdio` | Enter interactive JSON-lines mode (the normal desktop-host path) |
| `--oneshot '<json>'` | Parse and handle a single JSON request, print response, exit |
| `--describe-tools` | Print the tool registry as human-readable text, exit |
| `--provider-request '<json>'` | Shape a provider API request and print it, exit |
| `--help` | Print usage summary |

The desktop host uses `--stdio`.

## Wire Format

One JSON object per line, both directions. No framing, no length prefix. Lines are newline-terminated (`\n`).

### Request

Fields are flat at the top level — there is no nested `params` object.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string, number, or null | No (defaults to `"null"`) | Caller-chosen request identifier, echoed in the response |
| `method` | string | Yes | One of `agent/health`, `tools/list`, `tools/call`, `agent/run` |
| `tool` | string or null | For `tools/call` | Tool name to invoke |
| `path` | string or null | Tool input | File path for `file.read` |
| `query` | string or null | Tool input | Search query for `rg.search` |
| `command` | string or null | Tool input | Build step for `zig.build` (`"build"` or `"test"`) |
| `text` | string or null | Tool input | Text to write for `terminal.write` |
| `prompt` | string or null | For `agent/run` | Prompt text for provider or fallback agent run |

Example minimal request:
```json
{"id":"1","method":"agent/health"}
```

Example `tools/call`:
```json
{"id":"2","method":"tools/call","tool":"file.read","path":"src/main.zig"}
```

### Response: OK

```json
{"id":"1","ok":true,"result":{...}}
```

### Response: Error

```json
{"id":"1","ok":false,"error":{"code":"unknown_method","message":"foo"}}
```

Error `code` values are `snake_case` (e.g. `unknown_method`, `unknown_tool`, `unsafe_path`, `read_error`).

If the request itself cannot be parsed, the `id` field is recovered via `bestEffortId` — a best-effort extraction of the raw `id` value from the line even when JSON parsing fails. This ensures the caller can correlate error responses with their requests.

If a single input line exceeds the read buffer (or stdin read fails), AgentD emits `{"id":"","ok":false,"error":{"code":"read_error","message":"..."}}` and ends the session cleanly rather than crashing.

All JSON strings are emitted as valid UTF-8: tool output that contains binary or non-UTF-8 bytes (e.g. `file.read` over a binary file) has each malformed byte substituted with U+FFFD, so the response envelope is always parseable. Well-formed UTF-8 passes through unchanged.

## Methods

### agent/health

Returns provider status, including which environment variables are configured.

```json
{"id":"1","method":"agent/health"}
```

Response result fields include provider, base_url, model, and stream_enabled. The exact shape is produced by `providerStatusJsonAlloc` in `main.zig`.

### tools/list

Returns the full tool registry: name, description, approval level, approval reason, effect string, context policy, and input/output schemas for every tool.

```json
{"id":"2","method":"tools/list"}
```

### tools/call

Invoke a named tool. See the Tool Registry section below for per-tool behavior.

```json
{"id":"3","method":"tools/call","tool":"rg.search","query":"ParseState"}
```

### agent/run

Run an agent prompt. AgentD first attempts to call a configured provider via curl. If the provider is unavailable, an API key is missing, or curl is not installed, it falls back to a local JSON response that describes the fallback status and suggests next tools.

```json
{"id":"4","method":"agent/run","prompt":"Summarize what this project does."}
```

When a provider is reached, the result envelope is:

```json
{"id":"4","ok":true,"result":{"provider":"openai-compatible","model":"...","endpoint":"...","status":"ok","raw_response":"...","stderr":"...","redacted":false}}
```

`status` is `"ok"` when the provider call exits 0, else `"provider_error"`. Both `raw_response` and `stderr` are passed through the same secret redaction as tool output before entering the envelope, and `redacted` is `true` when redaction changed either stream. The provider API key is never placed on the `curl` command line — it is written to a private `0600` temp file and passed via `-H @file`. On fallback (provider unavailable / no API key / curl missing) the result is instead `{"provider","model","endpoint","prompt","status","next_tools"}`.

Provider configuration is via environment variables:

| Variable | Purpose |
| --- | --- |
| `ZIGGYZAG_AGENT_PROVIDER` | Provider name (e.g. `openai`, `anthropic`) |
| `ZIGGYZAG_AGENT_BASE_URL` | API base URL |
| `ZIGGYZAG_AGENT_MODEL` | Model name |
| `ZIGGYZAG_AGENT_API_KEY` | API key |
| `ZIGGYZAG_AGENT_STREAM` | `true` to enable streaming |

Prompts are validated: maximum 64 KB, no NUL bytes.

## Tool Registry

Six tools are currently registered. Each tool definition includes: name, description, approval level, approval reason, effect string, context policy, and JSON schemas for inputs and outputs.

### project.info

- **Approval**: `none` (no user confirmation required)
- **Effect**: `read_workspace_metadata`
- **Context policy**: `minimal`
- Returns workspace root, project name, Zig version, and detected structure.

### file.read

- **Approval**: `none`
- **Effect**: `read_file_bounded_64k_redacted`
- **Context policy**: `bounded_64k_redacted`
- Reads a file relative to the workspace root and returns its contents. Output is clipped to 64 KB. Secret-like lines are redacted (see Secret Redaction below).

### rg.search

- **Approval**: `none`
- **Effect**: `read_search_index_bounded_redacted_command_output`
- **Context policy**: `bounded_redacted_command_output`
- Runs `rg --line-number --color never -- <query> .` in the workspace root. stdout is capped at 96 KB, stderr at 24 KB, both redacted.

### git.diff

- **Approval**: `none`
- **Effect**: `read_git_diff_bounded_redacted_command_output`
- **Context policy**: `bounded_redacted_command_output`
- Runs `git diff --` in the workspace root. Same bounds and redaction as `rg.search`.

### zig.build

- **Approval**: `ask` (requires host approval before execution)
- **Effect**: `write_build_artifacts_host_action_only_no_execution`
- **Context policy**: `host_action_only_no_execution`
- Normalizes the input to either `"build"` or `"test"`. Returns an **ask payload** — the tool does NOT execute the build. The host process receives the proposed `argv` (e.g. `["zig","build"]`) and must approve before acting.

### terminal.write

- **Approval**: `ask` (requires host approval before execution)
- **Effect**: `write_terminal_input_host_action_preview_only`
- **Context policy**: `host_action_preview_only`
- Returns an **ask payload** with a preview of the text (clipped to 512 bytes). The tool does NOT write to any PTY. The host process must explicitly approve before the text is sent to the active terminal.

## Approval Model

The `Approval` enum has three values:

| Value | Meaning |
| --- | --- |
| `none` | Tool executes immediately; no confirmation required |
| `ask` | Tool returns an ask payload; host must approve before any action is taken |
| `host` | Reserved for future host-managed tools (not currently used in the tool specs) |

When a tool has `approval == ask`, `tools/call` returns an ask JSON object describing the proposed action without executing it. The desktop AgentD panel presents this to the user; only after explicit approval does the host act (for `terminal.write`, by writing to the PTY; for `zig.build`, by running the build command).

Every tool response includes an audit object `{action, effect, requires_host, outcome}` and an event object `{type, action, approval, status}` for the desktop panel to display.

## file.read Sandbox

The `file.read` tool enforces three layers of path validation before reading anything:

1. **Lexical filter (`safeRelativePath`)**: rejects empty paths, paths longer than 4096 bytes, paths that are absolute (start with `/` or `\`), paths with a leading `/` or `\`, paths containing NUL bytes, paths containing `:` (blocks Windows drive-letter escapes), and any path component equal to `..`. This check is zero-alloc and runs before any filesystem call.

2. **Symlink check**: calls `statFile` on the resolved path with `follow_symlinks = false`. If the final path component is a symlink, the read is rejected. This prevents an attacker-controlled symlink from pointing outside the workspace.

3. **Realpath containment (`resolvedPathEscapesWorkspace`)**: calls `realPath`/`realPathFileAlloc` to canonicalize both the workspace root and the target path, then checks that the target is a prefix of the workspace root.

**Deliberate fail-open tradeoff**: if the realpath API call fails (e.g. on a platform where it has limited support, or due to a TOCTOU race), layer 3 fails open and the read proceeds. This is documented in `tools.zig` as an accepted best-effort tradeoff: the lexical filter and symlink check provide the primary defense; realpath provides defense-in-depth where the OS supports it reliably. This tradeoff is tracked as open hardening work in [alpha-tasks.md](../vision/alpha-tasks.md).

## Secret Redaction

All tool outputs that involve file contents or command output are passed through `redactSecretsAlloc`. It processes output line by line. A line is redacted if it contains any of the following substrings:

- `api_key`, `apikey`
- `auth_token`, `access_token`
- `secret`
- `password`
- `bearer ` (case-insensitive)

...AND the same line contains `=` or `:`.

Matching lines are replaced with `[redacted secret-like line]`. Non-matching lines are passed through unchanged.

## Example Session

The following shows a short `--stdio` session. Lines prefixed `→` are sent by the host; lines prefixed `←` are received from agentd.

```
→ {"id":"1","method":"agent/health"}
← {"id":"1","ok":true,"result":{"provider":"anthropic","base_url":"...","model":"...","stream":false}}

→ {"id":"2","method":"tools/list"}
← {"id":"2","ok":true,"result":{"tools":[{"name":"project.info",...},{"name":"file.read",...},...}]}}

→ {"id":"3","method":"tools/call","tool":"project.info"}
← {"id":"3","ok":true,"result":{"workspace":"/home/user/ZiggyZag","name":"ZiggyZag",...,"audit":{...},"event":{...}}}

→ {"id":"4","method":"tools/call","tool":"file.read","path":"build.zig"}
← {"id":"4","ok":true,"result":{"path":"build.zig","content":"...","truncated":false,...,"audit":{...},"event":{...}}}

→ {"id":"5","method":"tools/call","tool":"terminal.write","text":"ls -la\n"}
← {"id":"5","ok":true,"result":{"approval":"ask","preview":"ls -la\n","argv":null,...}}
```

After receiving the `approval: ask` response for `terminal.write`, the desktop host presents the preview to the user. Only after the user clicks Approve does the host write the text to the active PTY.

## Open Work

The following AgentD areas are tracked as open in [alpha-tasks.md](../vision/alpha-tasks.md):

- OSC 777 trust boundary hardening
- Read-only tool browsing from the UI
- Build-action approval flow
- Audit export
- Provider streaming
- Tool cancellation and timeouts
- Clearer error states
- Stronger secret redaction
