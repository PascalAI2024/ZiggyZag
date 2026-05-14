$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $env:TEMP "ziggyzag-smoke"
New-Item -ItemType Directory -Force $tmp | Out-Null

$config = Join-Path $tmp ".ziggyzagrc"
$meta = Join-Path $tmp "history.tsv"
$out = Join-Path $tmp "out.txt"
$sourceFile = Join-Path $tmp "source.zz"
$sourceShellPath = $sourceFile.Replace("\", "/")
$navDir = Join-Path $tmp "ziggyzag-smoke-nav"
$navShellPath = $navDir.Replace("\", "/")
$missingSourcePath = (Join-Path $tmp "missing-source.zz").Replace("\", "/")
$failFile = Join-Path $tmp "failed.txt"
$failShellPath = $failFile.Replace("\", "/")

Remove-Item -Force $meta, $out, $sourceFile, $failFile -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $navDir -ErrorAction SilentlyContinue

@'
alias hi='echo hello'
abbr greet='echo expanded'
complete -c zzdemo -a 'alpha beta' -d 'demo subcommand'
prompt smart
export ZZSMOKE=ready
'@ | Set-Content -NoNewline -Encoding ASCII $config

@'
alias sourced='echo sourced ok'
export SOURCED_VALUE=from-source
'@ | Set-Content -NoNewline -Encoding ASCII $sourceFile

$env:ZIGGYZAG_CONFIG = $config
$env:ZIGGYZAG_HISTORY_DB = $meta

@'
hi world
greet now
complete -p zzdemo
echo $ZZSMOKE
history --search greet
history --json
history --meta
history --meta --json
jobs --json
doctor
doctor --json
config check
inspect echo hello | findstr hello
about
about --json
which echo findstr missing-command
which --json echo
path --json
env ZZSMOKE
env --json
vars --json
timeit echo timed
repeat 2 echo repeated
source SOURCE_FILE_PLACEHOLDER
sourced
echo $SOURCED_VALUE
project
project --json
run --list
dirs
dirs --json
mkcd NAV_DIR_PLACEHOLDER
pwd
back
pwd
jump ziggyzag-smoke-nav
pwd
back
source MISSING_SOURCE_PLACEHOLDER 2> FAIL_FILE_PLACEHOLDER
history --failed
history --slow 0
history --cwd
history --stats
echo hello | findstr hello
exit
'@.Replace("SOURCE_FILE_PLACEHOLDER", $sourceShellPath).Replace("NAV_DIR_PLACEHOLDER", $navShellPath).Replace("MISSING_SOURCE_PLACEHOLDER", $missingSourcePath).Replace("FAIL_FILE_PLACEHOLDER", $failShellPath) | & (Join-Path $root "zig-out\bin\ziggyzag.exe") *> $out

$output = Get-Content $out -Raw
if ($output -notmatch "hello world") { throw "alias smoke failed" }
if ($output -notmatch "expanded now") { throw "abbreviation smoke failed" }
if ($output -notmatch "complete -c zzdemo -a alpha") { throw "completion smoke failed" }
if ($output -notmatch "ready") { throw "export smoke failed" }
if ($output -notmatch "history --search greet") { throw "history search smoke failed" }
if ($output -notmatch '"command":"history --json"') { throw "history json smoke failed" }
if ($output -notmatch '"prompt_mode"') { throw "doctor json smoke failed" }
if ($output -notmatch "ZiggyZag doctor") { throw "doctor smoke failed" }
if ($output -notmatch "ok ") { throw "config check smoke failed" }
if ($output -notmatch "pipeline: native simple pipeline") { throw "inspect smoke failed" }
if ($output -notmatch "ZiggyZag 0.1.0") { throw "about smoke failed" }
if ($output -notmatch '"name":"ZiggyZag"') { throw "about json smoke failed" }
if ($output -notmatch "shell builtin") { throw "which smoke failed" }
if ($output -notmatch '"kind":"builtin"') { throw "which json smoke failed" }
if ($output -notmatch '"path"') { throw "path json smoke failed" }
if ($output -notmatch "ready") { throw "env smoke failed" }
if ($output -notmatch '"name":"ZZSMOKE"') { throw "env json smoke failed" }
if ($output -notmatch "timeit: ") { throw "timeit smoke failed" }
if (($output | Select-String "repeated" -AllMatches).Matches.Count -lt 2) { throw "repeat smoke failed" }
if ($output -notmatch "sourced ok") { throw "source smoke failed" }
if ($output -notmatch "from-source") { throw "source export smoke failed" }
if ($output -notmatch "project: zig") { throw "project smoke failed" }
if ($output -notmatch '"kind":"zig"') { throw "project json smoke failed" }
if ($output -notmatch "tasks: build test run fmt") { throw "run list smoke failed" }
if ($output -notmatch '"current":true') { throw "dirs json smoke failed" }
if ($output -notmatch "ziggyzag-smoke-nav") { throw "directory navigation smoke failed" }
if ($output -notmatch "status=1") { throw "history failed smoke failed" }
if ($output -notmatch "history stats") { throw "history stats smoke failed" }
if ($output -notmatch "hello") { throw "native pipeline smoke failed" }
if (!(Test-Path $meta)) { throw "history metadata file was not written" }
if (!(Test-Path $failFile)) { throw "failed stderr redirect file was not written" }

Write-Host "ZiggyZag smoke passed"
