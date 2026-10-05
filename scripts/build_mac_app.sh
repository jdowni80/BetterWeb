#!/usr/bin/env bash
# Build dist/BetterWeb.app: Swift chrome + Python CraftRank sidecar.
# The app finds the repo through Contents/Resources/repo-root.txt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/BetterWeb.app"
cd "$ROOT"

if [[ "${SKIP_PYTHON:-0}" != "1" ]]; then
  echo "→ Python search engine deps…"
  if [[ ! -x .venv/bin/python ]]; then
    python3 -m venv .venv
  fi
  .venv/bin/pip install -e ".[crawl]" -q
fi

echo "→ Swift chrome (release)…"
(
  cd macos
  swift build -c release
)
BIN="$(cd macos && swift build -c release --show-bin-path)/BetterWeb"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN" "$APP/Contents/MacOS/BetterWeb"
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
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/MacOS/BetterWeb" >/dev/null
codesign --force --sign - "$APP" >/dev/null
echo "✓ Built $APP"
