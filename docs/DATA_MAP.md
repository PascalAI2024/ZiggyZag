# Data And QA Map

This map defines what counts as project data for ZiggyZag docs, QA, releases, and task tracking. Use it as the handoff layer between raw evidence and the task docs.

Start at [README.md](README.md) for the documentation hub. Use [TASK_SYSTEM.md](TASK_SYSTEM.md) for status rules and [ALPHA_TASKS.md](ALPHA_TASKS.md) for the alpha remaining-work source of truth.

## Data Sources

| Data | Lives In | Feeds |
| --- | --- | --- |
| Research sources and product references | [RESEARCH.md](RESEARCH.md), [ROADMAP.md](ROADMAP.md), [TERMINAL_APP.md](TERMINAL_APP.md), [ARCHITECTURE.md](ARCHITECTURE.md) | Promote validated ideas into [NEXT_20_FEATURES.md](NEXT_20_FEATURES.md) and [ALPHA_TASKS.md](ALPHA_TASKS.md); keep speculative references in roadmap docs until implementation starts. |
| Alpha task status and missing work | [ALPHA_TASKS.md](ALPHA_TASKS.md), [NEXT_20_FEATURES.md](NEXT_20_FEATURES.md), [FEATURES.md](FEATURES.md) | Update when code lands, QA proves behavior, or scope changes; README feature claims should follow these files, not lead them. |
| QA scripts and automated checks | `scripts/smoke.ps1`, `scripts/smoke.sh`, `scripts/qa-tomorrow.ps1`, `scripts/daily-driver-qa.ps1`, `scripts/build-release.ps1`, `scripts/qa-release-artifacts.ps1` | Record latest meaningful results in [QA_TOMORROW.md](QA_TOMORROW.md) and promote repeated failures into [ALPHA_TASKS.md](ALPHA_TASKS.md). |
| Manual and friend-test notes | [QA_TOMORROW.md](QA_TOMORROW.md), [DAILY_DRIVER_QA.md](DAILY_DRIVER_QA.md), local tester reports such as `daily-driver-report.md` when generated | Convert reproducible issues into explicit tasks; keep one-off observations in the QA docs until confirmed. |
| Release manifests and checksums | `dist/<version>/release-manifest.json`, `dist/<version>/checksums.sha256` | Feed [README.md](../README.md) release artifact claims and [QA_TOMORROW.md](QA_TOMORROW.md) release verification notes; checksum mismatches are release blockers. |
| AgentD protocol and audit events | [apps/agentd/README.md](../apps/agentd/README.md), AgentD JSON-lines responses, desktop AgentD transcript/audit host-action events | Feed AgentD safety tasks in [ALPHA_TASKS.md](ALPHA_TASKS.md) and approval checks in [DAILY_DRIVER_QA.md](DAILY_DRIVER_QA.md); audit export gaps should become hardening tasks. |
| Config paths and runtime settings | `%APPDATA%\ZiggyZag\desktop.conf`, `ZIGGYZAG_DESKTOP_CONFIG`, `$ZIGGYZAG_CONFIG`, `~/.ziggyzagrc`, [QUICK_START.md](QUICK_START.md), [README.md](../README.md) | Feed config UX and migration tasks in [ALPHA_TASKS.md](ALPHA_TASKS.md); docs should distinguish desktop settings from shell startup config. |
| Architecture and ownership boundaries | [SCOPE.md](SCOPE.md), [ARCHITECTURE.md](ARCHITECTURE.md), [TERMINAL_APP.md](TERMINAL_APP.md) | Resolve task placement before implementation; update when shell, desktop, AgentD, or release ownership changes. |

## Update Rules

1. Evidence first: script output, release files, AgentD responses, config paths, and friend-test notes should be captured before changing task status.
2. Task docs second: update [ALPHA_TASKS.md](ALPHA_TASKS.md) for alpha readiness and [NEXT_20_FEATURES.md](NEXT_20_FEATURES.md) for execution order.
3. User-facing claims last: update [README.md](../README.md), [FEATURES.md](FEATURES.md), and [QUICK_START.md](QUICK_START.md) only after task and QA docs agree.
4. Release data is immutable per version: never edit old `dist/<version>` manifests/checksums to match docs; create a new versioned build if artifacts change.
5. Friend-test notes become tasks only when they include platform, artifact/version, command or workflow, expected result, actual result, and whether it reproduces.

## Data Gaps To Track

- No committed template for friend-test reports; [DAILY_DRIVER_QA.md](DAILY_DRIVER_QA.md) has a report section, but generated reports are local.
- AgentD audit events are described in docs and visible in runtime transcripts, but there is no documented exported audit file path yet.
- Linux/macOS release runtime results still require real hosts or CI runners before cross-platform artifacts can be called fully runtime-tested.
- Config migration/versioning and support bundle paths are still planned work, so config data recovery is not yet mapped to a stable artifact.
