#!/bin/bash
# Stops the logger and removes the LaunchAgent and app. The encrypted logs and their key are kept.
set -euo pipefail
LABEL=com.julianmoncarz.activitylogger
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ActivityLogger 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/ActivityLogger.app"
rm -f "$HOME/.local/bin/activity-logger"
echo "Uninstalled. Encrypted logs and their key are kept in ~/personal-tools/data/activity-logger."
echo "Delete that folder to erase everything."
