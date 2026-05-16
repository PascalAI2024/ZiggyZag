param(
    [string]$Version = "v0.1.0-alpha.1",
    [ValidateSet("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall")]
    [string]$Optimize = "ReleaseSafe",
    [switch]$DryRun,
    [switch]$KeepExpanded
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "Invalid release version '$Version'. Use letters, numbers, dots, underscores, and dashes only."
}

$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root "dist"
$releaseRoot = Join-Path $dist $Version
$manifestName = "release-manifest.json"
$checksumsName = "checksums.sha256"

function Write-Section {
    param([string]$Message)

    Write-Host ""
    Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Write-Item {
    param([string]$Message)

    Write-Host " - $Message"
}

function Assert-ReleaseRootSafe {
    $distFull = [IO.Path]::GetFullPath($dist)
    $releaseFull = [IO.Path]::GetFullPath($releaseRoot)
    $prefix = $distFull.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    if (-not $releaseFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside dist: $releaseFull"
    }
}

function Assert-ProjectFile {
    param([string]$Relative)

    $path = Join-Path $root $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required project file is missing: $Relative"
    }
}

function Resolve-Zig {
    foreach ($envName in @("ZIGGYZAG_ZIG_PATH", "ZIG_EXE")) {
        $configured = [Environment]::GetEnvironmentVariable($envName)
        if ($configured) {
            if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) {
                throw "$envName points to a Zig executable that does not exist: $configured"
            }

            return (Resolve-Path -LiteralPath $configured).Path
        }
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

function Assert-ZigWorks {
    param([string]$Zig)

    $versionOutput = & $Zig version
    if ($LASTEXITCODE -ne 0) {
        throw "zig version failed for $Zig"
    }

    $versionText = ($versionOutput | Select-Object -First 1).ToString()
    if ($versionText -ne "0.16.0") {
        Write-Warning "Expected Zig 0.16.0 for this alpha; found $versionText."
    }

    return $versionText
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
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName -replace "\\", "/"
            if ($name.StartsWith("/") -or $name -match '(^|/)\.\.(/|$)') {
                throw "Package $(Split-Path -Leaf $Package) contains an unsafe path: $name"
            }
        }

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

function New-RequiredPackageEntries {
    param([string]$Exe)

    return @(
        "README.md",
        "LICENSE"
    ) + (New-RequiredBinaries -Exe $Exe)
}

function Assert-ChecksumsFile {
    param(
        [string]$Path,
        [object[]]$Artifacts
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing checksums file: $Path"
    }

    $lines = @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim().Length -gt 0 })
    if ($lines.Count -ne $Artifacts.Count) {
        throw "Checksum file should contain $($Artifacts.Count) entries, found $($lines.Count)."
    }

    foreach ($artifact in $Artifacts) {
        $expected = "$($artifact.sha256)  $($artifact.package)"
        if ($lines -notcontains $expected) {
            throw "Checksum file is missing expected entry: $expected"
        }

        $packagePath = Join-Path $releaseRoot $artifact.package
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagePath).Hash.ToLowerInvariant()
        if ($actual -ne $artifact.sha256) {
            throw "Checksum mismatch for $($artifact.package): manifest=$($artifact.sha256) actual=$actual"
        }
    }
}

