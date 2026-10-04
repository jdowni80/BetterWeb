#!/usr/bin/env bash
# Build Ladybird's engine (LibWeb/LibJS/LibWebView + helper processes) and libBetterWebEngine.
#
# Ladybird lives in its own checkout (LADYBIRD_DIR, default ~/Documents/GitHub/ladybird). We hook our
# bridge into its CMake tree with a one-line, idempotent patch so it links the exact libraries the
# helper processes were built against.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LADYBIRD_DIR="${LADYBIRD_DIR:-$HOME/Documents/GitHub/ladybird}"
ENGINE_DIR="$ROOT/engine/ladybird"
BUILD_DIR="$LADYBIRD_DIR/Build/release"

if [[ ! -d "$LADYBIRD_DIR/Meta" ]]; then
  echo "→ Cloning Ladybird into $LADYBIRD_DIR"
  git clone --depth 1 https://github.com/LadybirdBrowser/ladybird.git "$LADYBIRD_DIR"
fi

# 1. Hook: add_subdirectory(${BETTERWEB_ENGINE_DIR}) right after Ladybird's own UI.
if ! grep -q "BETTERWEB_ENGINE_DIR" "$LADYBIRD_DIR/CMakeLists.txt"; then
  echo "→ Patching Ladybird CMakeLists.txt"
  python3 - "$LADYBIRD_DIR/CMakeLists.txt" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = "    add_subdirectory(UI)\n"
hook = (
    needle
    + "    if (BETTERWEB_ENGINE_DIR)\n"
    + "        add_subdirectory(\"${BETTERWEB_ENGINE_DIR}\" BetterWebEngine)\n"
    + "    endif()\n"
)
if needle not in text:
    sys.exit("Ladybird CMakeLists.txt layout changed; cannot find add_subdirectory(UI)")
path.write_text(text.replace(needle, hook, 1))
PY
fi

cd "$LADYBIRD_DIR"

# 2. First build configures everything (vcpkg deps take a long while the first time).
if [[ ! -f "$BUILD_DIR/CMakeCache.txt" ]]; then
  echo "→ First Ladybird configure + build (this downloads and compiles all dependencies)…"
  ./Meta/ladybird.py build
fi

# 3. Point the existing cache at our bridge. A raw `cmake -S -B` without Ladybird's preset
#    loses OBJCXX; writing the cache entry lets the next ninja configure pick it up.
if ! grep -q "^BETTERWEB_ENGINE_DIR:.*=$ENGINE_DIR\$" "$BUILD_DIR/CMakeCache.txt"; then
  echo "→ Registering BetterWeb engine bridge with Ladybird's build"
  {
    echo "BETTERWEB_ENGINE_DIR:PATH=$ENGINE_DIR"
  } >> "$BUILD_DIR/CMakeCache.txt"
fi

echo "→ Building Ladybird helpers + libBetterWebEngine…"
# WebContent/WebWorker/MediaServer are the media path. ladybird is the Qt shell whose
# bundle directory is where CMake drops the helpers; we copy them into BetterWeb.app.
./Meta/ladybird.py build WebContent WebWorker ladybird BetterWebEngine

echo "✓ Engine: $BUILD_DIR/lib/libBetterWebEngine.dylib"
