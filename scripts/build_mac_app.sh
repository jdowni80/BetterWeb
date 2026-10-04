#!/usr/bin/env bash
# Build dist/BetterWeb.app: Swift chrome + Ladybird engine (LibWeb/LibJS + helpers).
# The app finds the Python CraftRank sidecar through Contents/Resources/repo-root.txt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/BetterWeb.app"
LADYBIRD_DIR="${LADYBIRD_DIR:-$HOME/Documents/GitHub/ladybird}"
LADYBIRD_BUILD="${LADYBIRD_BUILD_DIR:-$LADYBIRD_DIR/Build/release}"
HELPERS=(WebContent WebWorker Compositor ImageDecoder MediaServer RequestServer WasmCompiler ProcessReaper)
cd "$ROOT"

if [[ "${SKIP_PYTHON:-0}" != "1" ]]; then
  echo "→ Python search engine deps…"
  if [[ ! -x .venv/bin/python ]]; then
    python3 -m venv .venv
  fi
  .venv/bin/pip install -e . -q
fi

if [[ "${SKIP_LADYBIRD:-0}" != "1" ]]; then
  echo "→ Ladybird engine…"
  "$ROOT/scripts/build_ladybird_engine.sh"
fi

if [[ ! -f "$LADYBIRD_BUILD/lib/libBetterWebEngine.dylib" ]]; then
  echo "libBetterWebEngine.dylib missing at $LADYBIRD_BUILD/lib" >&2
  echo "Run scripts/build_ladybird_engine.sh first." >&2
  exit 1
fi

echo "→ Swift chrome (release)…"
(
  cd macos
  export LADYBIRD_BUILD_DIR="$LADYBIRD_BUILD"
  swift build -c release
)
BIN="$(cd macos && LADYBIRD_BUILD_DIR="$LADYBIRD_BUILD" swift build -c release --show-bin-path)/BetterWeb"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN" "$APP/Contents/MacOS/BetterWeb"

# Helpers must sit next to the executable (Ladybird looks in application_directory()).
HELPER_SRC="$LADYBIRD_BUILD/bin/Ladybird.app/Contents/MacOS"
for helper in "${HELPERS[@]}"; do
  if [[ -x "$HELPER_SRC/$helper" ]]; then
    cp -f "$HELPER_SRC/$helper" "$APP/Contents/MacOS/$helper"
  else
    echo "warning: helper $helper not found in $HELPER_SRC" >&2
  fi
done

# Dev-friendly: same layout Ladybird uses (Contents/lib → the Lagom dylibs).
ln -sfn "$LADYBIRD_BUILD/lib" "$APP/Contents/lib"

# Ladybird resources (themes, fonts, filter lists).
if [[ -d "$HELPER_SRC/../Resources" ]]; then
  rsync -a --delete \
    --exclude 'repo-root.txt' \
    --exclude 'app_icon.icns' \
    "$HELPER_SRC/../Resources/" "$APP/Contents/Resources/"
fi
printf '%s\n' "$ROOT" > "$APP/Contents/Resources/repo-root.txt"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BetterWeb</string>
  <key>CFBundleDisplayName</key><string>BetterWeb</string>
  <key>CFBundleIdentifier</key><string>dev.betterweb.BetterWeb</string>
  <key>CFBundleExecutable</key><string>BetterWeb</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web URL</string>
      <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Hardened runtime + library validation would reject Ladybird's ad-hoc Lagom dylibs
# (different Team IDs). Match Ladybird: disable library validation; JIT for renderers.
HELPER_ENTS=$(mktemp)
cat > "$HELPER_ENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
PLIST
JIT_ENTS=$(mktemp)
cat > "$JIT_ENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-jit</key><true/>
</dict></plist>
PLIST
for helper in "${HELPERS[@]}"; do
  if [[ -x "$APP/Contents/MacOS/$helper" ]]; then
    ents="$HELPER_ENTS"
    case "$helper" in WebContent|WebWorker|WasmCompiler) ents="$JIT_ENTS" ;; esac
    codesign --force --sign - --options runtime --entitlements "$ents" "$APP/Contents/MacOS/$helper" >/dev/null
  fi
done
codesign --force --sign - --options runtime --entitlements "$JIT_ENTS" "$APP/Contents/MacOS/BetterWeb" >/dev/null
codesign --force --sign - --entitlements "$HELPER_ENTS" "$APP" >/dev/null
rm -f "$HELPER_ENTS" "$JIT_ENTS"

echo "✓ Built $APP"
