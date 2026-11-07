#!/bin/bash
# Builds LidAwake.app, installs it into ~/Applications and (re)loads the
# fail-safe LaunchAgent.
set -e
cd "$(dirname "$0")"

APP="$HOME/Applications/LidAwake.app"
AGENT_LABEL="com.wilberc.lidawake.failsafe"
AGENT="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp main.swift Guards.swift "$APP/Contents/Resources/"
cp setup-permissions.sh failsafe.sh "$APP/Contents/Resources/"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -o "$APP/Contents/MacOS/LidAwake" main.swift Guards.swift \
    -F /System/Library/PrivateFrameworks -framework DisplayServices

codesign --force --sign - "$APP"
echo "Built and installed: $APP"

# Fail-safe agent: restores normal sleep if the app dies or hangs while it
# keeps the Mac awake.
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#__FAILSAFE_PATH__#$APP/Contents/Resources/failsafe.sh#" \
    "$AGENT_LABEL.plist" > "$AGENT"
launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Fail-safe agent loaded: $AGENT"

echo "Launch it with: open \"$APP\""
