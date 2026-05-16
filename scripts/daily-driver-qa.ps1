param(
    [switch]$Automated,
    [switch]$PrintOnly,
    [string]$ReportPath
)

$ErrorActionPreference = "Continue"

$Root = Split-Path -Parent $PSScriptRoot
$Results = New-Object System.Collections.Generic.List[object]

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "== $Text ==" -ForegroundColor Cyan
}

function Resolve-Zig {
    if ($env:ZIG_EXE -and (Test-Path $env:ZIG_EXE)) {
        return (Resolve-Path $env:ZIG_EXE).Path
    }

    $zigCommand = Get-Command zig -ErrorAction SilentlyContinue
    if ($zigCommand) {
        return $zigCommand.Source
    }

    if ($env:LOCALAPPDATA) {
        $wingetRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
        if (Test-Path $wingetRoot) {
            $wingetZig = Get-ChildItem -Path $wingetRoot -Recurse -Filter zig.exe -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1 -ExpandProperty FullName
            if ($wingetZig) {
                return $wingetZig
            }
        }
    }

    return $null
}

function Add-Result {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail
    )

    $Results.Add([pscustomobject]@{
        Name = $Name
        Status = $Status
        Detail = $Detail
    }) | Out-Null
}

function Run-Step {
    param(
        [string]$Name,
        [scriptblock]$Body,
        [switch]$WarnOnly
    )

    Write-Section $Name
    $global:LASTEXITCODE = 0
    $status = "PASS"
    $detail = "ok"

    try {
        $output = & $Body 2>&1
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }

        if ($output) {
            $output | Out-String -Stream | ForEach-Object {
                if ($_.Length -gt 0) {
                    Write-Host $_
                }
            }
        }

        if ($exitCode -ne 0) {
            throw "$Name exited with code $exitCode"
        }
    } catch {
        $detail = $_.Exception.Message
        if ($WarnOnly) {
            $status = "WARN"
            Write-Host "[WARN] $Name - $detail" -ForegroundColor Yellow
        } else {
            $status = "FAIL"
            Write-Host "[FAIL] $Name - $detail" -ForegroundColor Red
        }
    }

    if ($status -eq "PASS") {
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }

    Add-Result $Name $status $detail
}

function Assert-LastExit {
    param([string]$What)
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed with exit code $LASTEXITCODE"
    }
}

function Test-IsWindows {
    return [System.Environment]::OSVersion.Platform -eq "Win32NT"
}

function Write-ManualChecklist {
    Write-Section "Manual daily-driver checklist"
    Write-Host "Use docs\DAILY_DRIVER_QA.md as the source of truth."
    Write-Host ""
    Write-Host "[ ] Record tester, date, OS, architecture, Zig version, commit, artifact path."
    Write-Host "[ ] Run entry gate: zig build, zig build test, smoke, AgentD health, desktop launch/close."
    Write-Host "[ ] Keep one interactive session open for 2+ hours; 4 hours is better."
    Write-Host "[ ] Resize repeatedly, paste multi-line text, copy visible text, and reopen once."
    Write-Host "[ ] Produce 5000+ lines of output, scroll, resize, and run a command afterward."
    Write-Host "[ ] Verify Ctrl+C interrupts a foreground command and Ctrl+D exits only on an empty line."
    Write-Host "[ ] Run a full-screen TUI such as vim, nvim, nano, less, top, htop, or tig."
    Write-Host "[ ] Start a background job, check jobs while running, wait, and confirm reaping."
    Write-Host "[ ] Check prompt latency in repo root, a small directory, and a large or synced folder."
    Write-Host "[ ] Close/reopen after foreground, large-output, and background-job scenarios."
    Write-Host "[ ] Expand a new release zip beside the previous zip and confirm rollback works."
    Write-Host "[ ] Confirm AgentD terminal.write returns a host action and does not apply by itself."
    Write-Host "[ ] Capture PASS/WARN/FAIL/SKIP notes for each section."
}

