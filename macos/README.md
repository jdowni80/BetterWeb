# BetterWeb Mac chrome

Native SwiftUI shell (Apheleia information architecture) for BetterWeb.

- Vertical tabs + omnibox + new-tab CraftRank search
- Page content from the Servo browse helper (RGBA frames) — **not** WKWebView
- Starts the Python search sidecar on `127.0.0.1:8742`

## Dev run

From the repo root:

```bash
./scripts/run_mac_app.sh
```

Or manually:

```bash
export BETTERWEB_ROOT="$PWD"
export BETTERWEB_BROWSE="$PWD/rust/browse/target/release/betterweb-browse"
cd macos && swift run -c release BetterWeb
```
