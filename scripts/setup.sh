#!/bin/bash
#
# Downloads ONNX Runtime (C API) and VAD/Smart Turn ONNX models.
# Run once before building:  ./scripts/setup.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

ONNX_VERSION="1.19.2"
ARCH="$(uname -m)"  # arm64 or x86_64

VENDOR_DIR="vendor/onnxruntime"
MODELS_DIR="Resources/models"

# ── ONNX Runtime ─────────────────────────────────────────────
if [ -f "$VENDOR_DIR/lib/libonnxruntime.dylib" ]; then
    echo "✓ ONNX Runtime already downloaded"
else
    echo "⤓ Downloading ONNX Runtime v${ONNX_VERSION} (${ARCH})..."
    
    if [ "$ARCH" = "arm64" ]; then
        ONNX_URL="https://github.com/microsoft/onnxruntime/releases/download/v${ONNX_VERSION}/onnxruntime-osx-arm64-${ONNX_VERSION}.tgz"
    else
        ONNX_URL="https://github.com/microsoft/onnxruntime/releases/download/v${ONNX_VERSION}/onnxruntime-osx-x86_64-${ONNX_VERSION}.tgz"
    fi
    
    TMP_DIR=$(mktemp -d)
    trap "rm -rf $TMP_DIR" EXIT
    
    curl -fSL "$ONNX_URL" -o "$TMP_DIR/onnxruntime.tgz"
    tar xzf "$TMP_DIR/onnxruntime.tgz" -C "$TMP_DIR"
    
    # Find extracted directory
    EXTRACTED=$(find "$TMP_DIR" -maxdepth 1 -type d -name "onnxruntime-*" | head -1)
    
    mkdir -p "$VENDOR_DIR/lib" "$VENDOR_DIR/include"
    cp -R "$EXTRACTED/lib/"* "$VENDOR_DIR/lib/"
    cp -R "$EXTRACTED/include/"* "$VENDOR_DIR/include/"
    
    # Copy the main header into our C module so SPM can find it
    cp "$VENDOR_DIR/include/onnxruntime_c_api.h" "Sources/COnnxRuntime/include/"
    
    echo "✓ ONNX Runtime installed to $VENDOR_DIR"
fi

# ── Silero VAD ───────────────────────────────────────────────
if [ -f "$MODELS_DIR/silero_vad.onnx" ]; then
    echo "✓ Silero VAD model already downloaded"
else
    echo "⤓ Downloading Silero VAD model..."
    mkdir -p "$MODELS_DIR"
    curl -fSL "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx" \
        -o "$MODELS_DIR/silero_vad.onnx"
    echo "✓ Silero VAD model saved to $MODELS_DIR/silero_vad.onnx"
fi

# ── Smart Turn v3.2 ─────────────────────────────────────────
if [ -f "$MODELS_DIR/smart-turn-v3.2-cpu.onnx" ]; then
    echo "✓ Smart Turn model already downloaded"
else
    echo "⤓ Downloading Smart Turn v3.2 CPU model..."
    mkdir -p "$MODELS_DIR"
    curl -fSL "https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/main/smart-turn-v3.2-cpu.onnx" \
        -o "$MODELS_DIR/smart-turn-v3.2-cpu.onnx"
    echo "✓ Smart Turn model saved to $MODELS_DIR/smart-turn-v3.2-cpu.onnx"
fi

echo ""
echo "Setup complete! You can now build with: swift build"
