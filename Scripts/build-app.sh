#!/bin/bash
# Build script for keyflash.app
# Usage: ./Scripts/build-app.sh [debug|release]

set -euo pipefail

BUILD_MODE="${1:-release}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/$BUILD_MODE"
APP_DIR="$BUILD_DIR/keyflash.app"

echo "🏗️  Building keyflash ($BUILD_MODE)..."
swift build -c "$BUILD_MODE"

echo "📦 Creating keyflash.app bundle..."

# Create .app directory structure
mkdir -p "$APP_DIR/Contents/MacOS"

# Compile mac-brightnessctl from source
echo "🔨 Compiling mac-brightnessctl..."
make -C "$PROJECT_DIR/Scripts/mac-brightnessctl" clean
make -C "$PROJECT_DIR/Scripts/mac-brightnessctl"

# Copy binaries
cp "$BUILD_DIR/keyflash" "$APP_DIR/Contents/MacOS/keyflash"
cp "$BUILD_DIR/keyflash-run" "$APP_DIR/Contents/MacOS/keyflash-run"
cp "$PROJECT_DIR/Scripts/mac-brightnessctl/mac-brightnessctl" "$APP_DIR/Contents/MacOS/mac-brightnessctl"

# Create Resources directory and copy app icon
mkdir -p "$APP_DIR/Contents/Resources"
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
echo "   PTY wrapper CLI : $APP_DIR/Contents/MacOS/keyflash-run"
echo ""

# Register with Launch Services so `open` finds the latest version
if [ -d "$APP_DIR" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true
    echo "📝 Registered with Launch Services"
fi

echo ""
echo "To run: open $APP_DIR"
echo "To wrap: alias claude='$APP_DIR/Contents/MacOS/keyflash-run -- claude'"
