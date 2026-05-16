#!/bin/sh
#
# This script is used to run your program on CodeCrafters
#
# This runs after .codecrafters/compile.sh
#
# Learn more: https://codecrafters.io/program-interface

set -e # Exit on failure

BIN="$(dirname "$0")"/../zig-out/bin/ziggyzag

if [ ! -x "$BIN" ]; then
  printf '%s\n' "Missing $BIN. CodeCrafters should run .codecrafters/compile.sh before this script." >&2
  exit 1
fi

exec "$BIN" "$@"
