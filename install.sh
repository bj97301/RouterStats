#!/bin/bash
# Builds RouterStats, installs it to ~/Applications and starts it at login.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="io.github.bj97301.RouterStats"
APP="$HOME/Applications/RouterStats.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

command -v swiftc >/dev/null || { echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install"; exit 1; }

echo "Building…"
rm -rf build && mkdir -p build/RouterStats.app/Contents/MacOS
swiftc -O Sources/*.swift -o build/RouterStats.app/Contents/MacOS/RouterStats
cp Info.plist build/RouterStats.app/Contents/Info.plist
codesign --force --sign - build/RouterStats.app

echo "Installing to ${APP}…"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x RouterStats 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$APP" && cp -R build/RouterStats.app "$APP"

# Start through launchd (not from this terminal) so macOS treats RouterStats as its own menu bar app.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/RouterStats</string></array>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>ProcessType</key><string>Interactive</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "Done. RouterStats is running and will start at login."
echo "On first launch a setup window asks for your router's address, username and password."
