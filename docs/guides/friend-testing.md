# Friend Testing — Wave 3, Cohort 1

You are one of the first three people outside Pascal to run ZiggyZag as a primary terminal. This page is what you read first.

For background, the masterplan is at [`vision/masterplan.md`](../vision/masterplan.md), the wave plan with entry-gates and rollback criteria is at [`vision/waves.md`](../vision/waves.md), and the two external audits that opened this cohort are in [`reviews/2026-05-17-baseline.md`](../reviews/2026-05-17-baseline.md) and [`reviews/2026-05-17-polish.md`](../reviews/2026-05-17-polish.md). Read those when you want to know exactly what state the alpha is in. They are honest about what is broken.

## Welcome

ZiggyZag is a small Zig workspace — a readable shell, a native Windows terminal host, and a local AI sidecar that share themes, events, and approval semantics. It is not trying to replace WezTerm, Ghostty, or Warp. It is trying to be a daily-driver-quality terminal that you can read end-to-end in a focused sitting, with no telemetry and no account.

Wave 3 opens to three friend testers: one on Windows, one on macOS, one on Linux. You signed up to run ZiggyZag as your primary terminal for **at least two weeks**, file lightweight reports when something feels off, and write a 200-word reaction at the 14-day mark. That is the whole contract. There is no NDA, no scheduled call, no thank-you swag — just a credit in the Wave 4 announcement if you want one.

## What is expected (and what isn't)

What you will **not** be asked to do:

- No telemetry will ever phone home. We do not know if you used it today.
- No auto-update. New versions are zips you choose to extract.
- No account. There is no login, no sync, no cloud anything.
- No NDA, no "please don't blog about this." Tell anyone.

What we ask:

- File a GitHub issue when something feels off. One line is fine.
- Run `scripts/smoke.ps1` (Windows) or `scripts/smoke.sh` (POSIX) when a new tag asks for it. Takes ~30 seconds.
- Copy/paste tracebacks verbatim. Do not retype.
- Be the kind of tester who reports the small visual glitch nobody else mentions.

## Install order

Follow [`guides/quick-start.md`](quick-start.md) end-to-end. The short version: install Zig 0.16.0, `git clone`, `zig build`, run `./zig-out/bin/ziggyzag`. Total time on a fresh laptop is about 2 minutes.

If you prefer prebuilt artifacts, the [releases page](https://github.com/PascalAI2024/ZiggyZag/releases) has signed zips for `windows-x86_64`, `linux-x86_64`, `linux-aarch64`, `macos-x86_64`, and `macos-aarch64`. Each zip ships with a `checksums.sha256` file — verify it before extracting. We do not yet code-sign the Windows binary; SmartScreen will complain. The Wave 6 gate fixes that.

## Rollback plan

If ZiggyZag breaks on you, the rollback to your previous shell + terminal is one command. Your shell history is preserved across uninstalls because `HISTFILE` (or `ZIGGYZAG_HISTORY_DB` if you set it) lives outside the extracted artifact directory.

PowerShell:

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\ZiggyZag"
# Then re-open Windows Terminal or your previous shell. PowerShell history is intact.
```

POSIX (bash/zsh/fish):

```sh
rm -rf ~/.local/share/ziggyzag ~/.config/ziggyzag
# Then re-open Terminal / iTerm / your previous emulator. ~/.bash_history etc. are untouched.
```

Nothing in those paths touches `~/.zshrc`, `~/.bashrc`, `~/.config/fish/`, or your existing terminal's settings. Uninstalling ZiggyZag does not change your default shell — we never set it for you.

## How to report something

Use the GitHub issue templates. Pick by symptom:

- `bug-report.md` — anything visibly broken.
- `crash-report.md` — process died or hung. Include the `doctor --json` output.
- `friend-tester-note.md` — small papercut, not a crash. One sentence is fine.

Attach when relevant:

- Your config path (`~/.ziggyzagrc` or `%APPDATA%\ZiggyZag\desktop.conf`).
- `doctor --json` output (it captures version, platform, env, paths).
- A 5-10 line excerpt of the AgentD audit log if AgentD misbehaved.

Do **not** attach:

- Anything from `~/.ssh/` or `%USERPROFILE%\.ssh\`.
- Any env var matching `*_TOKEN`, `*_KEY`, `*_SECRET`, `AWS_*`, `OPENAI_API_KEY`.
- Private repo paths or anything under NDA at your job.

AgentD already redacts these in its tool output, but issue attachments don't get that filter. Eyeball your paste before posting.

## Daily flow

Wake up. Open ZiggyZag. Hit `Ctrl+Shift+T` once to cycle to a fresh theme — this is the "is it still working" check. Run your normal commands. When something feels off (sluggish, weird repaint, wrong color, unexpected exit code), file a one-line issue. Do not try to make ZiggyZag your only shell on day one — keep your usual terminal open in another window for the first 48 hours.

The shell config lives at `~/.ziggyzagrc`. Aliases, abbreviations, completions, prompt mode, theme — all there. It is a tiny custom format, not bash-compatible. Complex shell pipelines fall back to `/bin/sh -c` or `cmd /C`, so most things work, but unusual syntax may bite.

## The 14-day milestone

At two weeks, write a 200-word reaction. Anything you want — what worked, what didn't, whether you'd keep using it, what the next person should know before they sign up. Send it as a GitHub issue tagged `tester-reaction` or email it to the maintainer (address in [`SECURITY.md`](../../SECURITY.md)).

Three of those reactions get quoted in the public Wave 4 announcement, with your handle and a link if you want one. The other reactions stay private. We do not edit your words.

## Things we know are missing

Don't waste a report on these — they are tracked and dated:

- **Tabs.** Wave 5. Split panes work on Windows today; tabs do not.
- **Native macOS window.** Wave 3 exit gate. Today the macOS desktop binary launches the shell in the calling terminal.
- **SQLite history backend.** Wave 4. Today history is a TSV file with metadata.
- **OSC 7777 live theme updates.** Wave 4. Today theme change requires a new process.
- **Signed Windows installer.** Wave 6. SmartScreen will warn on first run.

Everything else is fair game. Thanks for being here.
