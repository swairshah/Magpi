#!/bin/bash
set -e
cd "$(dirname "$0")"

# Check vendor setup
if [ ! -d "vendor/onnxruntime" ]; then
    echo "ONNX Runtime not found. Running setup..."
    ./scripts/setup.sh
fi

export MAGPI_LOG_LEVEL=debug
export DYLD_LIBRARY_PATH="$(pwd)/vendor/onnxruntime/lib:${DYLD_LIBRARY_PATH:-}"

# Set MAGPI_NO_AEC=1 to disable echo cancellation (voice processing)
# Useful if voice processing is causing issues with audio capture
# export MAGPI_NO_AEC=1

swift build 2>&1
exec .build/debug/Magpi "$@"
