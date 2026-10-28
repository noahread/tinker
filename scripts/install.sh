#!/bin/bash
# Build tinker from this checkout and install it to /Applications.
#
#   scripts/install.sh            build, install, (re)launch
#   VERSION=1.2.0 scripts/install.sh
#
# Needs Xcode Command Line Tools (xcode-select --install). Signing is
# auto-detected by bundle.sh; on a Mac with no certificate the app is
# ad-hoc signed, which works fine locally — macOS just re-asks for the
# Microphone/Accessibility grants after each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh

osascript -e 'tell application id "com.noahread.tinker" to quit' 2>/dev/null || true
for i in $(seq 1 10); do
    pgrep -f "tinker.app/Contents/MacOS/tingle" >/dev/null 2>&1 || break
    sleep 0.5
done
pkill -f "tinker.app/Contents/MacOS/tingle" 2>/dev/null || true

rm -rf /Applications/tinker.app
cp -R dist/tinker.app /Applications/tinker.app
open /Applications/tinker.app
echo "installed /Applications/tinker.app and launched it"
