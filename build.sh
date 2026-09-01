#!/bin/bash
# Builds nerdsidekiq as a real .app bundle. TCC (the permission system) attributes
# permissions to a bundle identifier, so a bare CLI binary would inherit the
# terminal's permissions instead of owning its own.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/NerdSidekiq.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/"
cp assets/icon/AppIcon.icns "$APP/Contents/Resources/"

swiftc -O -parse-as-library \
  -framework AudioToolbox -framework CoreAudio -framework AVFoundation -framework Foundation \
  -framework SwiftUI -framework AppKit \
  -target arm64-apple-macos14.4 \
  -o "$APP/Contents/MacOS/nerdsidekiq" \
  src/Recorder.swift src/NerdSidekiqApp.swift src/SettingsUI.swift

codesign --force --sign - \
  --entitlements nerdsidekiq.entitlements \
  --options runtime \
  "$APP"

echo "built: $APP/Contents/MacOS/nerdsidekiq"
