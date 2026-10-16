#!/bin/bash
# Compiles Sources/*.swift into build/ActivityLogger.app (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/ActivityLogger.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -framework Cocoa -framework ApplicationServices Sources/*.swift -o "$APP/Contents/MacOS/ActivityLogger"
cp Info.plist "$APP/Contents/Info.plist"
echo -n 'APPL????' > "$APP/Contents/PkgInfo"
# Ad-hoc signature with a fixed identifier so privacy permissions stick across rebuilds.
codesign --force --sign - --identifier com.julianmoncarz.activitylogger "$APP"
echo "Built $APP"
