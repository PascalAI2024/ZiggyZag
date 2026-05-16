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

    $wingetRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (Test-Path $wingetRoot) {
        $wingetZig = Get-ChildItem -Path $wingetRoot -Recurse -Filter zig.exe -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
        if ($wingetZig) {
            return $wingetZig
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
            $output | ForEach-Object { Write-Host $_ }
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

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )
    if ($Text -notmatch $Pattern) {
        throw $Message
    }
}

Set-Location $Root
$Zig = Resolve-Zig

Write-Host "ZiggyZag tomorrow QA"
Write-Host "Repo: $Root"

if (-not $Zig) {
    Write-Host "[FAIL] No zig executable found." -ForegroundColor Red
    Write-Host "Install Zig 0.16.0, set ZIG_EXE, or add zig.exe to PATH, then rerun this script."
    exit 1
}

Write-Host "Using Zig: $Zig"
$zigVersion = & $Zig version
Write-Host "Zig version: $zigVersion"

if ($zigVersion -notmatch "^0\.16\.0") {
    Write-Host "[WARN] Expected Zig 0.16.0. Continuing, but mismatched compiler versions can cause noisy failures." -ForegroundColor Yellow
}

Run-Step "zig build" {
    & $Zig build
    Assert-LastExit "zig build"
}

Run-Step "zig build test" {
    & $Zig build test
    Assert-LastExit "zig build test"
}

Run-Step "shell smoke" {
    & "$Root\scripts\smoke.ps1"
    Assert-LastExit "shell smoke"
}

Run-Step "manual shell command subset" {
    $shell = Join-Path $Root "zig-out\bin\ziggyzag.exe"
    if (-not (Test-Path $shell)) {
        throw "Missing shell binary: $shell"
    }

    $output = @'
help
doctor
history --stats
project
exit
'@ | & $shell
    Assert-LastExit "manual shell subset"

    $joined = ($output -join "`n")
    Assert-Contains $joined "help" "Shell subset output did not include help text."
    Assert-Contains $joined "doctor" "Shell subset output did not include doctor output."
    $output
}

Run-Step "agentd describe-tools" {
    $output = & $Zig build run-agentd -- --describe-tools
    Assert-LastExit "agentd describe-tools"

    $joined = ($output -join "`n")
    foreach ($tool in @("project.info", "file.read", "rg.search", "git.diff", "zig.build", "terminal.write")) {
        Assert-Contains $joined ([regex]::Escape($tool)) "Tool list is missing $tool."
    }
    $output
}

Run-Step "agentd health" {
    $output = '{"id":0,"method":"agent/health"}' | & $Zig build run-agentd -- --stdio
    Assert-LastExit "agentd health"

    $joined = ($output -join "`n")
    Assert-Contains $joined '"ok":true' "agent/health did not return ok:true."
    Assert-Contains $joined '"provider"' "agent/health did not include provider status."
    Assert-Contains $joined '"ready":(true|false)' "agent/health did not include readiness."
    $output
}

Run-Step "agentd stdio tool smoke" {
    $output = @'
{"id":1,"method":"tools/list"}
{"id":2,"method":"tools/call","tool":"project.info"}
{"id":3,"method":"tools/call","tool":"terminal.write","text":"echo qa-agentd\n"}
'@ | & $Zig build run-agentd -- --stdio
    Assert-LastExit "agentd stdio smoke"

    $joined = ($output -join "`n")
    Assert-Contains $joined '"ok":true' "AgentD stdio smoke did not produce ok:true."
    Assert-Contains $joined '"terminal.write"' "AgentD stdio smoke did not include terminal.write."
    Assert-Contains $joined '"host_action"' "terminal.write did not return a host action."
    $output
}

Run-Step "agentd provider fallback" {
    $output = & $Zig build run-agentd -- --oneshot "Return one short sentence for QA."
    Assert-LastExit "agentd oneshot"

    $joined = ($output -join "`n")
    Assert-Contains $joined '"status":"(ok|provider_error|provider_unavailable|curl_unavailable|missing_api_key)"' "AgentD provider response did not include an accepted status."
    if ($joined -notmatch '"status":"ok"') {
        Write-Host "Provider is not ready; structured fallback is acceptable for tomorrow's protocol test." -ForegroundColor Yellow
    }
    $output
}

Run-Step "desktop launch-close smoke" {
    $desktop = Join-Path $Root "zig-out\bin\ziggyzag-desktop.exe"
    if (-not (Test-Path $desktop)) {
        throw "Missing desktop binary: $desktop"
    }

    $process = Start-Process -FilePath $desktop -PassThru -WindowStyle Normal
    Start-Sleep -Seconds 2
    $started = -not $process.HasExited
    $closed = $false

    if ($started) {
        $closed = $process.CloseMainWindow()
        Start-Sleep -Seconds 2
    }

    $process.Refresh()
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        throw "Desktop did not close cleanly and was force-stopped."
    }

    Write-Host "started=$started closed=$closed exited=$($process.HasExited) exit=$($process.ExitCode)"

    if (-not $started) {
        throw "Desktop exited before the smoke test could interact with it."
    }
    if (-not $closed) {
        throw "Desktop did not accept CloseMainWindow."
    }
    if ($process.ExitCode -ne 0) {
        throw "Desktop exited with code $($process.ExitCode)."
    }
}

Run-Step "top-level launcher smoke" {
    $launcher = Join-Path $Root "zig-out\bin\ziggyzag-launcher.exe"
    if (-not (Test-Path $launcher)) {
        throw "Missing launcher binary: $launcher"
    }

    $launcherProcess = Start-Process -FilePath $launcher -PassThru -WindowStyle Normal
    Start-Sleep -Seconds 2
    $launcherProcess.Refresh()

    if ($launcherProcess.HasExited) {
        throw "Launcher exited before the smoke test could interact with it. Exit code: $($launcherProcess.ExitCode)."
    }

    $closed = $launcherProcess.CloseMainWindow()
    Start-Sleep -Seconds 2
    $launcherProcess.Refresh()
    if (-not $launcherProcess.HasExited) {
        Stop-Process -Id $launcherProcess.Id -Force
        throw "Launcher window did not close cleanly and was force-stopped."
    }
    if (-not $closed) {
        throw "Launcher did not accept CloseMainWindow."
    }
    if ($launcherProcess.ExitCode -ne 0) {
        throw "Launcher exited with code $($launcherProcess.ExitCode)."
    }

    Write-Host "launcher_started=True closed=$closed exited=$($launcherProcess.HasExited) exit=$($launcherProcess.ExitCode)"
}

Run-Step "git diff whitespace check" {
    git diff --check
    Assert-LastExit "git diff --check"
}

Write-Host ""
Write-Host "== Final Summary ==" -ForegroundColor Cyan
$Results | Format-Table -AutoSize

$failCount = @($Results | Where-Object { $_.Status -eq "FAIL" }).Count
$warnCount = @($Results | Where-Object { $_.Status -eq "WARN" }).Count

if ($failCount -gt 0) {
    Write-Host "[FAIL] $failCount blocking check(s) failed. Fix these before friend testing." -ForegroundColor Red
    exit 1
}

if ($warnCount -gt 0) {
    Write-Host "[PASS with warnings] Core checks passed, but review the warning(s) above." -ForegroundColor Yellow
    exit 0
}

Write-Host "[PASS] All tomorrow QA checks passed." -ForegroundColor Green
