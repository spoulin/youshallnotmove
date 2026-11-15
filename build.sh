#!/bin/bash
# Build YouShallNotMove.app, sign it and install it in ~/Applications.
# A stable signing identity keeps the Accessibility permission across rebuilds.
#
# VERSION=1.2.0 ./build.sh  sets the version shown in the app; without it, the latest git tag
#                           (v1.2.0 gives 1.2.0), else the version in Info.plist.
# UNIVERSAL=1               builds for both Apple silicon and Intel Macs, as releases do.
# NO_INSTALL=1              builds build/YouShallNotMove.app only (the Release workflow).
# SIGN_KEYCHAIN=<path>      the keychain holding SIGN_ID, when it isn't the login one.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# Use SIGN_ID, else the first "Apple Development" identity, else an ad-hoc signature
# (ad-hoc means granting Accessibility again after each rebuild).
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')}"
SIGN_ID="${SIGN_ID:--}"
APP="build/YouShallNotMove.app"
DEST="$HOME/Applications/YouShallNotMove.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
compile() { # compile <output> [target]
	swiftc -O -swift-version 5 ${2:+-target "$2"} \
		-o "$1" \
		Sources/main.swift \
		-framework AppKit -framework ApplicationServices -framework Carbon -framework ServiceManagement
}
if [[ -n "${UNIVERSAL:-}" ]]; then
	MIN=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" Info.plist)
	compile "build/YouShallNotMove-arm64" "arm64-apple-macos$MIN"
	compile "build/YouShallNotMove-x86_64" "x86_64-apple-macos$MIN"
	lipo -create -output "$APP/Contents/MacOS/YouShallNotMove" build/YouShallNotMove-arm64 build/YouShallNotMove-x86_64
	rm -f build/YouShallNotMove-arm64 build/YouShallNotMove-x86_64
else
	compile "$APP/Contents/MacOS/YouShallNotMove"
fi
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cp Sounds/*.wav "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign "$SIGN_ID" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$APP"
echo "Built $APP $VERSION ($BUILD)"
[[ -n "${NO_INSTALL:-}" ]] && exit 0

pkill -x YouShallNotMove || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
