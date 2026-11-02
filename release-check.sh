#!/bin/zsh
# Checks a release before it's published: runs the tests, then installs the app from the
# DMG into a temporary folder and opens its Settings window there, failing if a tab
# doesn't fit. It never touches /Applications, your servers or the running ServerHat.
#
#   ./release-check.sh                      # checks ServerHat-<AppInfo version>-Installer.dmg
#   ./release-check.sh path/to/Installer.dmg
set -euo pipefail

ROOT="${0:A:h}"
cd "$ROOT"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" AppInfo.plist)
DMG="${1:-$ROOT/ServerHat-$VERSION-Installer.dmg}"
[[ -f "$DMG" ]] || { print "No $DMG. Run ./build-app.sh first."; exit 1 }

print "== Tests"
# The Command Line Tools' Swift sometimes can't load the Testing macros while building;
# that's a toolchain hiccup, not a failing test, so build a few times before giving up.
for attempt in 1 2 3 4 5; do
  BUILD=$(swift build --build-tests 2>&1) && break
  [[ "$BUILD" == *"plugin for module 'TestingMacros' not found"* ]] || { print -r -- "$BUILD" | tail -20; print "FAIL build"; exit 1 }
done
TESTS=0
OUTPUT=$(swift test --skip-build 2>&1) || TESTS=$?
print -r -- "$OUTPUT" | sed $'s/\e\\[[0-9;]*m//g' | grep -aE "Test run with|✘|error:" || true
(( TESTS == 0 )) || { print "FAIL tests"; exit 1 }

WORK=$(mktemp -d -t serverhat-release-check)
MOUNT="$WORK/mount"
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true' EXIT
print "== $DMG"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null 2>&1
ditto "$MOUNT/ServerHat.app" "$WORK/ServerHat.app"
hdiutil detach -quiet "$MOUNT"

APP="$WORK/ServerHat.app"
FAILED=0
check() { if eval "$2"; then print "ok   $1"; else print "FAIL $1"; FAILED=1; fi }
check "version is $VERSION" '[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist") == "$VERSION" ]]'
check "signature is valid" 'codesign -v "$APP" 2>/dev/null'
check "icon is bundled" '[[ -f "$APP/Contents/Resources/icon.png" && -f "$APP/Contents/Resources/AppIcon.icns" ]]'

print "== Settings window"
SHOTS="$ROOT/release-check"
rm -rf "$SHOTS"
SERVERHAT_SUPPORT_FOLDER="$WORK/support" "$APP/Contents/MacOS/ServerHat" --snapshot "$SHOTS" || FAILED=1

print "Screenshots: $SHOTS (look at them before publishing)"
if (( FAILED )); then print "== Release check FAILED"; exit 1; fi
print "== Release check passed"
