# ZiggyZag Documentation

This is the documentation hub for ZiggyZag, an alpha Zig shell workspace with a readable shell core, Windows-native desktop terminal host, POSIX launcher path, and slim AgentD sidecar.

ZiggyZag is usable for testing and development, but it is still alpha software. The Windows desktop host is the most complete native desktop path today. macOS and Linux currently build the shell, AgentD, and a terminal-attached desktop launcher while native graphical hosting continues to mature.

## Start Here

| Need | Read |
| --- | --- |
| Project overview | [Root README](../README.md) |
| Build and run commands | [Quick Start](QUICK_START.md) |
| What is in scope | [Product Scope](SCOPE.md) |
| Current capabilities | [Features And Roadmap](FEATURES.md) |
| System shape | [Architecture](ARCHITECTURE.md) |
| Contribution workflow | [Contributing](../CONTRIBUTING.md) |

## Planning And Alpha Work

| Topic | Read |
| --- | --- |
| Current alpha gaps and task list | [Alpha Task List And Missing Work](ALPHA_TASKS.md) |
| How task status moves | [Task System](TASK_SYSTEM.md) |
| Next near-term feature wave | [Next 20 Features](NEXT_20_FEATURES.md) |
| Official research traceability | [Research Library](RESEARCH.md) |
| Research-backed product direction | [Research-Backed Roadmap](ROADMAP.md) |
| Built-in terminal strategy | [Built-In Terminal App Strategy](TERMINAL_APP.md) |
| All-Zig terminal direction | [All-Zig Terminal Direction](ALL_ZIG_TERMINAL.md) |
| QA, release, and evidence map | [Data And QA Map](DATA_MAP.md) |

## QA And Release

| Topic | Read |
| --- | --- |
| Daily-driver validation | [Daily-Driver QA](DAILY_DRIVER_QA.md) |
| Alpha readiness checklist | [Alpha QA Checklist](QA_TOMORROW.md) |
| Release artifact process | [Root README: Release Artifacts](../README.md#release-artifacts) |
| Release build script | [scripts/build-release.ps1](../scripts/build-release.ps1) |
| Release artifact QA script | [scripts/qa-release-artifacts.ps1](../scripts/qa-release-artifacts.ps1) |

## App-Specific Docs

| Component | Read |
| --- | --- |
| Shell app | [apps/shell README](../apps/shell/README.md) |
| Desktop host | [apps/desktop README](../apps/desktop/README.md) |
| AgentD sidecar | [apps/agentd README](../apps/agentd/README.md) |
| Historical Tauri spike | [apps/desktop-tauri-spike README](../apps/desktop-tauri-spike/README.md) |

## Documentation Notes

- Planning documents are intentionally honest about alpha gaps, incomplete platform parity, and areas still under research.
- [ALPHA_TASKS.md](ALPHA_TASKS.md) is the source of truth for alpha remaining work; [NEXT_20_FEATURES.md](NEXT_20_FEATURES.md) is the execution roadmap.
- Release artifact guidance currently lives in the root README and release scripts rather than a dedicated release document.
- Research source mapping lives in [RESEARCH.md](RESEARCH.md); broader product ideas live in [ROADMAP.md](ROADMAP.md).
