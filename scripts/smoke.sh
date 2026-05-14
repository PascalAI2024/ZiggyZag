#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMPDIR="${TMPDIR:-/tmp}/ziggyzag-smoke"
CONFIG="$TMPDIR/.ziggyzagrc"
META="$TMPDIR/history.tsv"
OUT="$TMPDIR/out.txt"
SOURCE_FILE="$TMPDIR/source.zz"
COMMANDS="$TMPDIR/commands.txt"
NAV_DIR="$TMPDIR/ziggyzag-smoke-nav"
MISSING_SOURCE="$TMPDIR/missing-source.zz"
FAIL_FILE="$TMPDIR/failed.txt"

mkdir -p "$TMPDIR"
rm -f "$META" "$OUT" "$SOURCE_FILE" "$COMMANDS" "$FAIL_FILE"
rm -rf "$NAV_DIR"

cat > "$CONFIG" <<'EOF'
alias hi='echo hello'
abbr greet='echo expanded'
complete -c zzdemo -a 'alpha beta' -d 'demo subcommand'
prompt smart
export ZZSMOKE=ready
EOF

cat > "$SOURCE_FILE" <<'EOF'
alias sourced='echo sourced ok'
export SOURCED_VALUE=from-source
EOF

export ZIGGYZAG_CONFIG="$CONFIG"
export ZIGGYZAG_HISTORY_DB="$META"

cat > "$COMMANDS" <<'EOF'
hi world
greet now
complete -p zzdemo
doctor
history --json
history --meta --json
config check
inspect echo hello | grep hello
about
about --json
which echo grep missing-command
which --json echo
path --json
env ZZSMOKE
env --json
vars --json
timeit echo timed
repeat 2 echo repeated
source SOURCE_FILE_PLACEHOLDER
sourced
echo $SOURCED_VALUE
project
project --json
run --list
dirs
dirs --json
mkcd NAV_DIR_PLACEHOLDER
pwd
back
pwd
jump ziggyzag-smoke-nav
pwd
back
source MISSING_SOURCE_PLACEHOLDER 2> FAIL_FILE_PLACEHOLDER
history --failed
history --slow 0
history --cwd
history --stats
echo hello | grep hello
exit
EOF
sed -e "s|SOURCE_FILE_PLACEHOLDER|$SOURCE_FILE|g" -e "s|NAV_DIR_PLACEHOLDER|$NAV_DIR|g" -e "s|MISSING_SOURCE_PLACEHOLDER|$MISSING_SOURCE|g" -e "s|FAIL_FILE_PLACEHOLDER|$FAIL_FILE|g" "$COMMANDS" | "$ROOT/zig-out/bin/ziggyzag" > "$OUT" 2>&1

grep -q "hello world" "$OUT"
grep -q "expanded now" "$OUT"
grep -q "complete -c zzdemo -a alpha" "$OUT"
grep -q "ZiggyZag doctor" "$OUT"
grep -q '"command":"doctor"' "$OUT"
grep -q "ok " "$OUT"
grep -q "pipeline: native simple pipeline" "$OUT"
grep -q "ZiggyZag 0.1.0" "$OUT"
grep -q '"name":"ZiggyZag"' "$OUT"
grep -q "shell builtin" "$OUT"
grep -q '"kind":"builtin"' "$OUT"
grep -q '"path"' "$OUT"
grep -q "ready" "$OUT"
grep -q '"name":"ZZSMOKE"' "$OUT"
grep -q "timeit: " "$OUT"
test "$(grep -c "repeated" "$OUT")" -ge 2
grep -q "sourced ok" "$OUT"
grep -q "from-source" "$OUT"
grep -q "project: zig" "$OUT"
grep -q '"kind":"zig"' "$OUT"
grep -q "tasks: build test run fmt" "$OUT"
grep -q '"current":true' "$OUT"
grep -q "ziggyzag-smoke-nav" "$OUT"
grep -q "status=1" "$OUT"
grep -q "history stats" "$OUT"
grep -q "hello" "$OUT"
test -f "$META"
test -f "$FAIL_FILE"

printf '%s\n' "ZiggyZag smoke passed"
