#!/bin/bash
# Regenerate Icon/AppIcon.icns and Icon/AppIcon.png from Icon/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift make-icon.swift "$WORK/icon.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
	sips -z "$size" "$size" "$WORK/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
	double=$((size * 2))
	sips -z "$double" "$double" "$WORK/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o AppIcon.icns
sips -z 512 512 "$WORK/icon.png" --out AppIcon.png >/dev/null
echo "Wrote Icon/AppIcon.icns and Icon/AppIcon.png"
