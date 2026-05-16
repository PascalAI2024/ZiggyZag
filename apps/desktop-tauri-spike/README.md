# ZiggyZag Desktop

This directory contains the scaffold for the planned first-party desktop terminal host.

The desktop app should wrap the existing `ziggyzag` shell binary in a real PTY and provide a polished terminal surface: tabs, themes, search, command palette, settings, and shell-aware status. The intended stack is Tauri, Rust, React, and xterm.js, following the architecture in `docs/TERMINAL_APP.md`.

## Current Status

The frontend scaffold now exists as a Vite, React, and xterm.js app. A Tauri 2 backend scaffold exists under `src-tauri` and provides the PTY command boundary:

- `create_terminal`
- `write_to_terminal`
- `resize_terminal`
- `close_terminal`
- `terminal://data`

The frontend also parses ZiggyZag's optional OSC 777 shell-integration events so status UI can react to cwd, exit status, duration, and command lifecycle metadata.

## Development

Build the shell first:

```sh
zig build
```

Build the frontend:

```sh
npm ci
npm run build
```

Run the full desktop app once Rust/Cargo is installed:

```sh
npm run tauri dev
```

Set `ZIGGYZAG_SHELL_PATH` if you want the PTY backend to launch a specific shell binary.

## First Milestone

1. Compile and run the Tauri backend on a machine with Rust/Cargo.
2. Add backend tests around shell path resolution and PTY lifecycle.
3. Teach the backend to separate OSC 777 integration events from raw terminal data when needed.
4. Persist settings to disk.
5. Package development builds for Windows first.
