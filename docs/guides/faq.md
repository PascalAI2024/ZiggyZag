# FAQ

The first-five-minutes questions, answered honestly. For the full picture, start at the [README](../../README.md) or the [Masterplan](../vision/masterplan.md).

## Is this another terminal? Why?

ZiggyZag is a small Zig workspace — a readable shell, a native Windows terminal host, and a local AI sidecar — about 16,500 lines of Zig with zero third-party dependencies. It is learning-first.

It is not trying to replace WezTerm, Ghostty, or Warp. Those are mature production tools. ZiggyZag occupies the middle band: small enough to read in a focused sitting, complete enough to demonstrate the hard parts, written in a language that keeps memory ownership and PTY behavior visible.

If you want a daily driver with battle-tested edges, install Ghostty. If you want to read a complete terminal stack in a weekend, this is for you.

## Is it production-ready?

No. We tag releases as `alpha`. The audits in [`reviews/`](../reviews/) are blunt about what is missing.

The Windows desktop host is daily-drivable for tolerant users — that is what Wave 1 was. The macOS and Linux story today is launcher-only: the shell and AgentD run native, but the desktop binary launches the shell in your calling terminal rather than opening its own window. Native macOS/Linux windows arrive in Wave 3.

If "alpha" makes you nervous, wait for Wave 5 (public beta) or Wave 6 (1.0).

## Does it need a Zig install?

For source builds, yes — install [Zig 0.16.0](https://ziglang.org/download/). It's a single 50 MB extract, no system-wide install, no admin rights needed.

For prebuilt zips from the [releases page](https://github.com/PascalAI2024/ZiggyZag/releases), no. The zip contains the three binaries (`ziggyzag`, `ziggyzag-desktop`, `ziggyzag-agentd`) already compiled for your platform. Extract and run.

End users on Windows/macOS/Linux can skip Zig entirely. Contributors and source-builders need 0.16.0 specifically — earlier or later patches will not build today.

## Does AgentD send my code anywhere?

No, never to a third party by us. AgentD speaks JSON-lines over stdio to the desktop host on your machine. All inference is local by default through [Ollama](https://ollama.com/) on `http://127.0.0.1:11434`.

If you explicitly opt in by setting `ZIGGYZAG_AGENT_PROVIDER=openai-compatible` and `ZIGGYZAG_AGENT_BASE_URL=https://api.openai.com` (or another endpoint), your prompts go where you point them. That is your choice and your trust boundary.

Tool output is redacted for `Authorization` headers, Slack/GitHub/AWS-shaped tokens, PEM blocks, and `KEY=value` patterns before it leaves AgentD. See [`SECURITY.md`](../../SECURITY.md).

## What can the agent actually do?

AgentD ships six tools today: `project.info` (workspace summary), `file.read` (bounded reads inside the workspace), `rg.search` (ripgrep), `git.diff` (review context), `zig.build` (build/test), and `terminal.write` (typed-into-the-prompt suggestions).

The first four are read-only and return data directly. `zig.build` and `terminal.write` are gated: the desktop host previews the exact bytes and waits for explicit human approval — Enter is not implicit. AgentD never executes a mutation itself.

Full protocol spec: [`reference/agentd-protocol.md`](../reference/agentd-protocol.md).

## How does the theme system work?

One `ZIGGYZAG_THEME` env var drives both surfaces. Set `export ZIGGYZAG_THEME=tokyo-night` in your environment, and both the desktop palette and the shell prompt accent move together. In the desktop host, `Ctrl+Shift+T` cycles through built-ins live.

Twenty themes ship today — Catppuccin (Mocha/Frappe/Macchiato/Latte), Tokyo Night (regular + Storm), Dracula, Nord, Rose Pine, Gruvbox, Everforest, Kanagawa, Solarized (dark + light), One Dark, Ayu Dark, Paper, GitHub Light, Ember, and `ziggy`.

`theme list` shows them all. WCAG AA contrast audit: [`reference/accessibility.md`](../reference/accessibility.md).

## Can I use my existing zsh/bash/fish config?

No. ZiggyZag's config is its own small format at `~/.ziggyzagrc` (or `$ZIGGYZAG_CONFIG`). It supports `alias`, `abbr`, `complete -c`, `prompt <mode>`, `theme <id>`, and `export VAR=value`. That is intentionally a tiny surface.

POSIX-style commands work because complex pipelines fall back to `/bin/sh -c` (or `cmd /C` on Windows) when the native parser does not recognise them. Simple aliases and pipelines run native.

If you have 200 lines of `.zshrc` you cannot live without, ZiggyZag is not your daily shell yet — keep zsh as login, run ziggyzag as a launched session.

## Where's tabs / split panes / SSH?

Split panes ship in the Windows desktop host today. Use `Ctrl+Shift+D` (vertical) or `Ctrl+Shift+E` (horizontal), `Ctrl+Shift+N` to cycle, `Ctrl+Shift+W` to close.

Tabs are a Wave 5 deliverable, alongside session restore and persisted titles. macOS/Linux splits land with the native graphical host in Wave 3.

SSH is intentionally out of scope. Use your SSH client of choice from inside ZiggyZag — `ssh user@host` works fine. We are not building multiplexing, port forwarding, or any of that. See [`vision/scope.md`](../vision/scope.md).

## How do I install on macOS / Linux?

Two paths today. Build from source — install Zig 0.16.0, `git clone`, `cd ZiggyZag`, `zig build`, `./zig-out/bin/ziggyzag`. Takes about 90 seconds on a 2024 laptop.

Or download the prebuilt zip for your platform from the [releases page](https://github.com/PascalAI2024/ZiggyZag/releases), extract, and run `./zig-out/bin/ziggyzag` under your normal terminal (Terminal.app, iTerm2, GNOME Terminal, Alacritty, whatever).

The native graphical desktop host for macOS and Linux arrives in Wave 3 — see [`vision/waves.md`](../vision/waves.md) for the entry gate.

## What's the difference between the shell and the desktop host?

Three binaries, each independently usable:

- `ziggyzag` — the shell. REPL, parser, builtins, history, jobs, prompt themes. Run it under any terminal.
- `ziggyzag-desktop` — the host. Native Win32 window, ConPTY, grid, palette, splits, AgentD panel. Hosts a `ziggyzag` shell inside it.
- `ziggyzag-agentd` — the agent. JSON-lines over stdio. Spawned by the desktop host, also runnable standalone for protocol testing.

The shell is the source of truth. The desktop is a host. The agent asks before it acts.

## How do I contribute?

Start at [`CONTRIBUTING.md`](../../CONTRIBUTING.md) and the [contributing tour](contributing-tour.md). Specifically welcome:

- **More themes.** Spec at [`reference/theme-protocol.md`](../reference/theme-protocol.md). WCAG AA contrast on the four standard pairs is the bar.
- **Parser diagnostics.** Better error messages on malformed shell input.
- **Completion specs.** Add `complete -c <cmd>` entries for common tools.
- **Prompt modules.** Battery, time-of-day, kubectl context, anything.

PRs go against `master`. CI runs `zig build` + `zig build test` + smoke on Ubuntu, Windows, and macOS. Open an issue first for anything bigger than a theme.

## What's the license?

MIT. See [`LICENSE`](../../LICENSE). Use it, fork it, ship it commercially, learn from it. Credit appreciated but not required.

---

*Have a question that should be here?* Open one at [GitHub Discussions](https://github.com/PascalAI2024/ZiggyZag/discussions) and we will add the answer.
