#!/bin/bash
# One-line installer for LidNap:
#   curl -fsSL https://raw.githubusercontent.com/WilberC/LidNap/main/install.sh | bash
# Downloads the source, builds it locally (a few seconds), installs to ~/Applications.
set -e

if ! command -v swiftc >/dev/null 2>&1; then
    echo "LidNap builds from source and needs the Xcode Command Line Tools."
    echo "Install them first with:  xcode-select --install"
    echo "Then re-run this installer."
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading LidNap..."
curl -fsSL https://github.com/WilberC/LidNap/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP" --strip-components=1

cd "$TMP"
./build.sh

echo
echo "Installed: ~/Applications/LidNap.app"
echo "Fail-safe agent: ~/Library/LaunchAgents/com.wilberc.lidnap.failsafe.plist"
echo
echo "Recommended one-time step (lets the toggle work without a password prompt):"
echo "  bash ~/Applications/LidNap.app/Contents/Resources/setup-permissions.sh"
echo
echo "Launch it with:"
echo "  open ~/Applications/LidNap.app"
