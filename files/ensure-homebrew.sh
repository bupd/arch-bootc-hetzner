#!/bin/bash
set -euo pipefail

BREW_PREFIX="/home/linuxbrew/.linuxbrew"
BREW_BIN="${BREW_PREFIX}/bin/brew"
BREWFILE="/usr/share/arch-bootc-hetzner/homebrew/Brewfile"
TARGET_USER="bupd"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "ensure-homebrew: user $TARGET_USER does not exist" >&2
    exit 1
fi

install_homebrew() {
    install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" /home/linuxbrew
    sudo -H -u "$TARGET_USER" env NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

if [ ! -x "$BREW_BIN" ]; then
    install_homebrew
fi

if [ -f "$BREWFILE" ]; then
    sudo -H -u "$TARGET_USER" env PATH="${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${PATH}" \
        "$BREW_BIN" bundle --file "$BREWFILE"
fi
