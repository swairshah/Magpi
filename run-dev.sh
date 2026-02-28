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

swift build 2>&1
exec .build/debug/Magpi "$@"
