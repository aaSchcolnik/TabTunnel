#!/bin/bash
# Build, sign and (optionally) install TabTunnel.app.
#
#   scripts/build.sh              build build/TabTunnel.app
#   scripts/build.sh --install    build, quit the running copy, install to /Applications and open it
#
# Environment: TABTUNNEL_SIGN_IDENTITY picks the signing identity; TABTUNNEL_UNIVERSAL=1 builds arm64 + x86_64.
#
# Signing: uses $TABTUNNEL_SIGN_IDENTITY, else the first "Developer ID Application" or "Apple Development"
# identity in your keychain. It never falls back to ad-hoc signing: macOS ties the Full Disk Access grant to the
# signature, and a certificate-based signature keeps that grant across rebuilds (ad-hoc ones lose it every time).
set -euo pipefail
cd "$(dirname "$0")/.."
APP_NAME="TabTunnel"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
READER="$APP/Contents/Helpers/TabTunnel Reader.app"
VERSION="$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/TabTunnelModel/Reader.swift)"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

IDENTITY="${TABTUNNEL_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "No code signing identity found. Create a free 'Apple Development' certificate in Xcode › Settings › Accounts," >&2
  echo "or set TABTUNNEL_SIGN_IDENTITY. (Ad-hoc signing would lose Full Disk Access on every rebuild.)" >&2
  exit 1
fi
echo "Signing with: $IDENTITY"

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift Resources/AppIcon.icns
[[ -f Resources/ReaderIcon.icns ]] || swift scripts/make-icon.swift Resources/ReaderIcon.icns reader

# TABTUNNEL_UNIVERSAL=1 builds for both Apple silicon and Intel (the downloadable releases do this).
ARCHS=()
[[ "${TABTUNNEL_UNIVERSAL:-}" == "1" ]] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product TabTunnel
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product TabTunnelReader
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$READER/Contents/MacOS" "$READER/Contents/Resources"
cp "$BIN/TabTunnel" "$APP/Contents/MacOS/TabTunnel"
cp "$BIN/TabTunnelReader" "$READER/Contents/MacOS/TabTunnel Reader"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/ReaderIcon.icns "$READER/Contents/Resources/AppIcon.icns"

plist() { # path, bundle id, name, executable, extra xml
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleName</key><string>$3</string>
  <key>CFBundleDisplayName</key><string>$3</string>
  <key>CFBundleExecutable</key><string>$4</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>TabTunnel</string>
  $5
</dict>
</plist>
EOF
}
plist "$APP/Contents/Info.plist" "dev.tabtunnel.TabTunnel" "TabTunnel" "TabTunnel" \
  "<key>LSUIElement</key><true/><key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>"
plist "$READER/Contents/Info.plist" "dev.tabtunnel.TabTunnel.Reader" "TabTunnel Reader" "TabTunnel Reader" \
  "<key>LSBackgroundOnly</key><true/>"

# Inside-out: the nested Reader first, then the app. Hardened runtime, no entitlements (no debugger can attach).
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$READER"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Designated requirement (what Full Disk Access is tied to):"
codesign -d -r- "$READER" 2>&1 | sed -n 's/^designated => /  /p'
du -sh "$APP" | awk '{print "Size: " $1}'

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/$APP_NAME.app"
  osascript -e 'quit app id "dev.tabtunnel.TabTunnel"' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -xq TabTunnel || break; sleep 0.25; done
  pkill -x TabTunnel 2>/dev/null || true
  # The reader restarts on demand from the new copy.
  launchctl kill SIGTERM "gui/$(id -u)/dev.tabtunnel.TabTunnel.Reader" >/dev/null 2>&1 || true
  rm -rf "$DEST.new"
  ditto "$APP" "$DEST.new"
  rm -rf "$DEST"
  mv "$DEST.new" "$DEST"
  echo "Installed $DEST"
  open "$DEST"
fi
