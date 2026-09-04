#!/bin/bash
# Build + ad-hoc sign the menu bar app. No Xcode project, no signing identity.
set -euo pipefail
cd "$(dirname "$0")"
APP="Scribebot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
swiftc -target arm64-apple-macos14.0 -parse-as-library \
       -o "$APP/Contents/MacOS/Scribebot" Sources/*.swift
mkdir -p "$APP/Contents/Resources"
cp "$(dirname "$0")/icon/Scribebot.icns" "$APP/Contents/Resources/" 2>/dev/null || true

codesign --force -s - -i dev.scribebot.app "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature'
echo "built $PWD/$APP"
