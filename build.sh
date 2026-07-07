#!/bin/sh
# Build DuplexPrint.app and install it to ~/Applications.
set -e
cd "$(dirname "$0")"

APP=DuplexPrint.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

ARCH=$(uname -m)
swiftc -O -parse-as-library -target "$ARCH-apple-macos13.0" DuplexPrint.swift \
  -o "$APP/Contents/MacOS/DuplexPrint"

codesign --force --deep -s - "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/DuplexPrint.app
cp -R "$APP" ~/Applications/
echo "Installed to ~/Applications/DuplexPrint.app"
