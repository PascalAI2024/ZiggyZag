#!/usr/bin/env sh
# smoke-desktop-posix.sh — CI-runnable headless smoke test for the macOS/Linux
# desktop launcher (POSIX path, no graphical window required).
#
# What this tests:
#   1. The ziggyzag-desktop binary was compiled and is executable.
#   2. The POSIX launcher resolves a shell, sets ZIGGYZAG_APP / ZIGGYZAG_INTEGRATION
#      env vars, and hands off to it.
#   3. The launched shell session exits cleanly (exit code 0) when fed "exit".
#   4. The whole thing completes within a timeout (default 10s).
#
# Environment variables honoured:
#   ZIGGYZAG_DESKTOP_TIMEOUT  — seconds to wait before declaring a hang (default 10)
#
# Usage:
#   zig build                        # compile first
#   sh scripts/smoke-desktop-posix.sh
#
# Or via build system:
#   zig build smoke-desktop

set -eu

TIMEOUT="${ZIGGYZAG_DESKTOP_TIMEOUT:-10}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DESKTOP_BIN="$ROOT/zig-out/bin/ziggyzag-desktop"

pass() { printf '\033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$1" >&2; exit 1; }

# ── 1. Binary exists and is executable ───────────────────────────────────────
if [ ! -x "$DESKTOP_BIN" ]; then
    fail "ziggyzag-desktop not found at $DESKTOP_BIN — run 'zig build' first"
fi
pass "binary exists: $DESKTOP_BIN"

# ── 2. Launch and exit cleanly ───────────────────────────────────────────────
# ZIGGYZAG_DESKTOP_NO_PTY=1  — skip PTY allocation, use direct stdio fallback
#                               (no tty needed, works in CI)
# ZIGGYZAG_SHELL_PATH=/bin/sh — use system sh so the test does not depend on
#                               the ziggyzag shell binary being in PATH
# ZIGGYZAG_NATIVE_WINDOW unset — do not attempt to open a Cocoa window
#
# We pipe "exit\n" as stdin; /bin/sh exits 0 immediately.
# A background watchdog kills the process if it exceeds the timeout.

TMPDIR_SMOKE="${TMPDIR:-/tmp}/ziggyzag-smoke-desktop"
mkdir -p "$TMPDIR_SMOKE"
OUT="$TMPDIR_SMOKE/stderr.txt"

# Spawn with timeout via background watchdog (portable; avoids GNU timeout dep)
(
    sleep "$TIMEOUT"
    # If the main process is still running, kill it and mark as timed out.
    touch "$TMPDIR_SMOKE/timeout_flag"
    kill "$SMOKE_PID" 2>/dev/null || true
) &
WATCHDOG_PID=$!

printf 'exit\n' | \
    ZIGGYZAG_DESKTOP_NO_PTY=1 \
    ZIGGYZAG_SHELL_PATH=/bin/sh \
    "$DESKTOP_BIN" 2>"$OUT" &
SMOKE_PID=$!

wait "$SMOKE_PID"
EXIT_CODE=$?

# Kill the watchdog now that the process has ended
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true

if [ -f "$TMPDIR_SMOKE/timeout_flag" ]; then
    rm -f "$TMPDIR_SMOKE/timeout_flag"
    printf '\nstderr output:\n' >&2
    cat "$OUT" >&2
    fail "desktop launcher timed out after ${TIMEOUT}s — possible hang in PTY relay or shell spawn"
fi

if [ "$EXIT_CODE" -ne 0 ]; then
    printf '\nstderr output:\n' >&2
    cat "$OUT" >&2
    fail "desktop launcher exited with code $EXIT_CODE (expected 0)"
fi

pass "launcher exited cleanly (code 0)"

# ── 3. Env injection check ───────────────────────────────────────────────────
# Verify the launcher sets ZIGGYZAG_APP=1 and ZIGGYZAG_INTEGRATION=1 in the
# child environment by running a shell that prints them and captures output.
ENV_OUT="$TMPDIR_SMOKE/env_check.txt"

printf 'echo "APP=$ZIGGYZAG_APP INT=$ZIGGYZAG_INTEGRATION"\nexit\n' | \
    ZIGGYZAG_DESKTOP_NO_PTY=1 \
    ZIGGYZAG_SHELL_PATH=/bin/sh \
    "$DESKTOP_BIN" >"$ENV_OUT" 2>/dev/null

if grep -q "APP=1" "$ENV_OUT" && grep -q "INT=1" "$ENV_OUT"; then
    pass "env injection: ZIGGYZAG_APP=1 and ZIGGYZAG_INTEGRATION=1 present in child"
else
    printf '\nchild stdout:\n' >&2
    cat "$ENV_OUT" >&2
    fail "env injection: ZIGGYZAG_APP or ZIGGYZAG_INTEGRATION not set in child environment"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
printf '\n\033[32mAll desktop POSIX smoke checks passed.\033[0m\n'
