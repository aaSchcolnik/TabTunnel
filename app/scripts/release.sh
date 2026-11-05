#!/bin/bash
# Build the downloadable release: a universal TabTunnel.app signed with the project's self-signed certificate,
# zipped for GitHub Releases. Used by .github/workflows/release.yml; works locally too.
#
#   TABTUNNEL_P12=<base64 .p12> TABTUNNEL_P12_PASSWORD=<password> scripts/release.sh <out.zip>
#
# The certificate is a plain self-signed code-signing certificate ("TabTunnel Release Signing"), not an Apple one,
# so the app isn't notarized. Every release is signed with the same certificate, which keeps the Full Disk Access
# grant across updates and lets the app and its Reader verify each other.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(cd "$(dirname "${1:?usage: release.sh <out.zip>}")" && pwd)/$(basename "$1")"
: "${TABTUNNEL_P12:?set TABTUNNEL_P12 to the base64 signing .p12}"
: "${TABTUNNEL_P12_PASSWORD:?set TABTUNNEL_P12_PASSWORD}"

TMP="$(mktemp -d)"
KC="$TMP/release.keychain-db"
KCPASS="$(openssl rand -hex 16)"
OLD_KCS="$(security list-keychains -d user | tr -d '"' | xargs)"
cleanup() {
  # shellcheck disable=SC2086
  security list-keychains -d user -s $OLD_KCS
  security delete-keychain "$KC" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "$TABTUNNEL_P12" | base64 --decode > "$TMP/sign.p12"
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$TMP/sign.p12" -k "$KC" -P "$TABTUNNEL_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KC" >/dev/null
# shellcheck disable=SC2086
security list-keychains -d user -s "$KC" $OLD_KCS

HASH="$(security find-certificate -c "TabTunnel Release Signing" -Z "$KC" | sed -n 's/^SHA-1 hash: //p' | head -1)"
[[ -n "$HASH" ]] || { echo "signing certificate not found in the .p12" >&2; exit 1; }

TABTUNNEL_SIGN_IDENTITY="$HASH" TABTUNNEL_UNIVERSAL=1 scripts/build.sh
rm -f "$OUT"
ditto -c -k --keepParent build/TabTunnel.app "$OUT"
echo "Wrote $OUT"
