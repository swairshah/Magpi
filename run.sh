#!/bin/bash
set -e
cd "$(dirname "$0")"

# Check vendor setup
if [ ! -d "vendor/onnxruntime" ]; then
    echo "ONNX Runtime not found. Running setup..."
    ./scripts/setup.sh
fi

swift build 2>&1

# ONNX Runtime must be on the library path
export DYLD_LIBRARY_PATH="$(pwd)/vendor/onnxruntime/lib:${DYLD_LIBRARY_PATH:-}"
exec .build/debug/Magpi "$@"
