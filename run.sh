#!/bin/bash
set -e
cd "$(dirname "$0")"

# Check vendor setup
if [ ! -d "vendor/onnxruntime" ]; then
    echo "ONNX Runtime not found. Running setup..."
    ./scripts/setup.sh
fi

swift build 2>&1
exec .build/debug/Magpi "$@"
