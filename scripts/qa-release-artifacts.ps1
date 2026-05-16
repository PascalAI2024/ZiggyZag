param(
    [string]$Version = "v0.1.0-alpha.1",
    [string]$ReleaseRoot = "",
    [switch]$SkipWindowsRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
if (-not $ReleaseRoot) {
    $ReleaseRoot = Join-Path $Root "dist\$Version"
}

if (-not (Test-Path -LiteralPath $ReleaseRoot -PathType Container)) {
    throw "Release artifact directory not found: $ReleaseRoot"
}

$SafeVersion = $Version -replace '[^A-Za-z0-9._-]', '_'
$TempRoot = Join-Path $env:TEMP ("ziggyzag release qa {0} {1}" -f $SafeVersion, [Guid]::NewGuid().ToString("N"))
Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $TempRoot | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-Section {
    param([string]$Message)

    Write-Host ""
    Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Normalize-ZipPath {
    param([string]$Path)

    return $Path -replace "\\", "/"
}

function Read-HexPrefix {
    param(
        [string]$Path,
        [int]$Count
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt $Count) {
        throw "File is too short to inspect: $Path"
    }

    return (($bytes[0..($Count - 1)] | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Assert-Path {
    param(
        [string]$Path,
        [ValidateSet("Any", "Leaf", "Container")]
        [string]$Type = "Any"
    )

    if ($Type -eq "Leaf") {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Missing expected file: $Path"
        }
    } elseif ($Type -eq "Container") {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "Missing expected directory: $Path"
        }
    } elseif (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing expected path: $Path"
    }
}

function New-RequiredEntries {
    param([string]$Exe)

    return @(
        "README.md",
        "LICENSE",
        "ZiggyZag$Exe",
        "bin/ziggyzag-launcher$Exe",
        "bin/ziggyzag$Exe",
        "bin/ziggyzag-agentd$Exe",
        "bin/ziggyzag-desktop$Exe"
    )
}

function Assert-ZipEntries {
    param(
        [string]$Zip,
        [string[]]$Required
    )

    Assert-Path -Path $Zip -Type Leaf
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entries = @($archive.Entries | ForEach-Object { Normalize-ZipPath $_.FullName })
        foreach ($entry in $entries) {
            if ($entry.StartsWith("/") -or $entry -match '(^|/)\.\.(/|$)') {
                throw "Zip contains an unsafe path: $(Split-Path -Leaf $Zip) -> $entry"
            }
        }

        foreach ($relative in $Required) {
            $match = @($archive.Entries | Where-Object { (Normalize-ZipPath $_.FullName) -eq $relative })
            if ($match.Count -ne 1) {
                throw "Zip $(Split-Path -Leaf $Zip) should contain exactly one $relative, found $($match.Count)."
            }
            if ($match[0].Length -le 0) {
                throw "Zip $(Split-Path -Leaf $Zip) contains an empty $relative."
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Assert-BinaryHeader {
    param(
        [string]$Path,
        [string]$Kind,
        [int]$HeaderBytes
    )

    $prefix = Read-HexPrefix $Path $HeaderBytes
    if ($Kind -eq "mach-o") {
        if (@("cffaedfe", "feedfacf", "cafebabe", "bebafeca") -notcontains $prefix) {
            throw "macOS artifact is not Mach-O/fat Mach-O: $Path prefix=$prefix"
        }
    } elseif ($prefix -ne $Kind) {
        throw "Unexpected binary header for $Path prefix=$prefix"
    }
}

function Read-Checksums {
    param([object[]]$Targets)

    $path = Join-Path $ReleaseRoot "checksums.sha256"
    Assert-Path -Path $path -Type Leaf

    $records = @{}
    $lines = @(Get-Content -LiteralPath $path | Where-Object { $_.Trim().Length -gt 0 })
    if ($lines.Count -ne $Targets.Count) {
        throw "checksums.sha256 should contain $($Targets.Count) lines, found $($lines.Count)."
    }

    foreach ($line in $lines) {
        if ($line -notmatch '^([a-fA-F0-9]{64})\s{2,}(.+\.zip)$') {
            throw "Malformed checksum line: $line"
        }

        $hash = $Matches[1].ToLowerInvariant()
        $package = $Matches[2]
        $packagePath = Join-Path $ReleaseRoot $package
        Assert-Path -Path $packagePath -Type Leaf

        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagePath).Hash.ToLowerInvariant()
        if ($actual -ne $hash) {
            throw "Checksum mismatch for $package`: listed=$hash actual=$actual"
        }
        $records[$package] = $hash
    }

    return $records
}

function Assert-Manifest {
    param(
        [object[]]$Targets,
        [hashtable]$Checksums
    )

    $path = Join-Path $ReleaseRoot "release-manifest.json"
    Assert-Path -Path $path -Type Leaf
    $manifest = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json

    if ($manifest.schema -ne "ziggyzag.release.v1") {
        throw "Unexpected manifest schema: $($manifest.schema)"
    }
    if ($manifest.version -ne $Version) {
        throw "Manifest version mismatch: $($manifest.version)"
    }
    if (-not $manifest.optimize) {
        throw "Manifest is missing optimize."
    }
    if (-not $manifest.generated_utc) {
        throw "Manifest is missing generated_utc."
    }

    $artifacts = @($manifest.artifacts)
    if ($artifacts.Count -ne $Targets.Count) {
        throw "Manifest should contain $($Targets.Count) artifacts, found $($artifacts.Count)."
    }

    foreach ($target in $Targets) {
        $package = "ZiggyZag-$Version-$($target.Name).zip"
        $artifact = @($artifacts | Where-Object { $_.target -eq $target.Name -and $_.package -eq $package })
        if ($artifact.Count -ne 1) {
            throw "Manifest is missing target $($target.Name)."
        }

        if (-not $Checksums.ContainsKey($package)) {
            throw "checksums.sha256 is missing $package."
        }
        if ($artifact[0].sha256 -ne $Checksums[$package]) {
            throw "Manifest checksum mismatch for $package."
        }

        $packagePath = Join-Path $ReleaseRoot $package
        $bytes = (Get-Item -LiteralPath $packagePath).Length
        if ($artifact[0].bytes -ne $bytes) {
            throw "Manifest size mismatch for $package."
        }

        $required = @(New-RequiredEntries -Exe $target.Exe)
        $manifestRequired = @($artifact[0].required)
        foreach ($entry in $required) {
            if ($manifestRequired -notcontains $entry) {
                throw "Manifest required entries for $package are missing $entry."
            }
        }
    }
}

$targets = @(
    @{ Name = "windows-x86_64"; Exe = ".exe"; Header = "4d5a"; HeaderBytes = 2 },
    @{ Name = "linux-x86_64"; Exe = ""; Header = "7f454c46"; HeaderBytes = 4 },
    @{ Name = "linux-aarch64"; Exe = ""; Header = "7f454c46"; HeaderBytes = 4 },
    @{ Name = "macos-x86_64"; Exe = ""; Header = "mach-o"; HeaderBytes = 4 },
    @{ Name = "macos-aarch64"; Exe = ""; Header = "mach-o"; HeaderBytes = 4 }
)

Write-Section "Release metadata"
$expectedPackages = @($targets | ForEach-Object { "ZiggyZag-$Version-$($_.Name).zip" })
$actualPackages = @(Get-ChildItem -LiteralPath $ReleaseRoot -Filter "*.zip" -File | Select-Object -ExpandProperty Name)
foreach ($expected in $expectedPackages) {
    if ($actualPackages -notcontains $expected) {
        throw "Missing expected package: $expected"
    }
}
foreach ($actual in $actualPackages) {
    if ($expectedPackages -notcontains $actual) {
        throw "Unexpected extra package in release directory: $actual"
    }
}

$checksums = Read-Checksums -Targets $targets
Assert-Manifest -Targets $targets -Checksums $checksums
Write-Host "[PASS] checksums.sha256 and release-manifest.json are internally consistent."

Write-Section "Zip contents"
foreach ($target in $targets) {
    $zip = Join-Path $ReleaseRoot "ZiggyZag-$Version-$($target.Name).zip"
    $required = New-RequiredEntries -Exe $target.Exe
    Assert-ZipEntries -Zip $zip -Required $required

    $dest = Join-Path $TempRoot $target.Name
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force

    Assert-Path -Path (Join-Path $dest "README.md") -Type Leaf
    Assert-Path -Path (Join-Path $dest "LICENSE") -Type Leaf
    $launcher = Join-Path $dest "ZiggyZag$($target.Exe)"
    Assert-Path -Path $launcher -Type Leaf
    Assert-BinaryHeader -Path $launcher -Kind $target.Header -HeaderBytes $target.HeaderBytes
    $bin = Join-Path $dest "bin"
    Assert-Path -Path $bin -Type Container

    foreach ($binary in @("ziggyzag-launcher", "ziggyzag", "ziggyzag-agentd", "ziggyzag-desktop")) {
        $binaryPath = Join-Path $bin "$binary$($target.Exe)"
        Assert-Path -Path $binaryPath -Type Leaf
        Assert-BinaryHeader -Path $binaryPath -Kind $target.Header -HeaderBytes $target.HeaderBytes
    }

    Write-Host "[PASS] $($target.Name) zip expands, contains docs and binaries, and has expected binary headers."
}

if (-not $SkipWindowsRun) {
    Write-Section "Extracted Windows runtime smoke"
    $windowsBin = Join-Path $TempRoot "windows-x86_64\bin"
    $launcher = Join-Path $TempRoot "windows-x86_64\ZiggyZag.exe"
    $shell = Join-Path $windowsBin "ziggyzag.exe"
    $agentd = Join-Path $windowsBin "ziggyzag-agentd.exe"
    $desktop = Join-Path $windowsBin "ziggyzag-desktop.exe"

    Assert-Path -Path $launcher -Type Leaf
    Assert-Path -Path $shell -Type Leaf
    Assert-Path -Path $agentd -Type Leaf
    Assert-Path -Path $desktop -Type Leaf

    $shellOutput = "help`nexit`n" | & $shell
    if ($LASTEXITCODE -ne 0) {
        throw "Extracted Windows shell smoke failed with exit code $LASTEXITCODE."
    }
    if (($shellOutput -join "`n") -notmatch "ZiggyZag shell") {
        throw "Extracted Windows shell smoke did not print help output."
    }
    Write-Host "[PASS] extracted Windows shell smoke."

    $agentOutput = & $agentd --describe-tools
    if ($LASTEXITCODE -ne 0) {
        throw "Extracted Windows AgentD describe-tools failed with exit code $LASTEXITCODE."
    }
    if (($agentOutput -join "`n") -notmatch "terminal.write") {
        throw "Extracted Windows AgentD output did not include terminal.write."
    }
    Write-Host "[PASS] extracted Windows AgentD describe-tools."

    $launcherProcess = Start-Process -FilePath $launcher -WorkingDirectory (Split-Path -Parent $launcher) -PassThru -WindowStyle Normal
    Start-Sleep -Seconds 2
    $launcherProcess.Refresh()
    if ($launcherProcess.HasExited) {
        throw "Top-level Windows launcher exited before the smoke test could interact with it. Exit code: $($launcherProcess.ExitCode)."
    }

    $launcherClosed = $launcherProcess.CloseMainWindow()
    Start-Sleep -Seconds 2
    $launcherProcess.Refresh()
    if (-not $launcherProcess.HasExited) {
        Stop-Process -Id $launcherProcess.Id -Force
        throw "Top-level Windows launcher did not close cleanly and was force-stopped."
    }
    if (-not $launcherClosed -or $launcherProcess.ExitCode -ne 0) {
        throw "Top-level Windows launcher failed: closed=$launcherClosed exit=$($launcherProcess.ExitCode)."
    }
    Write-Host "[PASS] extracted Windows top-level launcher opens and closes the desktop host."

    $process = Start-Process -FilePath $desktop -WorkingDirectory $windowsBin -PassThru -WindowStyle Normal
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
        throw "Extracted Windows desktop did not close cleanly and was force-stopped."
    }
    if (-not $started -or -not $closed -or $process.ExitCode -ne 0) {
        throw "Extracted Windows desktop smoke failed: started=$started closed=$closed exit=$($process.ExitCode)."
    }

    Write-Host "[PASS] extracted Windows desktop launch-close smoke."
}

Write-Host "Archive QA temp: $TempRoot"
