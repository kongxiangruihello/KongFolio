#!/bin/bash
# Build first with scripts/build.sh. Package the verified app into a drag-install disk image.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
APP="$ROOT/../KongFolio.app"
OUTPUT="${1:-$ROOT/../KongFolio-$VERSION-arm64.dmg}"
codesign --verify --deep --strict "$APP"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/kongfolio-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto --norsrc --noextattr "$APP" "$STAGING/KongFolio.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "KongFolio $VERSION" -srcfolder "$STAGING" -format UDZO -ov "$OUTPUT"
hdiutil verify "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
printf 'Created and verified: %s\n' "$OUTPUT"
