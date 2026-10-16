#!/bin/bash
# Builds the app, copies it to ~/Applications, and registers a LaunchAgent so it
# starts at login and is relaunched if it ever exits. Logs go to ~/ActivityLog.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

LABEL=com.julianmoncarz.activitylogger
DEST="$HOME/Applications/ActivityLogger.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/ActivityLog"

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$LOGDIR"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ActivityLogger 2>/dev/null || true
rm -rf "$DEST"
cp -R build/ActivityLogger.app "$DEST"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Contents/MacOS/ActivityLogger</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>$LOGDIR/_logger-errors.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed to $DEST and started. It will launch at login."
echo "Logs: $LOGDIR/YYYY-MM-DD.jsonl"
echo "1. Allow Accessibility when prompted (System Settings > Privacy & Security > Accessibility)."
echo "2. Bring Chrome to the front; when asked to let Activity Logger control Chrome, click OK."
