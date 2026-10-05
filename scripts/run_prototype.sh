#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -x bin/lightpanda ]]; then
  echo "Downloading Lightpanda (macOS aarch64)…"
  mkdir -p bin
  curl -L -o bin/lightpanda \
    https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-aarch64-macos
  chmod a+x bin/lightpanda
fi

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -e . -q

if [[ ! -d web/node_modules ]]; then
  (cd web && npm install)
fi
(cd web && npm run build)

export LIGHTPANDA_DISABLE_TELEMETRY=true
echo "BetterWeb prototype → http://127.0.0.1:8742"
exec python -m betterweb.app.main
