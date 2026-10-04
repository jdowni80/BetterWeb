# betterweb-browse

Out-of-process **Servo** (`libservo`) helper for BetterWeb.app.

- No Chromium, no WKWebView
- JSON-lines commands on stdin, events on stdout
- Paints via `SoftwareRenderingContext`, writes RGBA frames to `BETTERWEB_FRAME_PATH`

## Build

```bash
unset CARGO_TARGET_DIR
export CARGO_TARGET_DIR="$PWD/target"
cargo build --release
```

## Protocol (examples)

```json
{"cmd":"navigate","url":"https://example.com"}
{"cmd":"set_bounds","width":1280,"height":800,"scale":2.0}
{"cmd":"go_back"}
{"cmd":"reload"}
{"cmd":"shutdown"}
```

Events include `ready`, `url_changed`, `title_changed`, `frame`, `load_status`, `error`.
