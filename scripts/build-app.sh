#!/bin/zsh
# Builds BetterFinder.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/BetterFinder"

if [[ ! -f Resources/AppIcon.icns ]]; then
  mkdir -p .build/tools
  swiftc -O -o .build/tools/make-icon scripts/make-icon/main.swift Sources/BetterFinder/Services/AppIconRenderer.swift
  .build/tools/make-icon Resources
fi

APP=build/BetterFinder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BetterFinder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with the stable local identity (see scripts/setup-signing.sh) so macOS keeps folder
# permissions across reinstalls. Falls back to ad-hoc signing when it hasn't been set up.
SIGN_KEYCHAIN="$HOME/Library/Keychains/BetterFinderSigning.keychain-db"
SIGN_IDENTITY="BetterFinder Local Signing"
if [[ -f "$SIGN_KEYCHAIN" ]]; then
  security unlock-keychain -p "betterfinder-local-signing" "$SIGN_KEYCHAIN"
  # codesign only finds identities in the search list; add ours just for this command.
  ORIGINAL_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
  restore_keychains() { security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" }
  trap restore_keychains EXIT
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$SIGN_KEYCHAIN"
  codesign --force --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1
  restore_keychains
  trap - EXIT
  echo "Signed with “$SIGN_IDENTITY”"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Signed ad-hoc (run scripts/setup-signing.sh so permissions survive reinstalls)"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/BetterFinder.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/BetterFinder.app"
fi
