#!/bin/zsh
# Fetch llama.cpp's llama-server so AiGrammar can EMBED it (Contents/Resources/llama) and run local
# GGUF models with no separate install. Downloads the prebuilt macOS release (fast, no build), and
# falls back to building from source. Output lands in vendor/llama.cpp/bundle, which build-app.sh
# copies into the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$ROOT/vendor/llama.cpp/bundle"
mkdir -p "$BUNDLE"

ARCH="$(uname -m)"   # arm64 or x86_64
ASSET_MATCH="macos-${ARCH}"
[[ "$ARCH" == "x86_64" ]] && ASSET_MATCH="macos-x64"

echo "==> finding latest llama.cpp release asset for $ASSET_MATCH…"
API="https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
URL="$(curl -fsSL "$API" | grep -o '"browser_download_url": *"[^"]*"' \
        | cut -d'"' -f4 | grep -i "$ASSET_MATCH" | head -1 || true)"

if [[ -n "$URL" ]]; then
  echo "==> downloading $URL"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/x"
  case "$URL" in
    *.tar.gz|*.tgz) curl -fL "$URL" -o "$TMP/llama.tgz"; tar -xzf "$TMP/llama.tgz" -C "$TMP/x" ;;
    *.zip)          curl -fL "$URL" -o "$TMP/llama.zip"; unzip -oq "$TMP/llama.zip" -d "$TMP/x" ;;
    *)              echo "✗ unknown archive type: $URL"; exit 1 ;;
  esac
  # Releases nest the binaries under build/bin (or similar) — gather what we need, flat.
  find "$TMP/x" \( -name 'llama-server' -o -name '*.dylib' -o -name '*.metallib' \) \
       -exec cp {} "$BUNDLE/" \;
  chmod +x "$BUNDLE/llama-server" 2>/dev/null || true
else
  echo "==> no prebuilt asset found; building from source (needs cmake)…"
  SRC="$ROOT/vendor/llama.cpp/src"
  [[ -d "$SRC" ]] || git clone https://github.com/ggml-org/llama.cpp.git "$SRC"
  cmake -S "$SRC" -B "$SRC/build" -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_CURL=OFF
  cmake --build "$SRC/build" --config Release --target llama-server -j 4
  find "$SRC/build/bin" \( -name 'llama-server' -o -name '*.dylib' \) -exec cp {} "$BUNDLE/" \;
fi

if [[ -x "$BUNDLE/llama-server" ]]; then
  echo ""
  echo "============================================================"
  echo "llama-server ready in vendor/llama.cpp/bundle."
  echo "Now rebuild to embed it in the app:  Scripts/build-app.sh"
  echo "Then in AiGrammar → AI Models, download the GGUF model and click Use."
  echo "============================================================"
else
  echo "✗ could not obtain llama-server"; exit 1
fi
