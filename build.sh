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

# ./build.sh install  → laufendes CamSort sauber beenden, neue Version nach /Applications kopieren und starten
if [ "${1:-}" = "install" ]; then
  if pgrep -x CamSort >/dev/null; then
    echo "Beende laufendes CamSort …"
    osascript -e 'tell application "CamSort" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -x CamSort >/dev/null || break; sleep 0.2; done
    pkill -x CamSort 2>/dev/null || true
    for _ in $(seq 1 25); do pgrep -x CamSort >/dev/null || break; sleep 0.2; done
  fi
  rm -rf /Applications/CamSort.app
  ditto build/CamSort.app /Applications/CamSort.app
  xattr -dr com.apple.quarantine /Applications/CamSort.app 2>/dev/null || true
  open -n /Applications/CamSort.app
  echo "Installiert und gestartet: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/CamSort.app/Contents/Info.plist)"
fi
