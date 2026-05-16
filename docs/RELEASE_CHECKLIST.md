# Release Checklist

This checklist covers every step between finishing implementation work and calling a ZiggyZag alpha release ready. Work through the steps in order. Do not skip any gate.

See [ALPHA_TASKS.md](ALPHA_TASKS.md) for the full list of what is and is not shipped, and [DAILY_DRIVER_QA.md](DAILY_DRIVER_QA.md) for the interactive daily-driver gates that the automated script cannot cover.

## Step 1: Build And Unit Tests

```powershell
zig build
zig build test
```

Both must exit cleanly with no errors or test failures. If either fails, do not proceed.

## Step 2: Shell And AgentD Smoke

```powershell
# Windows
.\scripts\smoke.ps1
```

```sh
# POSIX (Linux / macOS)
bash scripts/smoke.sh
```

These scripts exercise the shell REPL (REPL entry, builtins, history, completions), basic pipeline behavior, and AgentD `--describe-tools` and `--oneshot` responses. All checks must pass.

## Step 3: Broader QA Tomorrow Script

```powershell
.\scripts\qa-tomorrow.ps1
```

Covers shell smoke, AgentD smoke, desktop launch/close smoke, and cross-built archive structure checks. Run on Windows. All checks must pass.

## Step 4: Daily-Driver Automated Pass

```powershell
.\scripts\daily-driver-qa.ps1 -Automated
```

This runs the automated portions of the daily-driver QA: shell REPL start/exit, builtin smoke, completion trigger, history round-trip, AgentD health, and basic desktop host launch and close.

After the automated pass, complete the manual checklist in [DAILY_DRIVER_QA.md](DAILY_DRIVER_QA.md). The manual gates include:

- Scrollback and search in the desktop host
- Split pane creation, focus switching, and Ctrl+C isolation
- AgentD panel: health, tools list, `terminal.write` approval flow
- Unicode rendering, wide characters, and known edges
- Paste, copy-visible, quick-select
- Theme cycling (Ctrl+Shift+T)
- Settings overlay
- Command palette

Do not call the release ready until the manual gates pass or known failures are recorded as explicit edges.

## Step 5: Build Release Artifacts

```powershell
.\scripts\build-release.ps1 -Version <version> -Optimize ReleaseSafe
```

Replace `<version>` with the release tag (e.g. `v0.1.0-alpha.3`). The script cross-compiles for all five targets and assembles one zip per target plus a checksum file and manifest.

Expected artifacts in the output directory:

| File | Target |
| --- | --- |
| `ZiggyZag-<version>-windows-x86_64.zip` | Windows x86_64 |
| `ZiggyZag-<version>-linux-x86_64.zip` | Linux x86_64 |
| `ZiggyZag-<version>-linux-aarch64.zip` | Linux aarch64 |
| `ZiggyZag-<version>-macos-x86_64.zip` | macOS Intel |
| `ZiggyZag-<version>-macos-aarch64.zip` | macOS Apple Silicon |
| `checksums.sha256` | SHA-256 hashes for all zips |
| `release-manifest.json` | Version, targets, file list |

Each zip contains:

```
ZiggyZag/
  bin/ziggyzag
  bin/ziggyzag-agentd
  bin/ziggyzag-desktop    (Windows only)
  bin/ziggyzag-launcher
  README.md
  LICENSE
```

## Step 6: Artifact QA

```powershell
.\scripts\qa-release-artifacts.ps1 -Version <version>
```

Verifies zip structure, file presence, checksums, and that the extracted Windows runtime binaries respond to `--help`. All checks must pass before the artifacts are distributed.

## Step 7: Cross-Platform Host Matrix

Run the release zip smoke commands documented in [QA_TOMORROW.md](QA_TOMORROW.md) on real or CI hosts. The current host matrix and its alpha status:

| Platform | Host | Shell + AgentD | Notes |
| --- | --- | --- | --- |
| Windows x86_64 | Full native (Win32/ConPTY) | Yes | Alpha-ready |
| Linux x86_64 | Terminal-attached launcher only | Yes | No native graphical window |
| Linux aarch64 | Terminal-attached launcher only | Yes | No native graphical window |
| macOS Intel | Terminal-attached launcher only | Yes | No native graphical window |
| macOS Apple Silicon | Terminal-attached launcher only | Yes | No native graphical window |

"Alpha-ready" for a platform means: the release zip smoke commands pass on a real host or CI runner, and the pass/fail result is recorded in [DATA_MAP.md](DATA_MAP.md).

Do not claim cross-platform artifacts are tested until the POSIX smoke commands have been run on at least one real Linux and one real macOS host.

## Step 8: Version Bump And Tagging

Update the version string in `build.zig` (or wherever the project version is declared) to match the release tag. Create a git tag:

```powershell
git tag -a v<version> -m "Alpha release v<version>"
```

Do not push the tag until all previous steps have passed.

## Alpha-Ready Gates Summary

A release is **not** alpha-ready if any of the following are unresolved:

- `zig build` or `zig build test` fails
- Any smoke script check fails
- Any automated daily-driver QA check fails
- Any manual daily-driver gate in [DAILY_DRIVER_QA.md](DAILY_DRIVER_QA.md) fails without being recorded as an explicit known edge
- Release artifact QA script reports missing files or checksum mismatches
- The Windows runtime smoke (extracted zip `--help` test) fails
- No POSIX runtime smoke result is recorded for the current artifact set

See [ALPHA_TASKS.md](ALPHA_TASKS.md) for the P0 correctness items that must be addressed before expanding distribution beyond the current friend-tester group.
