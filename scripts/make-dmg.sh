#!/bin/bash
# Builds QuadCastControl (Release) and packages it into a drag-to-install DMG.
#
# Usage:  scripts/make-dmg.sh [version]
# Output: dist/QuadCastControl-<version>.dmg
#
# Signing: by default the app is ad-hoc signed ("Sign to Run Locally").
# For public distribution set SIGN_IDENTITY to a "Developer ID Application"
# certificate identity and (optionally) notarize the DMG afterwards:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/make-dmg.sh 1.0.0
#   xcrun notarytool submit dist/QuadCastControl-1.0.0.dmg --keychain-profile <profile> --wait
#   xcrun stapler staple dist/QuadCastControl-1.0.0.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc
BUILD_DIR="$(mktemp -d)"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR" "$STAGE_DIR"' EXIT

echo "==> Running unit tests"
(cd QuadCastKit && swift test)

echo "==> Building Release (arm64)"
xcodebuild -project QuadCastControl.xcodeproj \
  -scheme QuadCastControl \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  build

APP="$BUILD_DIR/Build/Products/Release/QuadCastControl.app"
test -d "$APP" || { echo "error: app not found at $APP" >&2; exit 1; }

echo "==> Verifying code signature"
codesign --verify --deep "$APP"

echo "==> Staging DMG contents"
cp -R "$APP" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

mkdir -p dist
DMG="dist/QuadCastControl-$VERSION.dmg"
rm -f "$DMG"

echo "==> Creating $DMG"
hdiutil create \
  -volname "QuadCast Control" \
  -srcfolder "$STAGE_DIR" \
  -ov -format UDZO \
  "$DMG" >/dev/null

echo "==> Done:"
du -h "$DMG"
