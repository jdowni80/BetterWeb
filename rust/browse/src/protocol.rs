//! JSON-lines IPC between the Swift shell and the browse helper.
//!
//! Every tab owns one Servo `WebView`, addressed by the shell's tab id.

use serde::{Deserialize, Serialize};
use std::io::{self, Write};

#[derive(Debug, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    Ping,
    Shutdown,
    /// Create (or reuse) the WebView for `tab` and load `url`.
    Open { tab: String, url: String },
    Close { tab: String },
    /// Make `tab` the painted, focused WebView. `None` hides all WebViews.
    Activate { tab: Option<String> },
    Navigate { tab: String, url: String },
    GoBack { tab: String },
    GoForward { tab: String },
    Reload { tab: String },
    /// Absolute page zoom for the active tab (1.0 = 100%).
    Zoom { factor: f32 },
    SetBounds { width: u32, height: u32, scale: f32 },
    Focus,
    Blur,
    /// Pointer coordinates are device pixels relative to the content view's top-left.
    MouseMove { x: f32, y: f32 },
    MouseButton { x: f32, y: f32, button: i16, down: bool },
    MouseLeave,
    Wheel { x: f32, y: f32, dx: f64, dy: f64, pixels: bool },
    Key {
        down: bool,
        /// Printable text for character keys, or a DOM `NamedKey` name ("Enter", "ArrowLeft", …).
        key: String,
        named: bool,
        /// DOM `code` ("KeyA", "Enter", …) when known.
        code: Option<String>,
        shift: bool,
        ctrl: bool,
        alt: bool,
        meta: bool,
        repeat: bool,
    },
    Edit { action: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    Ready { engine: String, version: String },
    Pong,
    UrlChanged { tab: String, url: String },
    TitleChanged { tab: String, title: String },
    LoadStatus { tab: String, status: String },
    History { tab: String, can_go_back: bool, can_go_forward: bool },
    Cursor { cursor: String },
    StatusText { tab: String, text: Option<String> },
    Blocked { tab: String, total: u32, host: String },
    /// Buffer `index` of the shared frame ring now holds frame `seq`.
    Frame { path: String, index: u8, width: u32, height: u32, seq: u64 },
    NewTabRequest { opener: String, url: String },
    Error { message: String },
}

pub fn emit(event: &Event) {
    if let Ok(line) = serde_json::to_string(event) {
        let mut out = io::stdout().lock();
        let _ = writeln!(out, "{line}");
        let _ = out.flush();
    }
}
