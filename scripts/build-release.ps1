param(
    [string]$Version = "v0.1.0-alpha.1"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$zig = $env:ZIG_EXE
if (-not $zig) {
    $zigCommand = Get-Command zig -ErrorAction SilentlyContinue
    if ($zigCommand) {
        $zig = $zigCommand.Source
    }
}
if (-not $zig) {
    $wingetZig = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter zig.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($wingetZig) {
        $zig = $wingetZig
    }
}
if (-not $zig) {
    throw "No zig executable found. Set ZIG_EXE or add Zig 0.16.0 to PATH."
}

$targets = @(
    @{ Name = "windows-x86_64"; Target = "x86_64-windows"; Exe = ".exe" },
    @{ Name = "linux-x86_64"; Target = "x86_64-linux"; Exe = "" },
    @{ Name = "linux-aarch64"; Target = "aarch64-linux"; Exe = "" },
    @{ Name = "macos-x86_64"; Target = "x86_64-macos"; Exe = "" },
    @{ Name = "macos-aarch64"; Target = "aarch64-macos"; Exe = "" }
)

$dist = Join-Path $root "dist"
$releaseRoot = Join-Path $dist $Version
Remove-Item -Recurse -Force $releaseRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $releaseRoot | Out-Null

Write-Host "Using Zig: $zig"
& $zig version
if ($LASTEXITCODE -ne 0) { throw "zig version failed" }

foreach ($entry in $targets) {
    $prefix = Join-Path $releaseRoot $entry.Name
    Write-Host ""
    Write-Host "== Building $($entry.Name) =="
    & $zig build -Doptimize=ReleaseSafe "-Dtarget=$($entry.Target)" --prefix $prefix
    if ($LASTEXITCODE -ne 0) { throw "zig build failed for $($entry.Name)" }

    $package = Join-Path $releaseRoot "ZiggyZag-$Version-$($entry.Name).zip"
    Remove-Item -Force $package -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $prefix "*") -DestinationPath $package -Force
    Write-Host "Wrote $package"
}

Write-Host ""
Write-Host "Release artifacts:"
Get-ChildItem $releaseRoot -Filter *.zip | Select-Object Name, Length
