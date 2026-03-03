#!/bin/bash
set -e
cd "$(dirname "$0")"

# Check vendor setup
if [ ! -d "vendor/onnxruntime" ]; then
    echo "ONNX Runtime not found. Running setup..."
    ./scripts/setup.sh
fi

# Build
swift build 2>&1

# Create app bundle (needed for macOS mic permission prompt)
APP_DIR=".build/Magpi.app"
if [ ! -d "$APP_DIR" ]; then
    echo "Creating app bundle..."
    mkdir -p "$APP_DIR/Contents/MacOS"
    mkdir -p "$APP_DIR/Contents/Resources"
    cp Sources/Magpi/Info.plist "$APP_DIR/Contents/"
    echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"
    # Copy icon if available
    if [ -f ".build/debug/Magpi_Magpi.bundle/Resources/Magpi.icns" ]; then
        cp .build/debug/Magpi_Magpi.bundle/Resources/Magpi.icns "$APP_DIR/Contents/Resources/"
    fi
fi

# Update binary + resources in app bundle
cp .build/debug/Magpi "$APP_DIR/Contents/MacOS/"
# Copy SPM resource bundle
if [ -d ".build/debug/Magpi_Magpi.bundle" ]; then
    cp -R .build/debug/Magpi_Magpi.bundle "$APP_DIR/Contents/Resources/" 2>/dev/null || true
fi
# Copy ONNX Runtime into bundle
mkdir -p "$APP_DIR/Contents/Frameworks"
cp -f vendor/onnxruntime/lib/libonnxruntime.*.dylib "$APP_DIR/Contents/Frameworks/" 2>/dev/null || true

# Set MAGPI_NO_AEC=1 to disable echo cancellation (voice processing)
# export MAGPI_NO_AEC=1

# Run from app bundle with ONNX Runtime in library path
export MAGPI_LOG_LEVEL=debug
export DYLD_LIBRARY_PATH="$APP_DIR/Contents/Frameworks:$(pwd)/vendor/onnxruntime/lib:${DYLD_LIBRARY_PATH:-}"
exec "$APP_DIR/Contents/MacOS/Magpi" "$@"
