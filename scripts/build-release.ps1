param(
    [string]$Version = "v0.1.0-alpha.1",
    [ValidateSet("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall")]
    [string]$Optimize = "ReleaseSafe",
    [switch]$DryRun,
    [switch]$KeepExpanded
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root "dist"
$releaseRoot = Join-Path $dist $Version

function Write-Section {
    param([string]$Message)

    Write-Host ""
    Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Write-Item {
    param([string]$Message)

    Write-Host " - $Message"
}

function Resolve-Zig {
    if ($env:ZIG_EXE -and (Test-Path -LiteralPath $env:ZIG_EXE -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $env:ZIG_EXE).Path
    }

    $zigCommand = Get-Command zig -ErrorAction SilentlyContinue
    if ($zigCommand) {
        return $zigCommand.Source
    }

    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $wingetRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
        if (Test-Path -LiteralPath $wingetRoot) {
            $candidates += Get-ChildItem -Path $wingetRoot -Recurse -Filter zig.exe -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName
        }

        $scoopZig = Join-Path $env:LOCALAPPDATA "Programs\zig\zig.exe"
        $candidates += $scoopZig
    }
    if ($env:ChocolateyInstall) {
        $candidates += Join-Path $env:ChocolateyInstall "bin\zig.exe"
    }
    $candidates += "C:\Program Files\Zig\zig.exe"

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "No zig executable found. Set ZIG_EXE or add Zig 0.16.0 to PATH."
}

function Convert-ReleasePath {
    param([string]$Path)

    return $Path -replace "/", [IO.Path]::DirectorySeparatorChar
}

function Assert-BinariesPresent {
    param(
        [string]$Prefix,
        [string[]]$Required
    )

    foreach ($relative in $Required) {
        $path = Join-Path $Prefix (Convert-ReleasePath $relative)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing expected binary in build prefix: $relative"
        }

        $item = Get-Item -LiteralPath $path
        if ($item.Length -le 0) {
            throw "Expected binary is empty in build prefix: $relative"
        }
    }
}

