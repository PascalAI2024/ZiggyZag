# Security Policy

ZiggyZag is a small Zig workspace with three trust-sensitive components: a shell that runs user commands, a desktop terminal host that owns a PTY and the active window, and an agent sidecar (AgentD) that has approval-aware filesystem and build tools. We take vulnerabilities in any of them seriously.

## Reporting a vulnerability

If you believe you have found a security issue, please **do not open a public GitHub issue**. Instead:

1. Email the maintainer at **159666353+PascalAI2024@users.noreply.github.com** with the subject line `[ZiggyZag security]` and a description of the issue.
2. If you prefer, you can use GitHub's [private vulnerability reporting](https://github.com/PascalAI2024/ZiggyZag/security/advisories/new) on the repository.
3. We aim to acknowledge within **7 days** and provide a remediation plan within **30 days** for confirmed issues. Once a fix is shipped, we credit the reporter in the CHANGELOG unless they ask otherwise.

There is no bug bounty. ZiggyZag is a hobby project — we offer thanks, credit, and the satisfaction of a public fix.

## Scope

In scope:

- The shell (`apps/shell`) — parser, expansion, builtins, redirection, background jobs, completion engine.
- The desktop host (`apps/desktop`) — PTY lifecycle, escape parser, OSC handling, settings, command palette, AgentD panel, env-var passthrough.
- The AgentD sidecar (`apps/agentd`) — tool implementations, sandbox (`file.read`, `rg.search`, `git.diff`, `zig.build`, `terminal.write`), JSON-lines protocol, secret redaction.
- The launcher (`apps/launcher`) and the release scripts under `scripts/`.

Out of scope:

- Third-party Ollama and OpenAI-compatible providers configured by the user.
- The user's own shell startup config (`.ziggyzagrc`), aliases, abbreviations, or completion specs.
- Build-time supply-chain (Zig stdlib, GitHub Actions runners) — report those upstream.
- Issues in forked code outside the `PascalAI2024/ZiggyZag` repository.

## Threat model summary

AgentD's threat model is the most safety-relevant surface. We assume:

- The user supplies the workspace path. ZiggyZag never decides what "the workspace" is.
- An attacker may influence path strings, search queries, command output, and provider responses that arrive over JSON-lines or `stdin`.
- An attacker does NOT have a live attacker-controlled filesystem on the user's host (no concurrent symlink swaps). Path checks are TOCTOU-best-effort within that bound.
- All state-changing tools (`terminal.write`, `zig.build`) are gated by host approval; the daemon never executes them itself.

## Hardening already in place

These are the protections shipped today. We expect to add more; new layers should also be listed here when added.

- **Path sandboxing for `file.read`**: lexical filter (no `..`, no absolute paths, no NTFS Alternate Data Stream syntax), then a non-following `lstat` walk to reject any intermediate symlink component, then a canonicalising `realpath` workspace-containment guard. Sibling-prefix escapes (`/ws-evil/...`), final-symlink escapes, and directory-symlink escapes are covered by tests.
- **Bounded output**: 64 KB per file read, 96 KB per command stdout, 24 KB per stderr; 16 KB max for `terminal.write` input.
- **Per-tool execution timeout** with a watchdog kill in the AgentD process tools.
- **Secret redaction** in tool output: `Authorization:` headers, Slack/GitHub/AWS-shaped tokens, PEM private-key blocks, and `KEY=value`-style secret-assignment patterns are scrubbed before the bytes leave AgentD.
- **OSC consumption**: the terminal core consumes non-777 OSC strings (BEL/ST/CAN/SUB-terminated) without acting on their payloads, so a hostile remote process cannot use OSC titles or clipboard sequences to drive UI state.
- **No `@panic` calls** anywhere in the source. Errors propagate; the process does not crash on user input.
- **No `std.debug.assert` calls** that would be compiled out — invariants are explicit `return error.X` instead.
- **Approval as data**: every tool declares its `approval` policy (`none`, `ask`, `host`) in `apps/agentd/src/tools.zig` and the desktop UI enforces it.

## What you should NOT find

If you do, please report it.

- A `file.read` that returns bytes outside the workspace.
- A `terminal.write` that runs without explicit approval.
- A `zig.build` that resolves and executes from inside AgentD itself.
- An OSC sequence that changes shell state without traversing the documented event API.
- A path traversal in the shell's `source` builtin or `history --export` target.
- Any code path that calls `@panic` or `std.debug.assert` in a way an attacker can trigger.

## Disclosure timeline

The default disclosure timeline for confirmed issues is **90 days from acknowledgement** before public disclosure, but we will usually move faster. If a fix is shipped in under 30 days, public disclosure happens with the next release tag. If the issue is unfixable for structural reasons, we will document it as a known limitation in this file rather than leave reporters in limbo.

## Older versions

ZiggyZag is pre-1.0. We only support the latest tagged release plus `master`. Issues against `v0.1.0-alpha.1` and older are fixed only if they also affect the latest release.

---

*This policy will evolve. Last updated: 2026-05-17.*
