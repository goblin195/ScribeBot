#!/bin/bash
# Build + ad-hoc sign the audio capture helper.
#
# The helper must be a real .app bundle, not a bare executable: macOS grants
# kTCCServiceAudioCapture (system audio recording) to a bundle identity, and a
# loose binary can never hold that permission. The Info.plist here is what the
# grant is attached to.
#
# Re-signing can invalidate an existing grant, after which the first capture
# hangs waiting on a permission that is no longer held. If system audio stops
# working right after running this, re-approve Scribebot under
# System Settings > Privacy & Security > Screen & System Audio Recording.
set -euo pipefail
cd "$(dirname "$0")"
APP="ScribebotCapture.app"
BIN="$APP/Contents/MacOS/ScribebotCapture"

mkdir -p "$APP/Contents/MacOS"
swiftc -target arm64-apple-macos14.2 -O -o "$BIN" tap.swift

codesign --force -s - -i dev.scribebot.capture "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature'
echo "built $PWD/$APP"
