#!/usr/bin/env sh
# ZiggyZag canonical feature walkthrough.
#
# This script is the source of truth for the demo GIF/video. Run it inside the
# ZiggyZag desktop host (or any terminal hosting `ziggyzag`) and you'll see a
# coherent sequence covering: REPL basics, builtins, expansion, completion,
# project awareness, history queries, prompt themes, theme protocol, and the
# AgentD health check.
#
# Recording tips:
#   Linux:    asciinema rec demo.cast -c 'sh scripts/demo.sh'
#   macOS:    asciinema rec demo.cast -c 'sh scripts/demo.sh'  (brew install asciinema)
#   Windows:  Run inside Windows Terminal or ziggyzag-desktop.exe, capture with
#             ScreenToGif (https://www.screentogif.com/).
#
# Convert asciinema cast to GIF:
#   svg-term --in demo.cast --out assets/demo.svg --window
#   (or)  agg demo.cast assets/demo.gif --font-size 14 --speed 1.0
#
# This is a SHELL script, not a Zig program. It just pipes commands into a
# running ZiggyZag interactive session. To run end-to-end without a window:
#
#   sh scripts/demo.sh | ./zig-out/bin/ziggyzag
#
# The script prints each command with a slight pause before sending, so the
# recording reads naturally rather than as a wall of instant text. Each pause
# can be tuned via DEMO_PAUSE (default 0.6 seconds). Set DEMO_PAUSE=0 to skip.

set -eu

DEMO_PAUSE="${DEMO_PAUSE:-0.6}"

pause() {
  if [ "$DEMO_PAUSE" != "0" ]; then
    sleep "$DEMO_PAUSE"
  fi
}

# Send a single command to the running shell, with a comment for the demo
# narrator. Comments are echoed to stderr so they show in screen recordings
# but don't reach the shell on stdin.
say() {
  printf -- '─── %s ───\n' "$1" >&2
  pause
}

run() {
  printf '%s\n' "$1"
  pause
}

# --- 0. Set the scene -------------------------------------------------------

say "ZiggyZag · the canonical feature walkthrough"
run 'about'

# --- 1. Builtins, expansion, redirection ------------------------------------

say "Parameter expansion and quoting"
run 'declare project=ZiggyZag'
run 'echo "hello, ${project}"'
run "echo 'literal \$project'"

say "Aliases and abbreviations"
run "alias gs='git status --short'"
run "abbr gco='git checkout'"
run 'alias'
run 'abbr'

say "Programmable completion"
run "complete -c zz -a 'build run test fmt' -d 'common command'"
run 'complete -p zz'

# --- 2. Project awareness ---------------------------------------------------

say "Project detection and run targets"
run 'project'
run 'project --json'
run 'run --list'

# --- 3. History with metadata ----------------------------------------------

say "Metadata history, queryable from this session AND prior sessions"
run 'history --stats'
run 'history --slow 0'
run 'history --cwd'
run 'history --failed'
run 'history --search theme | head'

# --- 4. Prompts ------------------------------------------------------------

say "Five prompt themes"
run 'prompt themes'
run 'prompt smart'
run 'echo "smart prompt"'
run 'prompt dev'
run 'echo "dev prompt"'
run 'prompt dashboard'
run 'echo "dashboard prompt"'
run 'prompt classic'

# --- 5. Themes (the headline) ----------------------------------------------

say "Theme protocol — 20 themes, one selection drives the prompt accent"
run 'theme'
run 'theme list | head'
run 'theme tokyo-night'
run 'echo "now tokyo-night"'
run 'theme catppuccin-mocha'
run 'echo "now catppuccin-mocha"'
run 'theme --json'
run 'theme ziggy'

# --- 6. Convenience builtins ------------------------------------------------

say "Convenience: timeit, repeat, mkcd, up, back/forward, jump"
run 'timeit echo quick'
run 'repeat 2 echo round'
run 'mkcd /tmp/zz-demo'
run 'pwd'
run 'up'
run 'back'

# --- 7. Introspection ------------------------------------------------------

say "Doctor, inspect, which, path"
run 'doctor'
run 'which echo grep ls'
run 'path | head'

say "Inspect a piped command — see how ZiggyZag parses and executes"
run 'inspect echo hello | grep hello'

# --- 8. Pipelines -----------------------------------------------------------

say "Native simple pipelines (complex syntax falls back to /bin/sh)"
run 'echo hello | grep hello'
run 'history | wc -l'

# --- 9. AgentD --------------------------------------------------------------

say "AgentD JSON-lines protocol — local-first, approval-gated"
run 'echo \'\{"id":1,"method":"agent/health"\}\' | ziggyzag-agentd --stdio | head'
run 'ziggyzag-agentd --describe-tools | head -20'

# --- 10. The end ------------------------------------------------------------

say "All in roughly 16,000 lines of Zig, zero dependencies, MIT-licensed."
run 'about --json | head'
run 'exit'
