#!/bin/bash
set -e
cd "$(dirname "$0")"

# Check vendor setup
if [ ! -d "vendor/onnxruntime" ]; then
    echo "ONNX Runtime not found. Running setup..."
    ./scripts/setup.sh
fi

swift build 2>&1

# Create/update app bundle (needed for dock icon + mic permission)
APP_DIR=".build/Magpi.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

cp Sources/Magpi/Info.plist "$APP_DIR/Contents/"
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"
cp .build/debug/Magpi "$APP_DIR/Contents/MacOS/"

# Copy SPM resource bundle (contains icon + menubar images)
if [ -d ".build/debug/Magpi_Magpi.bundle" ]; then
    cp -R .build/debug/Magpi_Magpi.bundle "$APP_DIR/Contents/Resources/" 2>/dev/null || true
    # Also copy icns to bundle root for CFBundleIconFile
    if [ -f ".build/debug/Magpi_Magpi.bundle/Resources/Magpi.icns" ]; then
        cp .build/debug/Magpi_Magpi.bundle/Resources/Magpi.icns "$APP_DIR/Contents/Resources/"
    fi
fi

# Copy ONNX Runtime into bundle
cp -f vendor/onnxruntime/lib/libonnxruntime.*.dylib "$APP_DIR/Contents/Frameworks/" 2>/dev/null || true

# Run from app bundle
export DYLD_LIBRARY_PATH="$APP_DIR/Contents/Frameworks:$(pwd)/vendor/onnxruntime/lib:${DYLD_LIBRARY_PATH:-}"
exec "$APP_DIR/Contents/MacOS/Magpi" "$@"
