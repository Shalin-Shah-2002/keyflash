#!/bin/bash
# Build keyflash.dmg disk image
# Usage: ./Scripts/build-dmg.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_PATH="$BUILD_DIR/keyflash.app"
DMG_PATH="$BUILD_DIR/keyflash.dmg"
STAGING_DIR="$BUILD_DIR/dmg-staging"

# Ensure the .app exists
if [ ! -d "$APP_PATH" ]; then
    echo "❌ keyflash.app not found. Run ./Scripts/build-app.sh first."
    exit 1
fi

echo "🗜️  Creating keyflash.dmg..."

# Clean up any previous staging
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy app into staging
cp -R "$APP_PATH" "$STAGING_DIR/keyflash.app"

# Create Applications symlink
ln -s /Applications "$STAGING_DIR/Applications"

# Build the DMG
rm -f "$DMG_PATH"
hdiutil create \
    -volname "keyflash" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

# Clean up staging
rm -rf "$STAGING_DIR"

echo "✅ DMG created at: $DMG_PATH"
echo "   Size: $(du -h "$DMG_PATH" | cut -f1)"
ls -lh "$DMG_PATH"
