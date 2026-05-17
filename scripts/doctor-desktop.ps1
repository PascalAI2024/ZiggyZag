#requires -Version 5.1
<#
.SYNOPSIS
    Diagnose and repair the ZiggyZag desktop configuration.

.DESCRIPTION
    The Windows desktop host (ziggyzag-desktop.exe) resolves the shell binary
    via four channels, checked in order:

        1. profile.shell line in %APPDATA%\ZiggyZag\desktop.conf
           (or whatever ZIGGYZAG_DESKTOP_CONFIG points at)
        2. ZIGGYZAG_SHELL_PATH environment variable
        3. ziggyzag.exe next to the desktop binary (in ./bin/ or alongside)
        4. zig-out\bin\ziggyzag.exe relative to the current working directory

    Pre-fix, channels 1 and 2 returned configured paths without checking that
    the file existed, so a stale config produced a startup CreateProcessFailed
    error even when a working ziggyzag.exe was sitting next to the desktop
    binary. The resolver in apps/desktop/src/windows_app.zig is now patched to
    fall through stale configured paths, but old desktop.conf files left over
    from previous installs can still confuse new users.

    This script:
      - Locates desktop.conf
      - Backs it up (.bak.<timestamp>) before any edit
      - Comments out any profile.shell line that points at a non-existent file
      - Comments out any agentd path overrides that point at a non-existent file
      - Verifies the local zig-out\bin binaries exist; reports if not
      - Optionally launches ziggyzag-desktop.exe at the end

    The script is idempotent. Running it on a healthy system reports OK and
    makes no changes.

.PARAMETER ConfigPath
    Override the desktop.conf path. Defaults to $env:ZIGGYZAG_DESKTOP_CONFIG
    or $env:APPDATA\ZiggyZag\desktop.conf.

.PARAMETER RepoRoot
    The ZiggyZag repo. Defaults to the parent of the directory holding this
    script (so running scripts/doctor-desktop.ps1 just works from the repo).

.PARAMETER Launch
    If specified, launches ziggyzag-desktop.exe after diagnosis.

.PARAMETER DryRun
    Report problems but make no changes.

.EXAMPLE
    .\scripts\doctor-desktop.ps1

.EXAMPLE
    .\scripts\doctor-desktop.ps1 -Launch

.EXAMPLE
    .\scripts\doctor-desktop.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RepoRoot,
    [switch]$Launch,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Ok($msg)    { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Info($msg)  { Write-Host "  - $msg" -ForegroundColor Gray }
function Write-Warn($msg)  { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Write-Bad($msg)   { Write-Host "  ✗ $msg" -ForegroundColor Red }
function Write-Section($msg) { Write-Host ""; Write-Host $msg -ForegroundColor White }

# Resolve repo root from the script location.
if (-not $RepoRoot) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepoRoot  = (Resolve-Path (Join-Path $scriptDir '..')).Path
}
if (-not (Test-Path $RepoRoot)) {
    Write-Bad "Repo root does not exist: $RepoRoot"
    exit 2
}

# Resolve desktop.conf path.
if (-not $ConfigPath) {
    if ($env:ZIGGYZAG_DESKTOP_CONFIG) {
        $ConfigPath = $env:ZIGGYZAG_DESKTOP_CONFIG
    } else {
        $ConfigPath = Join-Path $env:APPDATA 'ZiggyZag\desktop.conf'
    }
}

$problemsFound = 0
$repairsMade   = 0

Write-Host ""
Write-Host "ZiggyZag desktop doctor" -ForegroundColor Cyan
Write-Host "  repo:   $RepoRoot"
Write-Host "  config: $ConfigPath"
if ($DryRun) { Write-Host "  mode:   dry run - no changes will be written" -ForegroundColor Yellow }

# --- 1. Check local binaries ------------------------------------------------

Write-Section "1. Local binaries"

$binDir   = Join-Path $RepoRoot 'zig-out\bin'
$expected = @('ziggyzag.exe', 'ziggyzag-desktop.exe', 'ziggyzag-agentd.exe', 'ziggyzag-launcher.exe')
$missing  = @()
foreach ($name in $expected) {
    $path = Join-Path $binDir $name
    if (Test-Path $path) {
        Write-Ok "$name ($([math]::Round(((Get-Item $path).Length / 1KB))) KB)"
    } else {
        Write-Bad "$name missing"
        $missing += $name
    }
}
if ($missing.Count -gt 0) {
    $problemsFound++
    Write-Warn "Run 'zig build' from the repo root to rebuild missing binaries."
}

# --- 2. Check desktop.conf --------------------------------------------------

Write-Section "2. Desktop config ($ConfigPath)"

if (-not (Test-Path $ConfigPath)) {
    Write-Info "No desktop.conf present. Defaults will be used."
    Write-Ok  "Resolver will find ziggyzag.exe next to ziggyzag-desktop.exe (channel 3)."
} else {
    $configBytes  = (Get-Item $ConfigPath).Length
    $lines        = Get-Content $ConfigPath
    Write-Ok "desktop.conf exists ($configBytes bytes, $($lines.Count) lines)"

    # Examine path-typed keys. profile.shell is the famous one;
    # profile.agentd_socket and ZIGGYZAG_AGENTD_PATH-equivalent overrides
    # follow the same pattern.
    $pathKeys = @(
        'profile.shell',
        'profile.cwd'
    )

    $newLines = New-Object System.Collections.Generic.List[string]
    $changed  = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        $matched = $false

        if ($trimmed -and -not $trimmed.StartsWith('#')) {
            foreach ($key in $pathKeys) {
                $pattern = "^\s*$([regex]::Escape($key))\s*=\s*(.+?)\s*$"
                if ($trimmed -match $pattern) {
                    $value = $Matches[1].Trim().Trim('"').Trim("'")
                    if ($value -and -not (Test-Path -LiteralPath $value)) {
                        Write-Bad "${key} = ${value}  (path does not exist)"
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
                        $newLines.Add('# ZiggyZag doctor disabled stale path on ' + $timestamp + ' - next line was the original:')
                        $newLines.Add('# ' + $line)
                        $problemsFound++
                        $repairsMade++
                        $changed = $true
                        $matched = $true
                        break
                    } else {
                        Write-Ok "${key} = ${value}"
                        $matched = $true
                        break
                    }
                }
            }
        }

        if (-not $matched) { $newLines.Add($line) }
    }

    if ($changed -and -not $DryRun) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup    = "$ConfigPath.bak.$timestamp"
        Copy-Item -LiteralPath $ConfigPath -Destination $backup
        Write-Info "Backup written: $backup"
        Set-Content -LiteralPath $ConfigPath -Value $newLines -Encoding UTF8
        Write-Ok "desktop.conf repaired in place ($repairsMade lines disabled)"
    } elseif ($changed -and $DryRun) {
        Write-Warn ("DryRun - would have written backup and disabled " + $repairsMade + " stale line(s)")
    } elseif (-not $changed) {
        Write-Ok "No stale paths found"
    }
}

