#!/bin/bash
# Assemble tinker.app from a SwiftPM release build.
#
# Usage: scripts/bundle.sh [output-dir]        (default: ./dist)
# Signing: auto-detected from the keychain (Developer ID, else Apple
# Development, else ad-hoc); override with CODESIGN_IDENTITY. TCC grants
# only survive updates with a stable identity.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
OUT="${1:-dist}"
APP="$OUT/tinker.app"

# Signing identity: CODESIGN_IDENTITY wins ("-" forces ad-hoc). Otherwise
# use the best certificate in the login keychain — a Developer ID lets the
# app open on any Mac; an Apple Development cert is only trusted on Macs
# that have it, but still gives THIS Mac a stable signature so the
# Microphone/Accessibility grants survive rebuilds. Ad-hoc as a last resort.
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  FOUND=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
  if [ -z "$FOUND" ]; then
    FOUND=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
  fi
  IDENTITY="${FOUND:--}"
else
  IDENTITY="$CODESIGN_IDENTITY"
fi

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/tingle "$APP/Contents/MacOS/tingle"
# SwiftPM resource bundle (device payload); Bundle.module resolves it via
# Bundle.main.resourceURL inside an .app.
cp -R .build/release/*.bundle "$APP/Contents/Resources/"

# App icon: .icns from the checked-in 1024px render of docs/images/icon.svg
# (regenerate with: qlmanage -t -s 1024 -o /tmp docs/images/icon.svg
#  && mv /tmp/icon.svg.png packaging/icon_1024.png).
ICONSET="$(mktemp -d)/tinker.iconset"
mkdir -p "$ICONSET"
for S in 16 32 128 256 512; do
    sips -z "$S" "$S" packaging/icon_1024.png --out "$ICONSET/icon_${S}x${S}.png" > /dev/null
    D=$((S * 2))
    sips -z "$D" "$D" packaging/icon_1024.png --out "$ICONSET/icon_${S}x${S}@2x.png" > /dev/null
done
iconutil -c icns -o "$APP/Contents/Resources/tinker.icns" "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.noahread.tinker</string>
    <key>CFBundleName</key>
    <string>tinker</string>
    <key>CFBundleDisplayName</key>
    <string>tinker</string>
    <key>CFBundleExecutable</key>
    <string>tingle</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>tinker</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>tinker's summon-agent button brings your coding app to the front.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>tinker listens to your line-in to detect the ting's ultrasonic signals, to show a level meter, and to transcribe dictation from its microphone.</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Noah Read. Based on tingle © Tutor Intelligence, Inc. MIT License.</string>
</dict>
</plist>
PLIST

# Hardened runtime + secure timestamps are REQUIRED for notarization; the
# entitlements re-grant mic capture and Apple Events under the hardened
# runtime.
if [ "$IDENTITY" != "-" ]; then
  codesign --force --options runtime --timestamp \
      --entitlements packaging/entitlements.plist \
      --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign "$IDENTITY" "$APP"
fi
echo "built $APP (version $VERSION, signed: $IDENTITY)"
