#!/bin/sh
#
# Use this script to run your program LOCALLY.
#
# Note: Changing this script WILL NOT affect how CodeCrafters runs your program.
#
# Learn more: https://codecrafters.io/program-interface

set -e # Exit early if any commands fail

if ! command -v zig >/dev/null 2>&1; then
  printf '%s\n' "Missing zig. Install Zig 0.16.0 and make sure 'zig' is on PATH." >&2
  exit 1
fi

# Copied from .codecrafters/compile.sh
#
# - Edit this to change how your program compiles locally
# - Edit .codecrafters/compile.sh to change how your program compiles remotely
(
  cd "$(dirname "$0")" # Ensure compile steps are run within the repository directory
  zig build
)

# Copied from .codecrafters/run.sh
#
# - Edit this to change how your program runs locally
# - Edit .codecrafters/run.sh to change how your program runs remotely
BIN="$(dirname "$0")"/zig-out/bin/ziggyzag

if [ ! -x "$BIN" ]; then
  printf '%s\n' "Missing $BIN after build. Check the 'zig build' output above." >&2
  exit 1
fi

exec "$BIN" "$@"