# --- 3. Check environment overrides ----------------------------------------

Write-Section "3. Environment overrides"

$envChecks = @{
    'ZIGGYZAG_SHELL_PATH'    = 'shell'
    'ZIGGYZAG_AGENTD_PATH'   = 'AgentD'
    'ZIGGYZAG_DESKTOP_CONFIG' = 'config'
    'ZIGGYZAG_THEME'         = 'theme'
}

$anyEnv = $false
foreach ($name in $envChecks.Keys) {
    $value = [Environment]::GetEnvironmentVariable($name, 'User')
    if (-not $value) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    if ($value) {
        $anyEnv = $true
        $role = $envChecks[$name]
        if ($role -in @('shell', 'AgentD', 'config')) {
            if (Test-Path -LiteralPath $value) {
                Write-Ok "$name = $value  (exists)"
            } else {
                Write-Bad "$name = $value  (file missing)"
                $problemsFound++
                Write-Warn ("Either point " + $name + " at a real file, or clear it: Remove-Item Env:\" + $name)
            }
        } elseif ($role -eq 'theme') {
            Write-Ok "$name = $value"
        }
    }
}
if (-not $anyEnv) { Write-Info "No ZiggyZag environment overrides set." }

# --- 4. Summary -------------------------------------------------------------

Write-Section "Summary"

if ($problemsFound -eq 0) {
    Write-Host "  ✓ ZiggyZag desktop is healthy." -ForegroundColor Green
} elseif ($repairsMade -gt 0 -and -not $DryRun) {
    Write-Host "  ✓ Found $problemsFound issue(s); repaired $repairsMade in desktop.conf." -ForegroundColor Green
    Write-Host "    Remaining issues need manual action (see warnings above)." -ForegroundColor Yellow
} else {
    Write-Host "  ! Found $problemsFound issue(s). See above for fixes." -ForegroundColor Yellow
}
Write-Host ""

# --- 5. Optional launch -----------------------------------------------------

if ($Launch) {
    $desktop = Join-Path $binDir 'ziggyzag-desktop.exe'
    if (Test-Path $desktop) {
        Write-Host "Launching $desktop..." -ForegroundColor Cyan
        Start-Process -FilePath $desktop -WorkingDirectory $RepoRoot
    } else {
        Write-Bad ("Cannot launch: " + $desktop + " missing. Run 'zig build' first.")
        exit 3
    }
}

if ($problemsFound -gt 0 -and $repairsMade -eq 0) { exit 1 } else { exit 0 }
