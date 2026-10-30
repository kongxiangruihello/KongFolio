#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Info.plist is the single source of the version number (the app reads it at runtime too).
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swift-cache"
swift build --build-system native --disable-sandbox --package-path "$ROOT" -c release
BIN="$(swift build --build-system native --disable-sandbox --package-path "$ROOT" -c release --show-bin-path)"
# Assemble outside cloud-synced folders so Finder metadata cannot invalidate signing.
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/kongfolio-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/KongFolio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Helpers"
cp "$BIN/KongFolio" "$APP/Contents/MacOS/KongFolio"
cp "$BIN/KongFolioUpdater" "$APP/Contents/Helpers/KongFolioUpdater"
codesign --force --sign - --identifier com.kongfolio.updater "$APP/Contents/Helpers/KongFolioUpdater"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
# A bundle without localization folders gets English standard menus (File, Edit, View…) even on a Chinese system.
for language in zh-Hans en; do
    mkdir -p "$APP/Contents/Resources/$language.lproj"
    printf '"CFBundleName" = "KongFolio";\n' > "$APP/Contents/Resources/$language.lproj/InfoPlist.strings"
done
swift "$ROOT/scripts/Icon.swift" "$ROOT/.build/KongFolio.iconset"
iconutil -c icns "$ROOT/.build/KongFolio.iconset" -o "$APP/Contents/Resources/KongFolio.icns"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto --norsrc --noextattr "$APP" "$ROOT/../KongFolio.app"
xattr -d com.apple.FinderInfo "$ROOT/../KongFolio.app" 2>/dev/null || true
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ROOT/../KongFolio-$VERSION-macOS.zip"
printf 'Built and verified: %s\n' "$ROOT/../KongFolio-$VERSION-macOS.zip"
