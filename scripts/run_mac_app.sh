#!/usr/bin/env bash
# Build dist/BetterWeb.app and launch it as a normal foreground Mac app.
# Logs: ~/Library/Logs/BetterWeb/{BetterWeb,sidecar}.log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build_mac_app.sh"

# Quit a running copy so the fresh build is what opens.
osascript -e 'tell application id "dev.betterweb.BetterWeb" to quit' >/dev/null 2>&1 || true
sleep 0.5

echo "→ Launching BetterWeb"
open "$ROOT/dist/BetterWeb.app"
echo "  Logs: ~/Library/Logs/BetterWeb/"
