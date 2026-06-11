# Native Pipelines

How ZiggyZag runs `a | b | c` without shelling out to `/bin/sh`, and when it
still falls back.

## Two paths

ZiggyZag handles unquoted `|` pipelines natively. A pipeline takes one of two
internal paths, chosen by inspecting the stages:

### Streaming path (real OS pipe chain)

When **every stage is an external command** — no shell builtin, no redirection,
2–16 stages — ZiggyZag wires the stages together with real operating-system
pipes and runs them **concurrently**:

- Stage *N*'s stdout pipe is handed directly to stage *N+1*'s stdin (via the
  child's `dup2`), so the kernel moves bytes between the two processes. No
  stage's output is ever buffered in the shell.
- Only the **last** stage's stdout is read by the shell, drained incrementally
  in fixed-size chunks and written straight to the terminal, capped at 8 MiB.
- Every stage's **stderr is inherited** to the terminal, matching how `bash`
  and `fish` interleave pipeline stderr. The shell captures no intermediate
  stderr, so there is no intermediate stderr pipe that could fill and stall the
  chain.

Consequences:

- **Constant memory.** `seq 1 100000000 | head -1` prints `1` immediately and
  uses no measurable memory — `head` reads one line and exits, `seq` dies on
  `SIGPIPE`. The old buffered path would have tried to materialize ~800 MB and
  hit the 8 MiB cap.
- **No deadlock.** The classic failure — writing all of stage 0's output before
  reading stage 1 — cannot happen, because the shell never sits between two
  external stages; the kernel does. A regression test (`yes | head -c 200000 |
  wc -c`, an infinite producer past the pipe-buffer size) guards this in CI.

The pipeline's exit status is the last stage's. A command that isn't found in
the **first** stage falls back to the buffered path (which reports the error in
the usual form); a spawn failure after the first stage has started is surfaced
rather than silently re-running earlier, possibly non-idempotent, stages.

### Buffered path (in-memory handoff)

The pipeline falls back to running stages **sequentially**, capturing each
stage's full stdout into memory (spilling to a temp file above 64 KiB) and
feeding it to the next stage's stdin, when **any** of these hold:

- **A stage is a shell builtin** (e.g. `echo x | grep x`, `pwd | cat`). Builtins
  produce their output in-process, not from a child, so there is no fd to wire
  into the next stage. The builtin's output is synthesized into a buffer and
  handed on.
- **More than 16 stages.** Beyond the streaming cap, the buffered path (which has
  no stage ceiling) takes over.
- **A streaming setup failure** (e.g. fd exhaustion) — rare; the buffered path is
  the safety net.

Captures on this path are bounded at 8 MiB per stage; output beyond that is
truncated with a diagnostic.

### System-shell fallback

Pipelines whose syntax the native engine does not model — `&&`, `||`, `|&`, `;`,
command substitution (`$(...)`/backticks), redirections inside a stage, or a
trailing `&` — are handed to the system shell unchanged. Pre-validation parses
every stage *before* running any of them, so discovering an unsupported stage
mid-pipeline never double-executes an earlier, already-run stage.

## Environment

| Variable | Effect |
| --- | --- |
| `ZIGGYZAG_PIPE_TMPDIR` | Directory for the buffered path's >64 KiB spill files (falls back to `TMPDIR`/`TEMP`/`TMP`, then `.`). |

## Why stderr is inherited, not captured

Real shells send each pipeline stage's stderr straight to the terminal,
unordered — `make 2>&1 | tail` only redirects because you asked. Inheriting
stderr on the streaming path matches that behavior and, as a bonus, removes the
only intermediate pipe that could deadlock the chain. The buffered path still
concatenates stderr (it has already serialized the stages), so behavior there is
unchanged.
