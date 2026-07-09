#!/bin/zsh
# Build "AiGrammar.app" from the SwiftPM product.
# Usage: Scripts/build-app.sh [debug|release]
#
# Sign with a STABLE identity so the Accessibility (TCC) grant persists across rebuilds —
# with ad-hoc signing macOS treats every rebuild as a new app and drops the permission.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Stamp build identity (git short hash + dirty flag + date) into BuildInfo.swift so the running app
# can show which build it is. The dirty check ignores the generated BuildInfo.swift itself.
HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")
if [ -n "$(git status --porcelain -uno -- . ':!Sources/AiGrammar/BuildInfo.swift' 2>/dev/null)" ]; then
    DIRTY="+dirty"
else
    DIRTY=""
fi
COMMIT="$HASH$DIRTY"
DATE="$(date '+%Y-%m-%d %H:%M')"
STAMP="$COMMIT · $DATE"
cat > Sources/AiGrammar/BuildInfo.swift <<EOF
/// Build identity, stamped by Scripts/build-app.sh. Do not edit by hand.
enum BuildInfo {
    static let commit = "$COMMIT"
    static let date = "$DATE"
    static let version = "$STAMP"
}
EOF
echo "==> stamped BuildInfo = $STAMP"

swift build -c "$CONFIG"

BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/AiGrammar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/AiGrammar" "$APP/Contents/MacOS/AiGrammar"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/App/AppIcon.icns" ]] && cp "$ROOT/App/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# The (N) glob qualifier = "expand to nothing if no match" (instead of a fatal error under set -e).
setopt NULL_GLOB

# Embed llama.cpp's llama-server (+ its dylibs) so local GGUF models run with no separate install.
# Provided by Scripts/fetch-llama.sh into vendor/llama.cpp/bundle. Optional — skipped if absent.
LLAMA_SRC="$ROOT/vendor/llama.cpp/bundle"
if [[ -x "$LLAMA_SRC/llama-server" ]]; then
  DEST="$APP/Contents/Resources/llama"
  mkdir -p "$DEST"
  cp "$LLAMA_SRC/llama-server" "$DEST/"
  for lib in "$LLAMA_SRC/"*.dylib "$LLAMA_SRC/"*.metallib; do cp "$lib" "$DEST/"; done
  # The binary must find its sibling dylibs inside the bundle.
  install_name_tool -add_rpath "@loader_path" "$DEST/llama-server" 2>/dev/null || true
  echo "==> embedded llama-server from vendor/llama.cpp/bundle"
else
  echo "==> (no vendored llama-server; run Scripts/fetch-llama.sh to embed it, or the app will use a system/brew llama-server)"
fi

# Prefer a stable identity (so TCC/Accessibility permission persists across rebuilds), most-trusted
# first. Override with CODESIGN_IDENTITY=...
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  for pat in "Developer ID Application" "Apple Development" "AiGrammar Self-Signed" "VRDesktop Self-Signed"; do
    IDENTITY="$(security find-identity -p codesigning 2>/dev/null \
      | awk -F'"' -v p="$pat" '$0 ~ p {print $2; exit}')"
    [[ -n "$IDENTITY" ]] && break
  done
fi

SIGN=("--force" "--sign" "-")                                   # ad-hoc by default
[[ -n "${IDENTITY:-}" ]] && SIGN=("--force" "--sign" "$IDENTITY")

# Sign nested code (embedded llama-server + dylibs) FIRST, so the outer app signature covers them.
if [[ -d "$APP/Contents/Resources/llama" ]]; then
  for f in "$APP/Contents/Resources/llama/"*.dylib "$APP/Contents/Resources/llama/"*.metallib \
           "$APP/Contents/Resources/llama/llama-server"; do
    codesign "${SIGN[@]}" "$f"
  done
fi

# Sign the app with a STABLE identifier so its designated requirement is constant across rebuilds.
codesign "${SIGN[@]}" --identifier io.github.dripster82.AiGrammar "$APP"
if [[ -n "${IDENTITY:-}" ]]; then
  echo "Signed with: $IDENTITY"
else
  echo "Ad-hoc signed — Accessibility permission will NOT survive rebuilds; create a self-signed cert."
fi

# Fail loudly if the signature is broken (this is what silently regressed and reset Accessibility).
if ! codesign --verify --strict "$APP" 2>/dev/null; then
  echo "✗ codesign --verify FAILED — Accessibility permission will reset every build."; exit 1
fi
echo "==> signature OK ($(codesign -dvv "$APP" 2>&1 | grep -E 'Identifier=|Authority=' | head -2 | tr '\n' ' '))"

echo "Built: $APP"
echo "Run:   open '$APP'"
