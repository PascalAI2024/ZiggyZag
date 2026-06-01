# ZiggyZag Documentation

This is the documentation hub. Everything is organized into three folders that answer three questions:

1. **`guides/`** — how do I do a specific thing? (install, contribute, run QA, cut a release)
2. **`reference/`** — what is the technical spec? (architecture, protocols, file formats)
3. **`vision/`** — where is this project going and why? (scope, masterplan, waves, research)

External audits live in `reviews/`. The landing page is [`index.html`](index.html). Project-level contracts (README, CHANGELOG, CONTRIBUTING, SECURITY, LICENSE) live at the repo root.

If a doc cannot find a clean home in one of those folders, it probably should not exist yet.

## Start here

| You want to | Open |
| --- | --- |
| Build and run it for the first time | [guides/quick-start.md](guides/quick-start.md) |
| Configure the shell and desktop | [reference/config.md](reference/config.md) |
| Understand the strategic direction | [vision/masterplan.md](vision/masterplan.md) |
| See the public-facing pitch | [index.html](index.html) |
| Read an external review | [reviews/2026-05-17-baseline.md](reviews/2026-05-17-baseline.md) |

## Guides — how to do something

| Guide | When to use |
| --- | --- |
| [Quick start](guides/quick-start.md) | First clone, first build, first run |
| [Contributing tour](guides/contributing-tour.md) | Onboarding for a new contributor — what to read, what to touch |
| [Daily-driver QA](guides/daily-driver-qa.md) | Manual checks before claiming a wave is daily-driver-ready |
| [QA tomorrow](guides/qa-tomorrow.md) | Pre-release-tag QA checklist (Windows-first) |
| [Release checklist](guides/release-checklist.md) | The procedure that wraps the release tag |
| [VT conformance harness](guides/vt-conformance.md) | Spec for the `ziggyzag-conformance` binary — VT/CSI/OSC sequence corpus |

Top-level contracts that act like guides also live in the root: [`../CONTRIBUTING.md`](../CONTRIBUTING.md), [`../SECURITY.md`](../SECURITY.md).

## Reference — technical specs

| Reference | What it covers |
| --- | --- |
| [Architecture](reference/architecture.md) | Process boundaries, command lifecycle, core state |
| [AgentD protocol](reference/agentd-protocol.md) | JSON-lines methods, tool schemas, approval semantics |
| [Theme protocol](reference/theme-protocol.md) | `ZIGGYZAG_THEME` env var + OSC 7777 (v2) |
| [Theme authoring](reference/theme-authoring.md) | How to add a new theme to the registry |
| [OSC 8 hyperlinks](reference/osc8-hyperlinks.md) | Cell model, parser, renderer, and scheme allowlist for `ESC ] 8` |
| [Accessibility](reference/accessibility.md) | WCAG AA contrast audit across every built-in theme |
| [Config](reference/config.md) | Shell and desktop configuration reference |
| [Terminal parser](reference/terminal-parser.md) | VT/CSI/OSC state machine internals |
| [Terminal app](reference/terminal-app.md) | Desktop host strategy, layer boundaries |
| [All-Zig terminal direction](reference/all-zig-terminal.md) | Why no Tauri, no xterm.js, no embedded renderer |
| [Features](reference/features.md) | Current capability table |
| [Brand](reference/brand.md) | Semantic color tokens, type scale, voice rules |
| [Task system](reference/task-system.md) | How task status moves across alpha/TODO/shipped |
| [Data map](reference/data-map.md) | QA evidence map — which scripts produce which artifacts |

## Vision — strategy and planning

| Vision doc | What it says |
| --- | --- |
| [Scope](vision/scope.md) | What ZiggyZag is and is not |
| [Masterplan](vision/masterplan.md) | The north star, principles, strategic moves |
| [Waves](vision/waves.md) | Release plan with explicit entry gates |
| [Roadmap](vision/roadmap.md) | Research-backed feature ranking |
| [References](vision/references.md) | What we lifted from Warp, Ghostty, WezTerm, fish, Starship, Atuin |
| [Alpha tasks](vision/alpha-tasks.md) | Line-by-line remaining work for the alpha line |
| [Next 20 features](vision/next-20-features.md) | Daily-driver execution backlog |
| [Research](vision/research.md) | Source library and traceability |

## Reviews — external audits over time

| Date | Reviewer | Verdict |
| --- | --- | --- |
| [2026-05-17](reviews/2026-05-17-baseline.md) | First external pass | Baseline — became the input to the current masterplan |

Future reviews file alongside.

## Per-app docs

App-internal documentation lives next to the code, not here. Cross-link only when relevant:

- [`apps/shell/README.md`](../apps/shell/README.md)
- [`apps/desktop/README.md`](../apps/desktop/README.md)
- [`apps/agentd/README.md`](../apps/agentd/README.md)

## Conventions

- **Filenames** are `kebab-case.md`. No `SCREAMING_SNAKE_CASE`, no spaces, no version suffixes.
- **Cross-links** are markdown links to relative paths. Use the path that works when the file is browsed on GitHub. Do not link to GitHub URLs for files in this repo.
- **Honesty over enthusiasm.** If something is alpha, say so. If a feature is missing on macOS, say so.
- **A doc that contradicts another doc** is a bug. File it as you would file a code bug and fix the contradiction, not the symptom.
- **A doc with no link from this hub** is invisible. Either link it or delete it.

## Where new docs go

- Action-oriented ("how do I do X?") → `guides/`
- Specification or interface ("what is the format of X?") → `reference/`
- Strategy, scope, or planning ("why is X this way and what's next?") → `vision/`
- External assessment ("what does someone else think of X?") → `reviews/`

If a new doc doesn't fit, the system might need a fourth folder — but pause and ask before adding one. The whole point is that there are three.
