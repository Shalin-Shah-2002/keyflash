#!/bin/bash
# Build script for keyflash.app
# Usage: ./Scripts/build-app.sh [debug|release]
#
# Release builds are universal (Apple Silicon + Intel); debug builds are for
# the host architecture only.

set -euo pipefail

BUILD_MODE="${1:-release}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/.build/$BUILD_MODE/keyflash.app"

if [ "$BUILD_MODE" = "release" ]; then
    SWIFT_ARGS=(-c release --arch arm64 --arch x86_64)
    MAKE_ARCHS="-arch arm64 -arch x86_64"
else
    SWIFT_ARGS=(-c debug)
    MAKE_ARCHS="-arch $(uname -m)"
fi

echo "🏗️  Building keyflash ($BUILD_MODE)..."
cd "$PROJECT_DIR"
swift build "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

echo "📦 Creating keyflash.app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# Compile mac-brightnessctl from source
echo "🔨 Compiling mac-brightnessctl..."
make -C "$PROJECT_DIR/Scripts/mac-brightnessctl" clean
make -C "$PROJECT_DIR/Scripts/mac-brightnessctl" ARCHS="$MAKE_ARCHS"

# Copy binaries
cp "$BIN_DIR/keyflash" "$APP_DIR/Contents/MacOS/keyflash"
cp "$BIN_DIR/keyflash-run" "$APP_DIR/Contents/MacOS/keyflash-run"
cp "$PROJECT_DIR/Scripts/mac-brightnessctl/mac-brightnessctl" "$APP_DIR/Contents/MacOS/mac-brightnessctl"

# App icon + menu bar icon
cp "$PROJECT_DIR/Assets/KeyFlash_Logo.icns" "$APP_DIR/Contents/Resources/"
cp "$PROJECT_DIR/Assets/KeyFlash_MenuIcon.png" "$APP_DIR/Contents/Resources/"

# Copy Info.plist
cp "$PROJECT_DIR/Scripts/keyflash-Info.plist" "$APP_DIR/Contents/Info.plist"

# Sign with ad-hoc signature (required for macOS)
codesign --force --sign - "$APP_DIR/Contents/MacOS/keyflash"
codesign --force --sign - "$APP_DIR/Contents/MacOS/keyflash-run"
codesign --force --sign - "$APP_DIR/Contents/MacOS/mac-brightnessctl"
codesign --force --sign - "$APP_DIR"

echo "✅ keyflash.app created at: $APP_DIR"
echo "   Binary          : $APP_DIR/Contents/MacOS/keyflash"
echo "   Helper CLI      : $APP_DIR/Contents/MacOS/keyflash-run"
lipo -info "$APP_DIR/Contents/MacOS/keyflash" "$APP_DIR/Contents/MacOS/mac-brightnessctl" || true
echo ""

# Register with Launch Services so `open` finds the latest version
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true

echo ""
echo "To run: open $APP_DIR"
echo "Agent hooks (Claude Code / OpenCode) install automatically when the app launches,"
echo "or run: $APP_DIR/Contents/MacOS/keyflash-run --install-hooks"
