param(
    [string]$Version = "v0.1.0-alpha.1",
    [string]$ReleaseRoot = "",
    [switch]$SkipWindowsRun
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
if (-not $ReleaseRoot) {
    $ReleaseRoot = Join-Path $Root "dist\$Version"
}

if (-not (Test-Path $ReleaseRoot)) {
    throw "Release artifact directory not found: $ReleaseRoot"
}

$TempRoot = Join-Path $env:TEMP "ziggyzag-release-qa-$Version"
Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $TempRoot | Out-Null

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

function Assert-File {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Missing expected file: $Path"
    }
}

$targets = @(
    @{ Name = "windows-x86_64"; Exe = ".exe"; Header = "4d5a"; HeaderBytes = 2 },
    @{ Name = "linux-x86_64"; Exe = ""; Header = "7f454c46"; HeaderBytes = 4 },
    @{ Name = "linux-aarch64"; Exe = ""; Header = "7f454c46"; HeaderBytes = 4 },
    @{ Name = "macos-x86_64"; Exe = ""; Header = "mach-o"; HeaderBytes = 4 },
    @{ Name = "macos-aarch64"; Exe = ""; Header = "mach-o"; HeaderBytes = 4 }
)

foreach ($target in $targets) {
    $zip = Join-Path $ReleaseRoot "ZiggyZag-$Version-$($target.Name).zip"
    Assert-File $zip

    $dest = Join-Path $TempRoot $target.Name
    Expand-Archive -Path $zip -DestinationPath $dest -Force

    $bin = Join-Path $dest "bin"
    Assert-File $bin

    foreach ($binary in @("ziggyzag", "ziggyzag-agentd", "ziggyzag-desktop")) {
        Assert-File (Join-Path $bin "$binary$($target.Exe)")
    }

    $mainBinary = Join-Path $bin "ziggyzag$($target.Exe)"
    $prefix = Read-HexPrefix $mainBinary $target.HeaderBytes
    if ($target.Header -eq "mach-o") {
        if (@("cffaedfe", "feedfacf", "cafebabe", "bebafeca") -notcontains $prefix) {
            throw "macOS artifact is not Mach-O/fat Mach-O: $mainBinary prefix=$prefix"
        }
    } elseif ($prefix -ne $target.Header) {
        throw "Unexpected binary header for $mainBinary prefix=$prefix"
    }

    Write-Host "[PASS] $($target.Name) zip expands, contains expected binaries, and has the expected binary header."
}

if (-not $SkipWindowsRun) {
    $windowsBin = Join-Path $TempRoot "windows-x86_64\bin"
    $shell = Join-Path $windowsBin "ziggyzag.exe"
    $agentd = Join-Path $windowsBin "ziggyzag-agentd.exe"
    $desktop = Join-Path $windowsBin "ziggyzag-desktop.exe"

    Assert-File $shell
    Assert-File $agentd
    Assert-File $desktop

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
        throw "Extracted Windows desktop did not close cleanly and was force-stopped."
    }
    if (-not $started -or -not $closed -or $process.ExitCode -ne 0) {
        throw "Extracted Windows desktop smoke failed: started=$started closed=$closed exit=$($process.ExitCode)."
    }

    Write-Host "[PASS] extracted Windows desktop launch-close smoke."
}

Write-Host "Archive QA temp: $TempRoot"
