#!/bin/bash
set -euo pipefail

# Build, sign, notarize, and package Dialogue.app as a DMG.
#
# The Xcode project has per-target signing: Debug uses Automatic (development),
# Release uses Manual with Developer ID + provisioning profile. SPM targets
# stay Automatic and don't get the provisioning profile applied.
#
# Prerequisites:
#   1. "Developer ID Application" certificate + private key in your keychain
#   2. "Dialogue" provisioning profile installed
#   3. Notarization credentials stored via:
#      xcrun notarytool store-credentials "notarytool" \
#        --apple-id YOUR_EMAIL --team-id 8H548FVL95 --password APP_SPECIFIC_PASSWORD
#   4. create-dmg installed: brew install create-dmg

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SCRIPT_DIR/Dialogue.xcodeproj"
SCHEME="Dialogue"
BUILD_DIR="$SCRIPT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Dialogue.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
VERSION="${1:-dev}"
BUILD_NUMBER="${2:-$(date +%s)}"

echo "==> Cleaning build directory"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$BUILD_DIR" "$EXPORT_PATH"

echo "==> Archiving ($VERSION, build $BUILD_NUMBER)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  ARCHS=arm64 \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  | xcbeautify 2>/dev/null || true

# Verify archive was created
if [ ! -d "$ARCHIVE_PATH" ]; then
  echo "error: Archive failed — $ARCHIVE_PATH not found"
  exit 1
fi

echo "==> Copying signed app from archive"
cp -R "$ARCHIVE_PATH/Products/Applications/Dialogue.app" "$EXPORT_PATH/Dialogue.app"
codesign --verify --deep --strict "$EXPORT_PATH/Dialogue.app"
echo "  Signature valid"

echo "==> Notarizing app"
ditto -c -k --keepParent "$EXPORT_PATH/Dialogue.app" "$BUILD_DIR/Dialogue-notarize.zip"
xcrun notarytool submit "$BUILD_DIR/Dialogue-notarize.zip" \
  --keychain-profile "notarytool" \
  --wait --timeout 15m
rm "$BUILD_DIR/Dialogue-notarize.zip"

echo "==> Stapling app"
xcrun stapler staple "$EXPORT_PATH/Dialogue.app"

echo "==> Creating DMG"
DMG_PATH="$EXPORT_PATH/Dialogue-${VERSION}.dmg"
rm -f "$DMG_PATH"

create-dmg \
  --volname "Dialogue" \
  --volicon "$EXPORT_PATH/Dialogue.app/Contents/Resources/AppIcon.icns" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 100 \
  --icon "Dialogue.app" 180 190 \
  --hide-extension "Dialogue.app" \
  --app-drop-link 480 190 \
  --no-internet-enable \
  "$DMG_PATH" \
  "$EXPORT_PATH/Dialogue.app" \
|| test $? -eq 2

echo "==> Signing DMG"
codesign --force --sign "Developer ID Application: Michael Moore (8H548FVL95)" \
  --timestamp "$DMG_PATH"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "notarytool" \
  --wait --timeout 15m

echo "==> Stapling DMG"
xcrun stapler staple "$DMG_PATH"

echo ""
echo "Done! DMG ready at:"
echo "  $DMG_PATH"
