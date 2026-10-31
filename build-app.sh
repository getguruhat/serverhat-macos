#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
cd "$ROOT"
swift build -c release

APP="$ROOT/ServerHat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ServerHat "$APP/Contents/MacOS/ServerHat"
cp AppInfo.plist "$APP/Contents/Info.plist"
cp icon.png "$APP/Contents/Resources/icon.png"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP" >/dev/null

# --no-dmg skips the installer, for quick local builds.
if [[ "${1:-}" != "--no-dmg" ]]; then
  "$ROOT/../../../tools/create-dmg-installer.sh" "$APP" "ServerHat" "$ROOT/ServerHat-Installer.dmg"
  # A copy named with the version, which guruhat.com links to. The fixed name keeps
  # releases/latest/download/ServerHat-Installer.dmg working.
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" AppInfo.plist)
  cp "$ROOT/ServerHat-Installer.dmg" "$ROOT/ServerHat-$VERSION-Installer.dmg"
fi
print "$APP"
