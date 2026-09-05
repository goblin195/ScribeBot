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
# We already cd'd to this script's directory, so the path is relative to it.
# Using $(dirname "$0") a second time looked for app/app/icon when the script
# was run as ./app/build.sh, the copy failed, and `|| true` swallowed it - the
# rebuilt app silently lost its icon. Let a missing icon fail the build.
cp icon/Scribebot.icns "$APP/Contents/Resources/"

codesign --force -s - -i dev.scribebot.app "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature'
echo "built $PWD/$APP"
