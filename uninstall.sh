#!/bin/bash
# Stops the logger and removes the LaunchAgent and app. Logs in ~/personal-tools/data/activity-logger are kept.
set -euo pipefail
LABEL=com.julianmoncarz.activitylogger
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ActivityLogger 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/ActivityLogger.app"
echo "Uninstalled. Logs kept in ~/personal-tools/data/activity-logger."
