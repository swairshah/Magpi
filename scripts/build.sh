#!/bin/bash
#
# Build a release binary
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Ensure setup is done
if [ ! -d "vendor/onnxruntime" ]; then
    echo "Run scripts/setup.sh first"
    exit 1
fi

echo "Building Magpi (release)..."
swift build -c release 2>&1

BINARY=".build/release/Magpi"
echo "✓ Built: $BINARY"
echo "  Size: $(du -h "$BINARY" | cut -f1)"

# Copy ONNX Runtime dylib next to binary for @rpath resolution
mkdir -p ".build/release/lib"
cp vendor/onnxruntime/lib/libonnxruntime*.dylib .build/release/lib/

echo "✓ ONNX Runtime dylib copied to .build/release/lib/"
echo ""
echo "Run with: .build/release/Magpi"
