# `v0.1.0-alpha.3` Release-Readiness Checklist

Wave 2 is complete on disk. This document is the exact sequence to follow on a Windows machine with Zig 0.16.0 installed to verify the build, run the audits, and tag `alpha.3`.

Everything below is mechanical. Nothing in this checklist requires judgment unless something fails — in which case stop and read the failure before continuing.

## 0. Pre-flight (30 seconds)

```powershell
cd C:\Users\pasca\dev\ZiggyZag
git status
git log --oneline -10
```

Expected: working tree clean (or with the polish-pass changes uncommitted), HEAD on `master`, last commits including the audit work.

## 1. Build & test (5 minutes)

```powershell
zig version
# Expected: 0.16.0

zig build
# Expected: zig-out\bin\ziggyzag.exe, ziggyzag-desktop.exe,
#           ziggyzag-agentd.exe, ziggyzag-launcher.exe all materialise

zig build test
# Expected: every test green. Test count went from 177 (alpha.2 baseline)
#           to ~190 after the polish-pass additions:
#             +6 theme env-var/builtin tests
#             +1 isConfigDirective("theme") assertion
#             +1 JSON encoder control-byte test
#             +1 TSV round-trip test
#             +1 theme registry count test (=20)
#             +2 selects-themes-by-name expanded assertions
```

**If `zig build test` fails:**
- Most likely cause: `apps/desktop/src/theme.zig` truncation. The file should be 790 lines with 20 themes and 5 test blocks. Re-read it; if it's short, the polish pass's repair did not persist.
- Second-most-likely cause: a Zig 0.16 stdlib API change since the patches were written. The error message will name a specific symbol — search for it in `apps/shell/src/main.zig` (most polish work landed there).

## 2. Smoke & QA (3 minutes)

```powershell
.\scripts\smoke.ps1
.\scripts\qa-tomorrow.ps1
```

Expected: both green. Smoke covers the shell + builtins; `qa-tomorrow.ps1` is the broader Windows daily-driver pre-flight.

## 3. Manual spot-checks (5 minutes)

```powershell
# Theme env-var path
$env:ZIGGYZAG_THEME = "tokyo-night"
.\zig-out\bin\ziggyzag.exe -c "theme; theme list; theme catppuccin-mocha; theme; exit"
# Expected: first `theme` reports "tokyo-night (Tokyo Night)".
#           `theme list` shows 20 entries with `* tokyo-night` highlighted.
#           After `theme catppuccin-mocha`, the next `theme` reports
#           "catppuccin-mocha (Catppuccin Mocha)".

# Bad theme fallback
$env:ZIGGYZAG_THEME = "no-such-theme"
.\zig-out\bin\ziggyzag.exe -c "theme; exit"
# Expected: "ziggy (Ziggy)" — the fallback kicked in silently.

# JSON encoder regression (RFC 8259)
.\zig-out\bin\ziggyzag.exe -c "echo --json; about --json | head; exit"
# Expected: valid JSON.

# AgentD watchdog regression (round-1 fix)
echo '{"id":1,"method":"agent/health"}' | .\zig-out\bin\ziggyzag-agentd.exe --stdio
# Expected: returns within ~1 second with a health envelope.
# Before the round-1 watchdog fix, any commandJsonAlloc tool call hung 30s
# then returned ToolTimedOut. Health doesn't exercise that path but confirms
# the daemon spins up.
```

## 4. Accessibility audit re-run (30 seconds)

```powershell
python scripts\audit_contrast.py --write-report
git diff docs\reference\accessibility.md
```

Expected: no change to the report (it was last regenerated this session). If there IS a diff, the audit script re-ran against the canonical theme.zig and produced a different result — investigate before tagging.

## 5. Release artifact dry-run (10 minutes)

```powershell
$Version = "v0.1.0-alpha.3"
.\scripts\build-release.ps1 -Version $Version -Optimize ReleaseSafe -DryRun
```