function Assert-ZipContains {
    param(
        [string]$Package,
        [string[]]$Required
    )

    if (-not (Test-Path -LiteralPath $Package -PathType Leaf)) {
        throw "Package was not created: $Package"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Package)
    try {
        foreach ($relative in $Required) {
            $match = $archive.Entries |
                Where-Object { ($_.FullName -replace "\\", "/") -eq $relative } |
                Select-Object -First 1

            if (-not $match) {
                throw "Package $(Split-Path -Leaf $Package) is missing $relative"
            }
            if ($match.Length -le 0) {
                throw "Package $(Split-Path -Leaf $Package) contains an empty $relative"
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function New-RequiredBinaries {
    param([string]$Exe)

    return @(
        "bin/ziggyzag$Exe",
        "bin/ziggyzag-desktop$Exe",
        "bin/ziggyzag-agentd$Exe"
    )
}

$targets = @(
    @{ Name = "windows-x86_64"; Target = "x86_64-windows"; Exe = ".exe" },
    @{ Name = "linux-x86_64"; Target = "x86_64-linux"; Exe = "" },
    @{ Name = "linux-aarch64"; Target = "aarch64-linux"; Exe = "" },
    @{ Name = "macos-x86_64"; Target = "x86_64-macos"; Exe = "" },
    @{ Name = "macos-aarch64"; Target = "aarch64-macos"; Exe = "" }
)

Push-Location $root
try {
    Write-Section "ZiggyZag release packaging"
    Write-Item "Version: $Version"
    Write-Item "Optimize: $Optimize"
    Write-Item "Output: $releaseRoot"

    if ($DryRun) {
        Write-Item "Dry run: no files will be built, removed, or written"
    }

    $zig = $null
    try {
        $zig = Resolve-Zig
        Write-Item "Zig: $zig"
        if (-not $DryRun) {
            & $zig version
            if ($LASTEXITCODE -ne 0) { throw "zig version failed" }
        }
    } catch {
        if ($DryRun) {
            Write-Warning $_.Exception.Message
        } else {
            throw
        }
    }

    Write-Section "Target matrix"
    foreach ($entry in $targets) {
        $required = New-RequiredBinaries -Exe $entry.Exe
        Write-Item "$($entry.Name) -> $($entry.Target) [$($required -join ', ')]"
    }

    if ($DryRun) {
        Write-Section "Existing package validation"
        $existingPackages = @()
        if (Test-Path -LiteralPath $releaseRoot) {
            $existingPackages = @(Get-ChildItem -LiteralPath $releaseRoot -Filter "*.zip" -File)
        }

        if ($existingPackages.Count -eq 0) {
            Write-Item "No existing packages found to validate"
        } else {
            foreach ($entry in $targets) {
                $package = Join-Path $releaseRoot "ZiggyZag-$Version-$($entry.Name).zip"
                if (Test-Path -LiteralPath $package -PathType Leaf) {
                    Assert-ZipContains -Package $package -Required (New-RequiredBinaries -Exe $entry.Exe)
                    Write-Item "Validated $(Split-Path -Leaf $package)"
                }
            }
        }

        return
    }

    Remove-Item -Recurse -Force $releaseRoot -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $releaseRoot | Out-Null

    $artifacts = @()
    foreach ($entry in $targets) {
        $prefix = Join-Path $releaseRoot $entry.Name
        $package = Join-Path $releaseRoot "ZiggyZag-$Version-$($entry.Name).zip"
        $required = New-RequiredBinaries -Exe $entry.Exe

        Write-Section "Building $($entry.Name)"
        Write-Item "Target: $($entry.Target)"
        Write-Item "Prefix: $prefix"
        & $zig build "-Doptimize=$Optimize" "-Dtarget=$($entry.Target)" --prefix $prefix
        if ($LASTEXITCODE -ne 0) { throw "zig build failed for $($entry.Name)" }

        Assert-BinariesPresent -Prefix $prefix -Required $required
        Write-Item "Verified build output: $($required -join ', ')"

        Copy-Item -LiteralPath (Join-Path $root "README.md") -Destination (Join-Path $prefix "README.md") -Force
        Copy-Item -LiteralPath (Join-Path $root "LICENSE") -Destination (Join-Path $prefix "LICENSE") -Force

        Remove-Item -Force $package -ErrorAction SilentlyContinue
        Compress-Archive -Path (Join-Path $prefix "*") -DestinationPath $package -Force
        Assert-ZipContains -Package $package -Required $required

        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $package).Hash.ToLowerInvariant()
        $bytes = (Get-Item -LiteralPath $package).Length
        $artifacts += [pscustomobject]@{
            target = $entry.Name
            triple = $entry.Target
            package = Split-Path -Leaf $package
            bytes = $bytes
            sha256 = $hash
            required = $required
        }
        Write-Item "Wrote $(Split-Path -Leaf $package) ($bytes bytes)"
        Write-Item "SHA256 $hash"
    }

    $checksums = Join-Path $releaseRoot "checksums.sha256"
    $artifacts |
        ForEach-Object { "$($_.sha256)  $($_.package)" } |
        Set-Content -LiteralPath $checksums -Encoding ascii

    $manifest = Join-Path $releaseRoot "release-manifest.json"
    $artifacts |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $manifest -Encoding utf8

    if (-not $KeepExpanded) {
        foreach ($entry in $targets) {
            Remove-Item -Recurse -Force (Join-Path $releaseRoot $entry.Name) -ErrorAction SilentlyContinue
        }
    }

    Write-Section "Release artifacts ready"
    $artifacts |
        Select-Object target, package, bytes, sha256 |
        Format-Table -AutoSize
    Write-Item "Checksums: $checksums"
    Write-Item "Manifest: $manifest"
} finally {
    Pop-Location
}
