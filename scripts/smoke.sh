#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMPDIR="${TMPDIR:-/tmp}/ziggyzag-smoke"
CONFIG="$TMPDIR/.ziggyzagrc"
META="$TMPDIR/history.tsv"
OUT="$TMPDIR/out.txt"
SOURCE_FILE="$TMPDIR/source.zz"
COMMANDS="$TMPDIR/commands.txt"

mkdir -p "$TMPDIR"
rm -f "$META" "$OUT" "$SOURCE_FILE" "$COMMANDS"

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
echo hello | grep hello
exit
EOF
sed "s|SOURCE_FILE_PLACEHOLDER|$SOURCE_FILE|g" "$COMMANDS" | "$ROOT/zig-out/bin/ziggyzag" > "$OUT"

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
grep -q "hello" "$OUT"
test -f "$META"

printf '%s\n' "ZiggyZag smoke passed"