Expected: the build plan prints without errors. Drop `-DryRun` when ready to actually package.

## 6. Tag and push

```powershell
# Stage everything from the polish pass.
git add -A

# Commit. The CHANGELOG already has the [Unreleased] entries; this commit is
# what graduates them into the tagged release.
git commit -m "alpha.3: Wave 2 polish — themes, brand, docs, ops, five bug fixes" -m @"
- Unified theme protocol v1 (ZIGGYZAG_THEME env var + theme builtin + 20-theme registry)
- Brand & visual identity: hero/wordmark/gallery/agent-panel/split-panes/palette/prompt-themes/favicon/og
- Doc reorganisation into docs/{guides,reference,vision,reviews}/ (27 files, kebab-case, single hub)
- Ops: CHANGELOG, SECURITY, install.sh/install.ps1, tag-triggered release.yml, macOS in CI
- Specs (paper-only for now): history-backend.md, sessions.md, vt-conformance.md, osc8-hyperlinks.md
- WCAG AA contrast audit across all 20 themes (8 pass / 12 documented as needs-work)
- 5 real bugs fixed: AgentD watchdog deadlock, theme not in config, JSON encoder control bytes,
  history metadata never loaded on startup, dir_index race
- 7 false alarms documented honestly in docs/reviews/2026-05-17-polish.md
"@

# Push master.
git push github master

# Tag the release. The release.yml workflow picks this up automatically.
git tag -a v0.1.0-alpha.3 -m "ZiggyZag v0.1.0-alpha.3 — Wave 2 close"
git push github v0.1.0-alpha.3
```

## 7. Watch the release workflow

```powershell
# Open the Actions page and confirm:
#   1. build-test-smoke (CI) is green on ubuntu, windows, macos
#   2. release (release.yml) packages zips for all 5 targets
#   3. smoke-posix smoke-tests the extracted binaries on linux + macos
#   4. release job drafts a GitHub Release with assets attached
gh run watch
```

Expected: all four jobs green. If a smoke fails on Linux or macOS, the binary built but didn't run correctly on the target — typically a stdlib or PTY-relay issue specific to that OS.

## 8. Publish the draft release

The `release.yml` workflow drops a draft release with all zips attached. The release notes are pre-written at [`docs/releases/v0.1.0-alpha.3.md`](../releases/v0.1.0-alpha.3.md). Copy that into the draft, publish.

## 9. Enable GitHub Pages

If not already on: repo Settings → Pages → Source `master` branch, `/docs` folder. The landing page lives at `https://pascalai2024.github.io/ZiggyZag/` within a minute. Add that URL to the repo About sidebar.

## 10. Done

The Wave 2 cohort gate is `alpha.3` shipped. Wave 3 entry gates are documented at [`docs/vision/waves.md`](../vision/waves.md#wave-3--cross-platform-planned):
- Native macOS desktop host launches a window
- Native Linux desktop host launches a window
- `apps/desktop/src/pty.zig` goes from stub to real shared abstraction
- AgentD `Ctrl+Space` universal-input overlay ships
- Three friend testers signed up

None of those are addressable in a no-compile sandbox — they're real implementation work for the next session.

## Rollback plan

If `alpha.3` ships and something is broken in the wild:

```powershell
# Mark the bad tag as broken in CHANGELOG with a "Withdrawn:" note.
# Delete the draft GitHub Release (if not yet published).
# If published: edit the release notes to point at the next fix tag,
#  don't delete the tag itself.

# Cut a fix branch off the parent of the broken tag.
git checkout -b fix/alpha-3-issue v0.1.0-alpha.2

# Cherry-pick the fix, re-test, tag as alpha.3.1.
git push github fix/alpha-3-issue
git tag -a v0.1.0-alpha.3.1 -m "Fix <whatever broke>"
git push github v0.1.0-alpha.3.1
```

The release artifact workflow re-runs on the new tag automatically.
