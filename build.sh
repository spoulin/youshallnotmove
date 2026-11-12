#!/bin/bash
# Build YouShallNotMove.app, sign it and install it in ~/Applications.
# A stable signing identity keeps the Accessibility permission across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

# Use SIGN_ID, else the first "Apple Development" identity, else an ad-hoc signature
# (ad-hoc means granting Accessibility again after each rebuild).
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')}"
SIGN_ID="${SIGN_ID:--}"
APP="build/YouShallNotMove.app"
DEST="$HOME/Applications/YouShallNotMove.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 \
	-o "$APP/Contents/MacOS/YouShallNotMove" \
	Sources/main.swift \
	-framework AppKit -framework ApplicationServices -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cp Sounds/*.wav "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign "$SIGN_ID" "$APP"

pkill -x YouShallNotMove || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
