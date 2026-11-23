#!/bin/bash
# Builds the app, copies it to ~/Applications, and registers a LaunchAgent so it
# starts at login and is relaunched if it ever exits. Encrypted logs go to
# ~/personal-tools/data/activity-logger.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

LABEL=com.julianmoncarz.activitylogger
DEST="$HOME/Applications/ActivityLogger.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/personal-tools/data/activity-logger"

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$LOGDIR"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ActivityLogger 2>/dev/null || true
rm -rf "$DEST"
cp -R build/ActivityLogger.app "$DEST"

# Encryption key, which Chrome profile to log, and encrypting any old plain-text logs.
# Safe to run again: it keeps the existing key and profile choice.
BIN="$DEST/Contents/MacOS/ActivityLogger"
"$BIN" setup

# `activity-logger` on the command line, for export and settings.
mkdir -p "$HOME/.local/bin"
ln -sf "$BIN" "$HOME/.local/bin/activity-logger"

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
	<string>$LOGDIR/errors.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed to $DEST and started. It will launch at login."
echo "Logs (encrypted): $LOGDIR/YYYY-MM-DD.jsonl.enc"
echo "Read them back with: $HOME/.local/bin/activity-logger export --days 7 --copy"
echo "1. Allow Accessibility when prompted (System Settings > Privacy & Security > Accessibility)."
echo "2. Bring Chrome to the front; when asked to let Activity Logger control Chrome, click OK."
