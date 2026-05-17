# ZiggyZag Task System

This guide explains how ZiggyZag's research notes, roadmaps, alpha task list, QA checklists, and release scripts fit together. The goal is to keep implementation work honest: research can inspire the roadmap, the roadmap can propose features, but the alpha checklist decides what remains before the current alpha can be called ready.

Start at [README.md](../README.md) for the documentation hub. Use [research.md](../vision/research.md) for source-backed product signals and [data-map.md](data-map.md) for QA/release evidence flow.

## Source Of Truth

`docs/ALPHA_TASKS.md` is the source of truth for remaining alpha work.

When docs disagree, use this order:

1. `docs/ALPHA_TASKS.md` for alpha scope, shipped-vs-missing status, P0/P1/P2 priority, and release readiness.
2. `docs/QA_TOMORROW.md` for the current alpha smoke checklist and release-zip validation commands.
3. `docs/DAILY_DRIVER_QA.md` for multi-hour friend-test and main-terminal readiness gates.
4. `docs/NEXT_20_FEATURES.md` for research-backed roadmap context and future implementation waves.
5. Release scripts in `scripts/` for executable packaging and verification behavior.

If a contributor finishes alpha work, update `docs/ALPHA_TASKS.md` first. Then update roadmap, QA, README, or release notes only if their claims need to change.

## Priority Definitions

P0 means correctness, stability, safety, or release honesty. A P0 can block alpha sharing even if the product feels good. Examples include broken builds, deadlocks, crashy terminal behavior, misleading artifact claims, unsafe AgentD actions, missing release verification, and unsupported behavior presented as complete.

P1 means daily-driver usability. A P1 does not always block a narrow smoke release, but it affects whether ZiggyZag is pleasant and reliable enough to use as a main terminal. Examples include tabs, selection-aware copy, prompt navigation, settings editing, completion depth, durable history, AgentD panel hardening, and accessibility.

P2 means platform expansion, packaging maturity, and product polish. P2 work is valuable but should not displace P0/P1 alpha stabilization. Examples include native non-Windows graphical hosts, signing/notarization, uninstall/rollback polish, config migrations, contributor docs, renderer strategy, and longer friend-test feedback loops.

## Document Roles

`docs/ALPHA_TASKS.md` is the alpha control board. It records what is shipped, what is missing, what is out of scope, and what must pass before the alpha can be promoted. Treat it as the canonical remaining-work checklist.

`docs/NEXT_20_FEATURES.md` is the research-backed roadmap. It gathers product references, feature opportunities, technical areas, and execution waves. It can contain aspirational work, partial progress, and future waves that are not all alpha blockers.

`docs/QA_TOMORROW.md` is the alpha smoke checklist. It tells a tester how to rerun the Windows, macOS, Linux, AgentD, and release-zip checks for the current alpha line. It is the quick "can we hand this build to someone tomorrow?" guide.

`docs/DAILY_DRIVER_QA.md` is the main-terminal readiness checklist. It is stricter than smoke QA and covers multi-hour sessions, large output, Ctrl+C/Ctrl+D, full-screen TUIs, background jobs, prompt latency, crash recovery, install/rollback, and AgentD approval safety.

The `scripts/` directory turns the docs into repeatable gates:

- `scripts/smoke.ps1` and `scripts/smoke.sh` verify shell behavior and basic native pipeline behavior on Windows and POSIX.
- `scripts/qa-tomorrow.ps1` runs the Windows alpha smoke gate and summarizes failures without stopping at the first problem.
- `scripts/daily-driver-qa.ps1` runs or prints the daily-driver gate and can generate tester report templates.
- `scripts/build-release.ps1` cross-builds release zips, writes `checksums.sha256`, and writes `release-manifest.json`.
- `scripts/qa-release-artifacts.ps1` verifies release zips, archive contents, binary headers, checksums, manifest consistency, and extracted Windows runtime smoke.

## Workflow

Use this flow for new work:

1. Research
   Capture product references, constraints, and tradeoffs in `docs/NEXT_20_FEATURES.md` or a focused research note. Research should name what ZiggyZag should learn from, not blindly copy.

2. Roadmap
   Promote research into roadmap items in `docs/NEXT_20_FEATURES.md`. Roadmap items should describe user value, current progress, likely implementation paths, and primary code areas.

3. Alpha Triage
   Decide whether the work affects the current alpha. If yes, add or update the relevant P0/P1/P2 item in `docs/ALPHA_TASKS.md`. This step is what makes work alpha-committed.

4. Implementation
   Assign ownership by file or area before editing. Keep changes scoped, preserve other workers' edits, and update task docs only when behavior or readiness actually changes.

5. Verification
   Run the smallest meaningful checks while developing, then run the relevant gates from `docs/QA_TOMORROW.md` and `docs/DAILY_DRIVER_QA.md`. For release work, run `scripts/build-release.ps1` and `scripts/qa-release-artifacts.ps1`.

6. Promotion
   Move completed items from missing work to shipped status only when implementation and verification evidence exist. Do not mark a roadmap item complete merely because a prototype exists.

## Release Gate

Before an alpha build is presented as ready, the task system expects:

- `zig build`
- `zig build test`
- `scripts/smoke.ps1` or `scripts/smoke.sh` on the target platform
- `scripts/qa-tomorrow.ps1` on Windows
- `scripts/daily-driver-qa.ps1 -Automated` plus the manual checklist in `docs/DAILY_DRIVER_QA.md` for main-terminal claims
- `scripts/build-release.ps1 -Version <version>`
- `scripts/qa-release-artifacts.ps1 -Version <version>`
- Real or CI runtime smoke for Linux and macOS release zips before claiming those artifacts were runtime-tested

If any gate fails, keep the failure visible in `docs/ALPHA_TASKS.md` or the relevant QA doc. Do not hide it in a release note after the fact.

## Consistency Rules

- Do not add a feature to README or release copy unless `docs/ALPHA_TASKS.md` says it is shipped or the copy clearly labels it as planned.
- Do not use `docs/NEXT_20_FEATURES.md` as a completion source. It is a roadmap, not the alpha checklist.
- Do not let QA docs overclaim platform support. Windows has the native graphical host in this alpha; macOS/Linux have shell, AgentD, and a terminal-attached desktop launcher unless `docs/ALPHA_TASKS.md` says otherwise.
- Do not mark release artifacts as tested on Linux or macOS until the release-zip smoke commands have run on real hosts or CI runners for those targets.
- When a script changes behavior, update the doc that tells people to run it.
- When a doc changes a readiness requirement, update or create a script only if the requirement can be automated safely.

## Practical Update Checklist

When starting work:

- Check `docs/ALPHA_TASKS.md` for priority and remaining alpha scope.
- Check `docs/NEXT_20_FEATURES.md` for broader context and known progress.
- Check the relevant QA doc before changing test or release expectations.

When finishing work:

- Update `docs/ALPHA_TASKS.md` if alpha shipped/missing status changed.
- Update `docs/NEXT_20_FEATURES.md` if roadmap progress changed.
- Update `docs/QA_TOMORROW.md` or `docs/DAILY_DRIVER_QA.md` if testers must run a different command or judge a different behavior.
- Run the relevant scripts and record failures honestly.

For the current alpha, the shortest rule is: if it changes what remains before alpha, it must be reflected in `docs/ALPHA_TASKS.md`.
