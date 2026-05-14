$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $env:TEMP "ziggyzag-smoke"
New-Item -ItemType Directory -Force $tmp | Out-Null

$config = Join-Path $tmp ".ziggyzagrc"
$meta = Join-Path $tmp "history.tsv"
$out = Join-Path $tmp "out.txt"

Remove-Item -Force $meta, $out -ErrorAction SilentlyContinue

@'
alias hi='echo hello'
abbr greet='echo expanded'
complete -c zzdemo -a 'alpha beta' -d 'demo subcommand'
prompt smart
export ZZSMOKE=ready
'@ | Set-Content -NoNewline -Encoding ASCII $config

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
echo hello | findstr hello
exit
'@ | & (Join-Path $root "zig-out\bin\ziggyzag.exe") > $out

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
if ($output -notmatch "hello") { throw "native pipeline smoke failed" }
if (!(Test-Path $meta)) { throw "history metadata file was not written" }

Write-Host "ZiggyZag smoke passed"
