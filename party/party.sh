#!/bin/sh
# ani-cli watch party, friend side (macOS / Linux):
#   curl -fsSL <gist>/party.sh | sh -s <room> [name]
# Installs mpv + Syncplay if missing (macOS: into ~/Applications, no admin), then joins the room.
# Nothing to configure: the host's playlist carries the stream headers, party.lua applies them.
set -eu

room="${1:?usage: party.sh <room> [name]}"
name="${2:-$(id -un | cut -c 1-16)}"
server="${ANI_PARTY_SERVER:-syncplay.pl:8999}"
gist="${ANI_PARTY_GIST:-https://gist.githubusercontent.com/GIST_USER/GIST_ID/raw}"

say() { printf '\033[1;35m%s\033[0m\n' "$*"; }
die() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

# $1 = repo, $2 = grep -E pattern for the asset name
gh_asset() {
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" |
        grep -o '"browser_download_url": *"[^"]*"' | cut -d '"' -f 4 | grep -E "$2" | head -n 1
}

case "$(uname -s)" in
    Darwin)
        dir="$HOME/Library/Application Support/ani-party"
        apps="$HOME/Applications"
        mkdir -p "$dir" "$apps"
        mpv=""
        for p in "$(command -v mpv || true)" /Applications/mpv.app/Contents/MacOS/mpv "$apps/mpv.app/Contents/MacOS/mpv" /opt/homebrew/bin/mpv /usr/local/bin/mpv; do
            [ -n "$p" ] && [ -x "$p" ] && mpv="$p" && break
        done
        if [ -z "$mpv" ]; then
            say "Installing mpv..."
            arch=arm
            [ "$(uname -m)" = "x86_64" ] && arch=intel
            os=$(sw_vers -productVersion | cut -d . -f 1)
            # newest official build whose macOS version is <= this one
            url=$(curl -fsSL https://api.github.com/repos/mpv-player/mpv/releases/latest |
                grep -o '"browser_download_url": *"[^"]*macos-[0-9]*-'"$arch"'\.zip"' | cut -d '"' -f 4 |
                awk -v os="$os" '{ v = $0; sub(/.*macos-/, "", v); sub(/-.*/, "", v); if (v + 0 <= os + 0 && v + 0 > best) { best = v + 0; u = $0 } } END { print u }')
            if [ -n "$url" ]; then
                tmp=$(mktemp -d)
                curl -fL# "$url" -o "$tmp/mpv.zip"
                (cd "$tmp" && unzip -q mpv.zip)
                # the zip may wrap the app in a tarball
                for t in "$tmp"/*.tar.gz "$tmp"/*.tar; do [ -f "$t" ] && tar -xf "$t" -C "$tmp"; done
                app=$(find "$tmp" -maxdepth 3 -name 'mpv.app' -type d | head -n 1)
                [ -n "$app" ] || die "mpv download had no mpv.app"
                rm -rf "$apps/mpv.app" && cp -R "$app" "$apps/"
                rm -rf "$tmp"
                mpv="$apps/mpv.app/Contents/MacOS/mpv"
            elif command -v brew >/dev/null; then
                brew install mpv && mpv=$(command -v mpv)
            else
                die "No mpv build for macOS $os. Install Homebrew (https://brew.sh) and run this again."
            fi
            xattr -dr com.apple.quarantine "$apps/mpv.app" 2>/dev/null || true
        fi
        syncplay=""
        for p in /Applications/Syncplay.app/Contents/MacOS/Syncplay "$apps/Syncplay.app/Contents/MacOS/Syncplay"; do
            [ -x "$p" ] && syncplay="$p" && break
        done
        if [ -z "$syncplay" ]; then
            say "Installing Syncplay..."
            tmp=$(mktemp -d)
            curl -fL# "$(gh_asset Syncplay/syncplay '\.dmg$')" -o "$tmp/syncplay.dmg"
            hdiutil attach -nobrowse -quiet -mountpoint "$tmp/mnt" "$tmp/syncplay.dmg"
            rm -rf "$apps/Syncplay.app" && cp -R "$tmp/mnt/Syncplay.app" "$apps/"
            hdiutil detach -quiet "$tmp/mnt" || true
            rm -rf "$tmp"
            xattr -dr com.apple.quarantine "$apps/Syncplay.app" 2>/dev/null || true
            syncplay="$apps/Syncplay.app/Contents/MacOS/Syncplay"
        fi
        ;;
    *)
        dir="${XDG_DATA_HOME:-$HOME/.local/share}/ani-party"
        mkdir -p "$dir"
        mpv=$(command -v mpv || true)
        syncplay=$(command -v syncplay || true)
        if [ -z "$mpv" ] || [ -z "$syncplay" ]; then
            if command -v pacman >/dev/null; then cmd="sudo pacman -S --needed mpv syncplay"
            elif command -v apt-get >/dev/null; then cmd="sudo apt-get install -y mpv syncplay"
            elif command -v dnf >/dev/null; then cmd="sudo dnf install -y mpv syncplay"
            elif command -v zypper >/dev/null; then cmd="sudo zypper install -y mpv syncplay"
            else cmd="install mpv and syncplay with your package manager"; fi
            die "mpv and syncplay are needed. Run:  $cmd  then paste the same command again."
        fi
        ;;
esac

curl -fsSL "$gist/party.lua" -o "$dir/party.lua" || [ -f "$dir/party.lua" ] || die "could not download party.lua"

# private config dir: Syncplay's ini lives here and mpv starts with a clean config
mkdir -p "$dir/cfg"
cat >"$dir/cfg/syncplay.ini" <<EOF
[server_data]
host = ${server%:*}
port = ${server##*:}
password =
[client_settings]
name = $name
room = $room
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
EOF

say "Joining room $room as $name. Chat: press Enter in the video window. Subtitle timing: z / Z. Quit: close mpv or Ctrl-C here."
# --no-gui: without a file argument the GUI always opens its settings dialog first
XDG_CONFIG_HOME="$dir/cfg" exec "$syncplay" --no-gui --no-store -- --scripts-append="$dir/party.lua" </dev/tty
