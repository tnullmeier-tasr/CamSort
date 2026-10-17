#!/bin/bash
# Baut CamSort.app (Universal: Apple Silicon + Intel). Läuft auf macOS mit Xcode/Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target ${arch}-apple-macos14.0 Sources/*.swift -o build/CamSort-${arch}
done
APP=build/CamSort.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create build/CamSort-arm64 build/CamSort-x86_64 -output "$APP/Contents/MacOS/CamSort"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION##*.}" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$APP"
(cd build && ditto -c -k --keepParent CamSort.app CamSort.zip)
echo "Fertig: build/CamSort.app"
