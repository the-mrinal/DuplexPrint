#!/bin/sh
# Build a distributable DuplexPrint DMG into dist/.
#
#   VERSION=4.2 ./scripts/make-dmg.sh     # stamp a version
#   ./scripts/make-dmg.sh                 # unversioned "dev" build
#
# The binary is universal (Apple Silicon + Intel), the app is ad-hoc signed
# (no Apple Developer ID), so first launch on another Mac needs the one-time
# Gatekeeper approval described in the DMG's READ ME FIRST.txt.
set -e
cd "$(dirname "$0")/.."

VERSION="${VERSION:-dev}"
APP=dist/DuplexPrint.app

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
if [ "$VERSION" != "dev" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

echo "Building arm64 slice…"
swiftc -O -parse-as-library -target arm64-apple-macos13.0 DuplexPrint.swift -o dist/DuplexPrint-arm64
echo "Building x86_64 slice…"
swiftc -O -parse-as-library -target x86_64-apple-macos13.0 DuplexPrint.swift -o dist/DuplexPrint-x86_64
lipo -create dist/DuplexPrint-arm64 dist/DuplexPrint-x86_64 -output "$APP/Contents/MacOS/DuplexPrint"
lipo -info "$APP/Contents/MacOS/DuplexPrint"
rm dist/DuplexPrint-arm64 dist/DuplexPrint-x86_64

codesign --force --deep -s - "$APP"

STAGE=dist/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'EOF'
DuplexPrint — install & first launch
====================================

1. Drag DuplexPrint.app onto the Applications folder icon next to it.

2. FIRST LAUNCH ONLY — macOS will block the app because it isn't
   notarized by Apple (this app is signed locally, not with a paid
   Apple Developer ID). Approve it once:

   • macOS 15 (Sequoia) or newer:
     Open the app (it gets blocked) → System Settings →
     Privacy & Security → scroll down → "Open Anyway" → confirm.

   • macOS 13/14:
     Right-click (or Control-click) DuplexPrint.app → Open → Open.

   Alternatively, in Terminal:
     xattr -d com.apple.quarantine /Applications/DuplexPrint.app

3. After that it opens normally forever. Requires macOS 13 or newer;
   works on both Apple Silicon and Intel Macs.
EOF

hdiutil create -volname "DuplexPrint" -srcfolder "$STAGE" -ov -format UDZO \
  "dist/DuplexPrint-$VERSION.dmg"
rm -rf "$STAGE" dist/DuplexPrint.app
echo "Created dist/DuplexPrint-$VERSION.dmg"
