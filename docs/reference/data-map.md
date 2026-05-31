# Data And QA Map

This map defines what counts as project data for ZiggyZag docs, QA, releases, and task tracking. Use it as the handoff layer between raw evidence and the task docs.

Start at [README.md](../README.md) for the documentation hub. Use [task-system.md](task-system.md) for status rules and [alpha-tasks.md](../vision/alpha-tasks.md) for the alpha remaining-work source of truth.

## Data Sources

| Data | Lives In | Feeds |
| --- | --- | --- |
| Research sources and product references | [research.md](../vision/research.md), [roadmap.md](../vision/roadmap.md), [terminal-app.md](terminal-app.md), [architecture.md](architecture.md) | Promote validated ideas into [next-20-features.md](../vision/next-20-features.md) and [alpha-tasks.md](../vision/alpha-tasks.md); keep speculative references in roadmap docs until implementation starts. |
| Alpha task status and missing work | [alpha-tasks.md](../vision/alpha-tasks.md), [next-20-features.md](../vision/next-20-features.md), [features.md](features.md) | Update when code lands, QA proves behavior, or scope changes; README feature claims should follow these files, not lead them. |
| QA scripts and automated checks | `scripts/smoke.ps1`, `scripts/smoke.sh`, `scripts/qa-tomorrow.ps1`, `scripts/daily-driver-qa.ps1`, `scripts/build-release.ps1`, `scripts/qa-release-artifacts.ps1` | Record latest meaningful results in [qa-tomorrow.md](../guides/qa-tomorrow.md) and promote repeated failures into [alpha-tasks.md](../vision/alpha-tasks.md). |
| Manual and friend-test notes | [qa-tomorrow.md](../guides/qa-tomorrow.md), [daily-driver-qa.md](../guides/daily-driver-qa.md), local tester reports such as `daily-driver-report.md` when generated | Convert reproducible issues into explicit tasks; keep one-off observations in the QA docs until confirmed. |
| Release manifests and checksums | `dist/<version>/release-manifest.json`, `dist/<version>/checksums.sha256` | Feed [README.md](../../README.md) release artifact claims and [qa-tomorrow.md](../guides/qa-tomorrow.md) release verification notes; checksum mismatches are release blockers. |
| AgentD protocol and audit events | [apps/agentd/README.md](../../apps/agentd/README.md), AgentD JSON-lines responses, desktop AgentD transcript/audit host-action events | Feed AgentD safety tasks in [alpha-tasks.md](../vision/alpha-tasks.md) and approval checks in [daily-driver-qa.md](../guides/daily-driver-qa.md); audit export gaps should become hardening tasks. |
| Config paths and runtime settings | `%APPDATA%\ZiggyZag\desktop.conf`, `ZIGGYZAG_DESKTOP_CONFIG`, `$ZIGGYZAG_CONFIG`, `~/.ziggyzagrc`, [quick-start.md](../guides/quick-start.md), [README.md](../../README.md) | Feed config UX and migration tasks in [alpha-tasks.md](../vision/alpha-tasks.md); docs should distinguish desktop settings from shell startup config. |
| Architecture and ownership boundaries | [scope.md](../vision/scope.md), [architecture.md](architecture.md), [terminal-app.md](terminal-app.md) | Resolve task placement before implementation; update when shell, desktop, AgentD, or release ownership changes. |

## Update Rules

1. Evidence first: script output, release files, AgentD responses, config paths, and friend-test notes should be captured before changing task status.
2. Task docs second: update [alpha-tasks.md](../vision/alpha-tasks.md) for alpha readiness and [next-20-features.md](../vision/next-20-features.md) for execution order.
3. User-facing claims last: update [README.md](../../README.md), [features.md](features.md), and [quick-start.md](../guides/quick-start.md) only after task and QA docs agree.
4. Release data is immutable per version: never edit old `dist/<version>` manifests/checksums to match docs; create a new versioned build if artifacts change.
5. Friend-test notes become tasks only when they include platform, artifact/version, command or workflow, expected result, actual result, and whether it reproduces.

## Data Gaps To Track

- No committed template for friend-test reports; [daily-driver-qa.md](../guides/daily-driver-qa.md) has a report section, but generated reports are local.
- AgentD audit events are described in docs and visible in runtime transcripts, but there is no documented exported audit file path yet.
- Linux/macOS release runtime results still require real hosts or CI runners before cross-platform artifacts can be called fully runtime-tested.
- Config migration/versioning is now enforced on the desktop config load path (`config.zig` `migrate()`/`validate()` run at load, upgrading older schemas and rejecting out-of-range values); crash-time support-bundle paths remain planned work, so config data recovery is not yet mapped to a stable artifact.
