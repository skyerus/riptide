#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $# != 2 || "$1" != /* || "$2" != /* || ! -x "$1" || ! -O "$2" ]]; then
    echo "Usage (as the Hermes profile owner): $0 /absolute/hermes /absolute/profile" >&2
    exit 2
fi

hermes=$1
export HERMES_HOME=$2
chrome=/usr/bin/google-chrome-stable
setting=browser.executable_path

install_chrome() {
    local package_arch signing_key source
    local -a administrator=()
    if [[ $EUID != 0 ]]; then
        administrator=(sudo)
    fi
    package_arch=$(dpkg --print-architecture)
    case "$package_arch" in
        amd64|arm64) ;;
        *) echo "Google Chrome Stable requires an amd64 or arm64 Debian-based host." >&2; return 1 ;;
    esac

    signing_key=/usr/share/keyrings/google-chrome.gpg
    source=/etc/apt/sources.list.d/google-chrome.list
    if [[ ! -e "$source" ]]; then
        # Trust Google's current signing key for this repository only.
        curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o "$scratch/google.pub"
        install -d -m 0700 "$scratch/gnupg"
        gpg --batch --homedir "$scratch/gnupg" --import "$scratch/google.pub"
        gpg --batch --homedir "$scratch/gnupg" --export EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796 \
            > "$scratch/google-chrome.gpg"
        test -s "$scratch/google-chrome.gpg"
        printf 'deb [arch=%s signed-by=%s] https://dl.google.com/linux/chrome/deb/ stable main\n' \
            "$package_arch" "$signing_key" > "$scratch/google-chrome.list"
        "${administrator[@]}" install -m 0644 "$scratch/google-chrome.gpg" "$signing_key"
        "${administrator[@]}" install -m 0644 "$scratch/google-chrome.list" "$source"
    fi
    "${administrator[@]}" apt-get update
    "${administrator[@]}" apt-get install -y google-chrome-stable
}

dock_uses_stable() {
    local panel launcher_id
    panel="$HERMES_HOME/bot-desktop/xdg/xfce4/panel"
    [[ -r "$panel/.hermes-browser-launcher" ]] || return 1
    launcher_id=$(<"$panel/.hermes-browser-launcher")
    [[ "$launcher_id" =~ ^[0-9]{1,8}$ ]] || return 1
    grep -q "^Exec=\"${chrome}\" " "$panel/launcher-$launcher_id/hermes.desktop"
}

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
if [[ ! -x "$chrome" ]]; then
    install_chrome
fi
"$chrome" --version

previous=$("$hermes" config get "$setting")
if [[ "$previous" == "$chrome" ]] && dock_uses_stable; then
    exit 0
fi

# Hermes refuses an unforced stop while a human holds the control lease.
# Starting the desktop rewrites the Browser launcher's Exec line for this profile.
"$hermes" computer-use screen stop
if "$hermes" config set "$setting" "$chrome" \
    && [[ $("$hermes" config get "$setting") == "$chrome" ]] \
    && "$hermes" computer-use screen start \
    && dock_uses_stable; then
    echo "Hermes Bot Screen and browser tools now use Google Chrome Stable."
    exit 0
fi

echo "Could not activate Chrome Stable for this profile. Restoring its previous executable." >&2
"$hermes" computer-use screen stop
if [[ -n "$previous" ]]; then
    "$hermes" config set "$setting" "$previous"
else
    "$hermes" config unset "$setting"
fi
"$hermes" computer-use screen start
exit 1