function Assert-ManifestFile {
    param(
        [string]$Path,
        [object[]]$Artifacts
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing release manifest: $Path"
    }

    $manifest = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    if ($manifest.schema -ne "ziggyzag.release.v1") {
        throw "Unexpected manifest schema: $($manifest.schema)"
    }
    if ($manifest.version -ne $Version) {
        throw "Manifest version mismatch: $($manifest.version)"
    }
    if ($manifest.optimize -ne $Optimize) {
        throw "Manifest optimize mismatch: $($manifest.optimize)"
    }
    if (-not $manifest.artifacts -or $manifest.artifacts.Count -ne $Artifacts.Count) {
        throw "Manifest should contain $($Artifacts.Count) artifacts."
    }

    foreach ($artifact in $Artifacts) {
        $match = @($manifest.artifacts | Where-Object { $_.target -eq $artifact.target -and $_.package -eq $artifact.package })
        if ($match.Count -ne 1) {
            throw "Manifest is missing artifact $($artifact.target)."
        }

        if ($match[0].sha256 -ne $artifact.sha256) {
            throw "Manifest hash mismatch for $($artifact.package)."
        }
        if ($match[0].bytes -ne $artifact.bytes) {
            throw "Manifest size mismatch for $($artifact.package)."
        }
        foreach ($entry in $artifact.required) {
            if (@($match[0].required) -notcontains $entry) {
                throw "Manifest required entries for $($artifact.package) are missing $entry."
            }
        }
    }
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
    Assert-ReleaseRootSafe
    Assert-ProjectFile -Relative "README.md"
    Assert-ProjectFile -Relative "LICENSE"

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
            $zigVersion = Assert-ZigWorks -Zig $zig
            Write-Item "Zig version: $zigVersion"
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
            $expectedPackageNames = @($targets | ForEach-Object { "ZiggyZag-$Version-$($_.Name).zip" })
            foreach ($package in $existingPackages) {
                if ($expectedPackageNames -notcontains $package.Name) {
                    throw "Existing release directory contains unexpected package: $($package.Name)"
                }
            }

            $existingArtifacts = @()
            foreach ($entry in $targets) {
                $package = Join-Path $releaseRoot "ZiggyZag-$Version-$($entry.Name).zip"
                if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
                    throw "Existing release directory is missing expected package: $(Split-Path -Leaf $package)"
                }

                $required = New-RequiredPackageEntries -Exe $entry.Exe
                Assert-ZipContains -Package $package -Required $required
                $existingArtifacts += [pscustomobject]@{
                    target = $entry.Name
                    triple = $entry.Target
                    package = Split-Path -Leaf $package
                    bytes = (Get-Item -LiteralPath $package).Length
                    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $package).Hash.ToLowerInvariant()
                    required = $required
                }
                Write-Item "Validated $(Split-Path -Leaf $package)"
            }

            if ($existingArtifacts.Count -gt 0) {
                $checksums = Join-Path $releaseRoot $checksumsName
                $manifest = Join-Path $releaseRoot $manifestName
                Assert-ChecksumsFile -Path $checksums -Artifacts $existingArtifacts
                Assert-ManifestFile -Path $manifest -Artifacts $existingArtifacts
                Write-Item "Validated $checksumsName and $manifestName"
            }
        }

        return
    }

    Write-Section "Cleaning output"
    Write-Item "Removing existing release directory if present"
    Remove-Item -Recurse -Force $releaseRoot -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $releaseRoot | Out-Null

    $artifacts = @()
    foreach ($entry in $targets) {
        $prefix = Join-Path $releaseRoot $entry.Name
        $package = Join-Path $releaseRoot "ZiggyZag-$Version-$($entry.Name).zip"
        $required = New-RequiredBinaries -Exe $entry.Exe
        $requiredPackageEntries = New-RequiredPackageEntries -Exe $entry.Exe

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
        Assert-ZipContains -Package $package -Required $requiredPackageEntries

        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $package).Hash.ToLowerInvariant()
        $bytes = (Get-Item -LiteralPath $package).Length
        $artifacts += [pscustomobject]@{
            target = $entry.Name
            triple = $entry.Target
            package = Split-Path -Leaf $package
            bytes = $bytes
            sha256 = $hash
            required = $requiredPackageEntries
        }
        Write-Item "Wrote $(Split-Path -Leaf $package) ($bytes bytes)"
        Write-Item "SHA256 $hash"
    }

    $checksums = Join-Path $releaseRoot $checksumsName
    $artifacts |
        ForEach-Object { "$($_.sha256)  $($_.package)" } |
        Set-Content -LiteralPath $checksums -Encoding ascii

    $manifest = Join-Path $releaseRoot $manifestName
    [pscustomobject]@{
        schema = "ziggyzag.release.v1"
        version = $Version
        optimize = $Optimize
        generated_utc = (Get-Date).ToUniversalTime().ToString("o")
        artifacts = $artifacts
    } |
        ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath $manifest -Encoding utf8

    Assert-ChecksumsFile -Path $checksums -Artifacts $artifacts
    Assert-ManifestFile -Path $manifest -Artifacts $artifacts

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
