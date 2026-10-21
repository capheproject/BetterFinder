#!/bin/zsh
# Builds BetterFinder.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/BetterFinder"

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift Resources

APP=build/BetterFinder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BetterFinder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/BetterFinder.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/BetterFinder.app"
fi
