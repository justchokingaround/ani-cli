# ani-cli watch party, friend side (Windows 10/11, no admin):
#   powershell -ep bypass -c "$r='<room>';irm <gist>/party.ps1|iex"
# Downloads portable mpv + Syncplay into %LOCALAPPDATA%\ani-party (once), then joins the room.
# Nothing to configure: the host's playlist carries the stream headers, party.lua applies them.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is 10x slower with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $r) { $r = Read-Host 'Room name' }
if (-not $n) { $n = $env:USERNAME }
if ($n.Length -gt 16) { $n = $n.Substring(0, 16) }
$server = if ($env:ANI_PARTY_SERVER) { $env:ANI_PARTY_SERVER } else { 'syncplay.pl:8999' }
$gist = if ($env:ANI_PARTY_GIST) { $env:ANI_PARTY_GIST } else { 'https://gist.githubusercontent.com/GIST_USER/GIST_ID/raw' }
$d = Join-Path $env:LOCALAPPDATA 'ani-party'
New-Item -ItemType Directory -Force -Path $d | Out-Null

function Get-Portable($repo, $pattern, $dest, $exe) {
    $found = Get-ChildItem -Path $dest -Recurse -Filter $exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    Write-Host "Downloading $exe ..." -ForegroundColor Magenta
    $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'ani-party' }
    $asset = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $asset) { throw "no $pattern in $repo" }
    $zip = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath $dest -Force
    Remove-Item $zip
    (Get-ChildItem -Path $dest -Recurse -Filter $exe | Select-Object -First 1).FullName
}

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
$mpv = Get-Portable 'mpv-player/mpv' "^mpv-v[0-9.]+-$arch-pc-windows-msvc\.zip$" (Join-Path $d 'mpv') 'mpv.exe'
# SyncplayConsole.exe: the plain Syncplay.exe opens its settings dialog first when it gets no file
$sp = Get-Portable 'Syncplay/syncplay' '_Portable\.zip$' (Join-Path $d 'syncplay') 'SyncplayConsole.exe'

$lua = Join-Path $d 'party.lua'
try { Invoke-WebRequest "$gist/party.lua" -OutFile $lua -UseBasicParsing } catch { if (-not (Test-Path $lua)) { throw } }

# private config: Syncplay reads %APPDATA%\syncplay.ini, so point APPDATA at our folder for
# this launch only (mpv then also starts with a clean config); also drop it next to the exe
$cfg = Join-Path $d 'cfg'
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
$host_, $port = $server.Split(':')
$ini = @"
[server_data]
host = $host_
port = $port
password =
[client_settings]
name = $n
room = $r
playerPath = $mpv
forceGuiPrompt = False
sharedPlaylistEnabled = True
onlySwitchToTrustedDomains = False
loopAtEndOfPlaylist = False
pauseOnLeave = True
unpauseAction = Always
filenamePrivacyMode = SendHashed
[general]
checkForUpdatesAutomatically = False
"@
[IO.File]::WriteAllText((Join-Path $cfg 'syncplay.ini'), $ini)
[IO.File]::WriteAllText((Join-Path (Split-Path $sp) 'syncplay.ini'), $ini)

$env:APPDATA = $cfg
Write-Host "Joining room $r as $n. Chat: press Enter in the video window. Subtitle timing: z / Z." -ForegroundColor Magenta
Start-Process -FilePath $sp -ArgumentList "--no-store -- `"--scripts-append=$lua`""
