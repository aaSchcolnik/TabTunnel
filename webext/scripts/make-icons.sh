#!/bin/bash
# Make the extension's icons from the Mac app's icon (app/Resources/AppIcon.icns), so both look the same.
# The app icon has macOS's margin around the blue squircle; the extension icons are cropped to the squircle.
#   webext/scripts/make-icons.sh      (macOS only: uses iconutil and sips)
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
iconutil -c iconset ../app/Resources/AppIcon.icns -o "$tmp/app.iconset"
# 1024px source; the squircle spans x 103-921, y 87-906.
sips -s format png --cropToHeightWidth 820 820 --cropOffset 86 102 "$tmp/app.iconset/icon_512x512@2x.png" --out "$tmp/square.png" >/dev/null
for s in 16 32 48 128; do
  sips -z "$s" "$s" "$tmp/square.png" --out "icons/$s.png" >/dev/null
done
echo "icons/{16,32,48,128}.png written"
