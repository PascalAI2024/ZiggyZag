#!/bin/sh
# Run `zig build test` (or any zig build step) with a per-invocation cache so
# concurrent builds from multiple agents do not SIGTERM each other.
#
# Why: several agents share one working tree and the default .zig-cache. Two
# `zig build` runs against the same cache race on the cache lock and one gets
# killed (exit 144 / SIGTERM) mid-build — which looks like a test failure but
# is pure contention. Pointing each run at its own cache dir removes the race.
#
# Usage:
#   sh scripts/zig-test.sh                 # runs `zig build test`
#   sh scripts/zig-test.sh fmt-check       # runs `zig build fmt-check`
#   STEP="vt-conformance" sh scripts/zig-test.sh
#
# The cache dir is unique per PID and removed on exit. First run is a full
# cold build (slower); that is the cost of isolation.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ZIG="${ZIG:-zig}"
command -v "$ZIG" >/dev/null 2>&1 || { echo "error: zig not found on PATH" >&2; exit 1; }

STEP="${1:-${STEP:-test}}"

CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zzcache.XXXXXX")"
GCACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zzgcache.XXXXXX")"
trap 'rm -rf "$CACHE_DIR" "$GCACHE_DIR"' EXIT INT TERM

echo "zig build $STEP  (isolated cache: $CACHE_DIR)"
"$ZIG" build "$STEP" --cache-dir "$CACHE_DIR" --global-cache-dir "$GCACHE_DIR"
