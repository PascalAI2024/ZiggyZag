#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMPDIR="${TMPDIR:-/tmp}/ziggyzag-smoke"
CONFIG="$TMPDIR/.ziggyzagrc"
META="$TMPDIR/history.tsv"
OUT="$TMPDIR/out.txt"

mkdir -p "$TMPDIR"
rm -f "$META" "$OUT"

cat > "$CONFIG" <<'EOF'
alias hi='echo hello'
abbr greet='echo expanded'
complete -c zzdemo -a 'alpha beta' -d 'demo subcommand'
prompt smart
export ZZSMOKE=ready
EOF

export ZIGGYZAG_CONFIG="$CONFIG"
export ZIGGYZAG_HISTORY_DB="$META"

"$ROOT/zig-out/bin/ziggyzag" > "$OUT" <<'EOF'
hi world
greet now
complete -p zzdemo
doctor
history --json
history --meta --json
config check
inspect echo hello | grep hello
echo hello | grep hello
exit
EOF

grep -q "hello world" "$OUT"
grep -q "expanded now" "$OUT"
grep -q "complete -c zzdemo -a alpha" "$OUT"
grep -q "ZiggyZag doctor" "$OUT"
grep -q '"command":"doctor"' "$OUT"
grep -q "ok " "$OUT"
grep -q "pipeline: native simple pipeline" "$OUT"
grep -q "hello" "$OUT"
test -f "$META"

printf '%s\n' "ZiggyZag smoke passed"
