# ZiggyZag install script for Windows.
#
# Usage (PowerShell):
#   iwr -useb https://raw.githubusercontent.com/PascalAI2024/ZiggyZag/master/scripts/install.ps1 | iex
#
# Or, to install a specific version:
#   $env:ZZ_VERSION = 'v0.1.0-alpha.2'
#   iwr -useb https://raw.githubusercontent.com/PascalAI2024/ZiggyZag/master/scripts/install.ps1 | iex
#
# Environment variables:
#   ZZ_VERSION       Release tag to install (default: latest)
#   ZZ_INSTALL_DIR   Where to drop binaries (default: $env:LOCALAPPDATA\ZiggyZag\bin)

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$Repo       = 'PascalAI2024/ZiggyZag'
$InstallDir = if ($env:ZZ_INSTALL_DIR) { $env:ZZ_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'ZiggyZag\bin' }
$Version    = $env:ZZ_VERSION

function Write-Step($msg) { Write-Host "-> $msg" -ForegroundColor DarkGray }
function Write-Ok($msg)   { Write-Host "  ✓ $msg"   -ForegroundColor Green }
function Write-Err($msg)  { Write-Error "install.ps1: $msg" }

# --- Resolve version --------------------------------------------------------
if (-not $Version) {
    Write-Step 'resolving latest release...'
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/releases/latest" -MaximumRedirection 0 -ErrorAction SilentlyContinue
    } catch {
        $response = $_.Exception.Response
    }
    $location = $response.Headers.Location
    if (-not $location) { $location = $response.Headers['Location'] }
    if (-not $location) { Write-Err 'could not resolve latest release tag'; return }
    $Version = ($location -split '/tag/')[-1]
}

$Target       = 'windows-x86_64'
$Archive      = "ZiggyZag-$Version-$Target.zip"
$Checksums    = 'checksums.sha256'
$DownloadBase = "https://github.com/$Repo/releases/download/$Version"

Write-Host ''
Write-Host "Installing ZiggyZag $Version for $Target" -ForegroundColor White
Write-Host "  archive:    $Archive"
Write-Host "  install to: $InstallDir"
Write-Host ''

# --- Download and verify ----------------------------------------------------
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ziggyzag-install-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $TempRoot | Out-Null

try {
    $ArchivePath   = Join-Path $TempRoot $Archive
    $ChecksumPath  = Join-Path $TempRoot $Checksums
    $ExtractPath   = Join-Path $TempRoot 'extracted'

    Write-Step 'downloading archive...'
    Invoke-WebRequest -UseBasicParsing -Uri "$DownloadBase/$Archive" -OutFile $ArchivePath

    Write-Step 'downloading checksums...'
    Invoke-WebRequest -UseBasicParsing -Uri "$DownloadBase/$Checksums" -OutFile $ChecksumPath

    Write-Step 'verifying SHA256...'
    $line = Get-Content $ChecksumPath | Where-Object { $_ -match "  $([regex]::Escape($Archive))$" } | Select-Object -First 1
    if (-not $line) { Write-Err "no checksum entry for $Archive"; return }
    $Expected = ($line -split '\s+')[0].ToLowerInvariant()
    $Actual   = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash.ToLowerInvariant()
    if ($Expected -ne $Actual) {
        Write-Err "checksum mismatch (expected $Expected, got $Actual)"
        return
    }
    Write-Ok 'checksum matches'

    # --- Install --------------------------------------------------------------
    Write-Step 'extracting...'
    Expand-Archive -Path $ArchivePath -DestinationPath $ExtractPath -Force

    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

    $binDir = Join-Path $ExtractPath 'bin'
    if (Test-Path $binDir) {
        Get-ChildItem -Path $binDir -File | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $InstallDir -Force
        }
    } else {
        Get-ChildItem -Path $ExtractPath -Recurse -Filter 'ziggyzag*' -File | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $InstallDir -Force
        }
    }

    Write-Host ''
    Write-Host "✓ installed to $InstallDir" -ForegroundColor Green
    Write-Host ''

    # --- PATH hint ------------------------------------------------------------
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$InstallDir*") {
        Write-Host 'Next: add to your user PATH (run once):' -ForegroundColor White
        Write-Host ''
        Write-Host "  [Environment]::SetEnvironmentVariable('Path', `"`$env:Path;$InstallDir`", 'User')" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Then close and reopen your terminal so PATH refreshes.'
        Write-Host ''
    }

    Write-Host 'Try it:'
    Write-Host "  & '$InstallDir\ziggyzag.exe'"
    Write-Host ''
    Write-Host "Docs: https://github.com/$Repo"
}
finally {
    Remove-Item -Recurse -Force -Path $TempRoot -ErrorAction SilentlyContinue
}