function New-ReportTemplate {
    param([string]$Path)

    $template = @"
# ZiggyZag Daily-Driver QA Report

Tester:
Date:
OS and version:
Architecture:
Zig version:
Commit:
Artifact or local build path:
Terminal used to launch ZiggyZag:

| Section | Result | Notes |
| --- | --- | --- |
| Entry gate |  |  |
| Main-terminal session |  |  |
| Large output and scrollback |  |  |
| Ctrl+C and Ctrl+D |  |  |
| Full-screen TUIs |  |  |
| Background jobs |  |  |
| Prompt latency |  |  |
| Crash recovery |  |  |
| Install and rollback |  |  |
| AgentD approval safety |  |  |
| Platform runtime smoke |  |  |

Logs, screenshots, or repro commands:

"@

    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $directory = Split-Path -Parent $resolved
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Set-Content -Path $resolved -Value $template -Encoding UTF8
    Write-Host "Wrote report template: $resolved" -ForegroundColor Green
}

function Invoke-AutomatedGate {
    Set-Location $Root
    $zig = Resolve-Zig

    Write-Section "Automated entry gate"
    Write-Host "Repo: $Root"

    if (-not $zig) {
        Add-Result "resolve zig" "FAIL" "No zig executable found."
        Write-Host "[FAIL] No zig executable found. Install Zig 0.16.0 or set ZIG_EXE." -ForegroundColor Red
        return
    }

    Write-Host "Using Zig: $zig"
    $zigVersion = & $zig version
    Write-Host "Zig version: $zigVersion"

    if ($zigVersion -notmatch "^0\.16\.0") {
        Add-Result "zig version" "WARN" "Expected Zig 0.16.0; found $zigVersion."
        Write-Host "[WARN] Expected Zig 0.16.0. Continuing." -ForegroundColor Yellow
    } else {
        Add-Result "zig version" "PASS" $zigVersion
    }

    if (Test-IsWindows) {
        Run-Step "tomorrow QA script" {
            & "$Root\scripts\qa-tomorrow.ps1"
            Assert-LastExit "tomorrow QA script"
        }
    } else {
        Run-Step "zig build" {
            & $zig build
            Assert-LastExit "zig build"
        }

        Run-Step "zig build test" {
            & $zig build test
            Assert-LastExit "zig build test"
        }

        Run-Step "POSIX shell smoke" {
            sh "$Root/scripts/smoke.sh"
            Assert-LastExit "POSIX shell smoke"
        }

        Run-Step "POSIX AgentD describe-tools" {
            & "$Root/zig-out/bin/ziggyzag-agentd" --describe-tools
            Assert-LastExit "POSIX AgentD describe-tools"
        }

        Run-Step "POSIX desktop launcher smoke" {
            "exit`n" | & $zig build run-desktop
            Assert-LastExit "POSIX desktop launcher smoke"
        }
    }

    Run-Step "git diff whitespace check" {
        git -c core.safecrlf=false diff --check
        Assert-LastExit "git diff --check"
    }
}

Write-Host "ZiggyZag daily-driver QA"
Write-Host "Repo: $Root"

if (-not $PrintOnly -and $Automated) {
    Invoke-AutomatedGate
}

Write-ManualChecklist

if ($ReportPath) {
    New-ReportTemplate -Path $ReportPath
}

if ($Results.Count -gt 0) {
    Write-Section "Automated summary"
    $Results | Format-Table -AutoSize

    $failCount = @($Results | Where-Object { $_.Status -eq "FAIL" }).Count
    if ($failCount -gt 0) {
        Write-Host "[FAIL] $failCount automated check(s) failed. Do not start friend testing yet." -ForegroundColor Red
        exit 1
    }

    Write-Host "[PASS] Automated entry gate passed. Continue with the manual multi-hour session." -ForegroundColor Green
}
