//! Servo (libservo) embed: one `WebView` per shell tab, software-rendered,
//! frames handed to the Swift shell through a memory-mapped double buffer.

use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    fs::OpenOptions,
    path::{Path, PathBuf},
    rc::Rc,
    str::FromStr,
    time::{Duration, Instant},
};

use dpi::PhysicalSize;
use euclid::{default::Point2D, Scale};
use memmap2::MmapMut;
use servo::{
    Code, Cursor, DeviceIntRect, DevicePoint, EditingActionEvent, InputEvent, Key, KeyState,
    KeyboardEvent, LoadStatus, Location, Modifiers, MouseButton, MouseButtonAction,
    MouseButtonEvent, MouseLeftViewportEvent, MouseMoveEvent, NamedKey, NavigationRequest, Opts,
    RenderingContext, Servo, ServoBuilder, ServoDelegate, ServoError, SoftwareRenderingContext,
    Theme, UserContentManager, UserScript, WebResourceLoad, WebResourceResponse, WebView,
    WebViewBuilder, WebViewDelegate, WheelDelta, WheelEvent, WheelMode,
};
use url::Url;

use crate::blocklist::Blocklist;
use crate::protocol::{emit, Event};

const RESIZE_DEBOUNCE: Duration = Duration::from_millis(60);
const FRAME_MAGIC: u32 = u32::from_le_bytes(*b"BWF1");
/// magic u32, width u32, height u32, reserved u32, seq u64.
const FRAME_HEADER: usize = 24;

/// Servo has no Media Source Extensions, so YouTube's in-page player can never play.
/// The shell plays the stream natively above the page; collapse the dead player here.
/// YouTube serves its ads first-party, so host blocking misses them; hide their slots.
/// `:has()` sits in its own rule so an engine without it doesn't drop the others.
const YOUTUBE_PLAYER_SCRIPT: &str = r#"(function () {
  if (!/(^|\.)youtube\.com$/.test(location.hostname)) return;
  var css = "ytd-watch-flexy #player, ytd-watch-flexy #player-container-outer," +
    " ytd-watch-flexy #full-bleed-container, ytd-watch-flexy #player-full-bleed-container" +
    " { display: none !important; }\n" +
    "ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-display-ad-renderer," +
    " ytd-promoted-sparkles-web-renderer, ytd-promoted-video-renderer, ytd-companion-slot-renderer," +
    " ytd-banner-promo-renderer, ytd-statement-banner-renderer, ytd-player-legacy-desktop-watch-ads-renderer," +
    " #masthead-ad, #player-ads, #panels > ytd-engagement-panel-section-list-renderer[target-id=engagement-panel-ads]" +
    " { display: none !important; }\n" +
    "ytd-rich-item-renderer:has(ytd-ad-slot-renderer) { display: none !important; }";
  function add() {
    if (document.getElementById("betterweb-native-media")) return;
    var root = document.head || document.documentElement;
    if (!root) return;
    var style = document.createElement("style");
    style.id = "betterweb-native-media";
    style.textContent = css;
    root.appendChild(style);
  }
  add();
  document.addEventListener("DOMContentLoaded", add);
})();"#;

/// State shared by every tab's delegate.
struct Shared {
    needs_paint: Cell<bool>,
    active: RefCell<Option<String>>,
    blocklist: Blocklist,
    blocked: RefCell<HashMap<String, u32>>,
    /// Throwaway popup WebViews kept alive until their first navigation is captured.
    popups: RefCell<Vec<WebView>>,
    rendering_context: Rc<dyn RenderingContext>,
}

impl Shared {
    fn is_active(&self, tab: &str) -> bool {
        self.active.borrow().as_deref() == Some(tab)
    }
}

struct TabDelegate {
    tab: String,
    shared: Rc<Shared>,
}

impl WebViewDelegate for TabDelegate {
    fn notify_new_frame_ready(&self, _webview: WebView) {
        if self.shared.is_active(&self.tab) {
            self.shared.needs_paint.set(true);
        }
    }

    fn notify_url_changed(&self, _webview: WebView, url: Url) {
        emit(&Event::UrlChanged {
            tab: self.tab.clone(),
            url: url.to_string(),
        });
    }

    fn notify_page_title_changed(&self, _webview: WebView, title: Option<String>) {
        emit(&Event::TitleChanged {
            tab: self.tab.clone(),
            title: title.unwrap_or_default(),
        });
    }

    fn notify_load_status_changed(&self, _webview: WebView, status: LoadStatus) {
        emit(&Event::LoadStatus {
            tab: self.tab.clone(),
            status: format!("{status:?}"),
        });
    }

    fn notify_history_changed(&self, _webview: WebView, entries: Vec<Url>, current: usize) {
        emit(&Event::History {
            tab: self.tab.clone(),
            can_go_back: current > 0,
            can_go_forward: current + 1 < entries.len(),
        });
    }

    fn notify_cursor_changed(&self, _webview: WebView, cursor: Cursor) {
        if self.shared.is_active(&self.tab) {
            emit(&Event::Cursor {
                cursor: format!("{cursor:?}"),
            });
        }
    }

    fn notify_status_text_changed(&self, _webview: WebView, status: Option<String>) {
        emit(&Event::StatusText {
            tab: self.tab.clone(),
            text: status,
        });
    }

    fn notify_crashed(&self, _webview: WebView, reason: String, _backtrace: Option<String>) {
        emit(&Event::Error {
            message: format!("page crashed: {reason}"),
        });
    }

    fn request_create_new(&self, _parent: WebView, request: servo::CreateNewWebViewRequest) {
        let popup = request
            .builder(Rc::clone(&self.shared.rendering_context))
            .delegate(Rc::new(PopupCapture {
                opener: self.tab.clone(),
                shared: Rc::clone(&self.shared),
            }))
            .build();
        self.shared.popups.borrow_mut().push(popup);
    }

    fn load_web_resource(&self, _webview: WebView, load: WebResourceLoad) {
        let request = load.request();
        if request.is_for_main_frame {
            self.shared.blocked.borrow_mut().insert(self.tab.clone(), 0);
            return;
        }
        let Some(host) = request.url.host_str().map(str::to_owned) else {
            return;
        };
        if !self.shared.blocklist.is_blocked(&host) {
            return;
        }
        let url = request.url.clone();
        load.intercept(WebResourceResponse::new(url)).cancel();
        let total = {
            let mut blocked = self.shared.blocked.borrow_mut();
            let n = blocked.entry(self.tab.clone()).or_insert(0);
            *n += 1;
            *n
        };
        emit(&Event::Blocked {
            tab: self.tab.clone(),
            total,
            host,
        });
    }
}

/// `window.open` / `target=_blank`: capture the URL, deny the load, hand it to the shell.
struct PopupCapture {
    opener: String,
    shared: Rc<Shared>,
}

impl WebViewDelegate for PopupCapture {
    fn request_navigation(&self, webview: WebView, navigation_request: NavigationRequest) {
        let url = navigation_request.url.to_string();
        navigation_request.deny();
        self.shared
            .popups
            .borrow_mut()
            .retain(|w| w.id() != webview.id());
        if url != "about:blank" {
            emit(&Event::NewTabRequest {
                opener: self.opener.clone(),
                url,
            });
        }
    }
}

struct ServoBridge;

impl ServoDelegate for ServoBridge {
    fn notify_error(&self, error: ServoError) {
        emit(&Event::Error {
            message: format!("servo: {error:?}"),
        });
    }
}

/// Two memory-mapped frame files; the writer alternates between them.
struct FrameRing {
    paths: [PathBuf; 2],
    maps: [Option<MmapMut>; 2],
    next: usize,
    seq: u64,
}

impl FrameRing {
    fn new(base: &Path) -> Self {
        let with = |i: usize| {
            let mut p = base.as_os_str().to_owned();
            p.push(format!(".{i}"));
            PathBuf::from(p)
        };
        Self {
            paths: [with(0), with(1)],
            maps: [None, None],
            next: 0,
            seq: 0,
        }
    }

    fn map(&mut self, index: usize, len: usize) -> std::io::Result<&mut MmapMut> {
        let fits = self.maps[index].as_ref().is_some_and(|m| m.len() >= len);
        if !fits {
            self.maps[index] = None;
            let file = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .open(&self.paths[index])?;
            // Grow with headroom so small window resizes don't remap every time.
            let cap = len + len / 4;
            file.set_len(cap as u64)?;
            self.maps[index] = Some(unsafe { MmapMut::map_mut(&file)? });
        }
        Ok(self.maps[index].as_mut().expect("mapped"))
    }

    fn write(&mut self, width: u32, height: u32, pixels: &[u8]) -> std::io::Result<()> {
        let index = self.next;
        let seq = self.seq.wrapping_add(1);
        let map = self.map(index, FRAME_HEADER + pixels.len())?;
        // Seqlock: clear seq, write pixels, then publish seq so the reader can detect tearing.
        map[16..24].copy_from_slice(&0u64.to_le_bytes());
        map[0..4].copy_from_slice(&FRAME_MAGIC.to_le_bytes());
        map[4..8].copy_from_slice(&width.to_le_bytes());
        map[8..12].copy_from_slice(&height.to_le_bytes());
        map[12..16].copy_from_slice(&0u32.to_le_bytes());
        map[FRAME_HEADER..FRAME_HEADER + pixels.len()].copy_from_slice(pixels);
        std::sync::atomic::fence(std::sync::atomic::Ordering::Release);
        map[16..24].copy_from_slice(&seq.to_le_bytes());

        self.seq = seq;
        self.next ^= 1;
        emit(&Event::Frame {
            path: self.paths[index].display().to_string(),
            index: index as u8,
            width,
            height,
            seq,
        });
        Ok(())
    }

    fn cleanup(&self) {
        for p in &self.paths {
            let _ = std::fs::remove_file(p);
        }
    }
}

pub struct BrowseEngine {
    servo: Servo,
    rendering_context: Rc<SoftwareRenderingContext>,
    shared: Rc<Shared>,
    webviews: HashMap<String, WebView>,
    user_content: Rc<UserContentManager>,
    frames: FrameRing,
    pending_resize: Option<(PhysicalSize<u32>, Instant)>,
    scale: f32,
}

impl BrowseEngine {
    pub fn new(
        frame_base: PathBuf,
        profile_dir: Option<PathBuf>,
        initial: PhysicalSize<u32>,
        waker: Box<dyn servo::EventLoopWaker>,
    ) -> Result<Self, String> {
        let size = PhysicalSize::new(initial.width.max(1), initial.height.max(1));
        let rendering_context = Rc::new(
            SoftwareRenderingContext::new(size)
                .map_err(|e| format!("SoftwareRenderingContext::new: {e:?}"))?,
        );
        rendering_context
            .make_current()
            .map_err(|e| format!("make_current: {e:?}"))?;

        if let Some(dir) = &profile_dir {
            let _ = std::fs::create_dir_all(dir);
        }
        let opts = Opts {
            config_dir: profile_dir.clone(),
            ..Opts::default()
        };
        let servo = ServoBuilder::default()
            .opts(opts)
            .event_loop_waker(waker)
            .build();
        servo.set_delegate(Rc::new(ServoBridge));
        let user_content = Rc::new(UserContentManager::new(&servo));
        user_content.add_script(Rc::new(UserScript::from(YOUTUBE_PLAYER_SCRIPT)));

        let shared = Rc::new(Shared {
            needs_paint: Cell::new(false),
            active: RefCell::new(None),
            blocklist: Blocklist::load(profile_dir.as_deref()),
            blocked: RefCell::new(HashMap::new()),
            popups: RefCell::new(Vec::new()),
            rendering_context: Rc::clone(&rendering_context) as Rc<dyn RenderingContext>,
        });

        Ok(Self {
            servo,
            rendering_context,
            shared,
            webviews: HashMap::new(),
            user_content,
            frames: FrameRing::new(&frame_base),
            pending_resize: None,
            scale: 1.0,
        })
    }

    fn active_webview(&self) -> Option<&WebView> {
        let active = self.shared.active.borrow();
        active.as_ref().and_then(|id| self.webviews.get(id))
    }

    pub fn open(&mut self, tab: &str, url: &str) -> Result<(), String> {
        let parsed = Url::parse(url).map_err(|e| format!("{url}: {e}"))?;
        if let Some(webview) = self.webviews.get(tab) {
            webview.load(parsed);
            return Ok(());
        }
        let webview = WebViewBuilder::new(&self.servo, Rc::clone(&self.shared.rendering_context))
            .delegate(Rc::new(TabDelegate {
                tab: tab.to_owned(),
                shared: Rc::clone(&self.shared),
            }))
            .hidpi_scale_factor(Scale::new(self.scale))
            .user_content_manager(Rc::clone(&self.user_content))
            .url(parsed)
            .build();
        webview.notify_theme_change(Theme::Dark);
        if self.shared.is_active(tab) {
            webview.show();
            webview.focus();
            self.shared.needs_paint.set(true);
        } else {
            webview.hide();
        }
        self.webviews.insert(tab.to_owned(), webview);
        Ok(())
    }

    pub fn close(&mut self, tab: &str) {
        self.webviews.remove(tab);
        self.shared.blocked.borrow_mut().remove(tab);
        if self.shared.is_active(tab) {
            *self.shared.active.borrow_mut() = None;
        }
    }

    pub fn activate(&mut self, tab: Option<String>) {
        if *self.shared.active.borrow() == tab {
            return;
        }
        if let Some(prev) = self.active_webview() {
            prev.blur();
            prev.hide();
        }
        *self.shared.active.borrow_mut() = tab;
        if let Some(next) = self.active_webview() {
            next.show();
            next.focus();
            self.shared.needs_paint.set(true);
        }
    }

    pub fn navigate(&mut self, tab: &str, url: &str) -> Result<(), String> {
        self.open(tab, url)
    }

    pub fn go_back(&self, tab: &str) {
        if let Some(w) = self.webviews.get(tab) {
            let _ = w.go_back(1);
        }
    }

    pub fn go_forward(&self, tab: &str) {
        if let Some(w) = self.webviews.get(tab) {
            let _ = w.go_forward(1);
        }
    }

    pub fn reload(&self, tab: &str) {
        if let Some(w) = self.webviews.get(tab) {
            w.reload();
        }
    }

    pub fn zoom(&self, factor: f32) {
        if let Some(w) = self.active_webview() {
            w.set_page_zoom(factor.clamp(0.3, 5.0));
        }
    }

    pub fn focus(&self) {
        if let Some(w) = self.active_webview() {
            w.focus();
        }
    }

    pub fn blur(&self) {
        if let Some(w) = self.active_webview() {
            w.blur();
        }
    }

    pub fn set_bounds(&mut self, width: u32, height: u32, scale: f32) {
        if scale > 0.0 && (self.scale - scale).abs() > f32::EPSILON {
            self.scale = scale;
            for w in self.webviews.values() {
                w.set_hidpi_scale_factor(Scale::new(scale));
            }
            self.shared.needs_paint.set(true);
        }
        let size = PhysicalSize::new(width.max(1), height.max(1));
        self.pending_resize = Some((size, Instant::now()));
    }

    fn input(&self, event: InputEvent) {
        if let Some(w) = self.active_webview() {
            w.notify_input_event(event);
        }
    }

    fn point(x: f32, y: f32) -> servo::WebViewPoint {
        DevicePoint::new(x, y).into()
    }

    pub fn mouse_move(&self, x: f32, y: f32) {
        self.input(InputEvent::MouseMove(MouseMoveEvent::new(Self::point(x, y))));
    }

    pub fn mouse_button(&self, x: f32, y: f32, button: i16, down: bool) {
        let action = if down {
            MouseButtonAction::Down
        } else {
            MouseButtonAction::Up
        };
        self.input(InputEvent::MouseButton(MouseButtonEvent::new(
            action,
            MouseButton::from(button),
            Self::point(x, y),
        )));
    }

    pub fn mouse_leave(&self) {
        self.input(InputEvent::MouseLeftViewport(MouseLeftViewportEvent::default()));
    }

    pub fn wheel(&self, x: f32, y: f32, dx: f64, dy: f64, pixels: bool) {
        let delta = WheelDelta {
            x: dx,
            y: dy,
            z: 0.0,
            mode: if pixels {
                WheelMode::DeltaPixel
            } else {
                WheelMode::DeltaLine
            },
        };
        self.input(InputEvent::Wheel(WheelEvent::new(delta, Self::point(x, y))));
    }

    #[allow(clippy::too_many_arguments)]
    pub fn key(
        &self,
        down: bool,
        key: &str,
        named: bool,
        code: Option<&str>,
        shift: bool,
        ctrl: bool,
        alt: bool,
        meta: bool,
        repeat: bool,
    ) {
        let key = if named {
            Key::Named(NamedKey::from_str(key).unwrap_or(NamedKey::Unidentified))
        } else {
            Key::Character(key.to_owned())
        };
        let code = code
            .and_then(|c| Code::from_str(c).ok())
            .unwrap_or(Code::Unidentified);
        let mut modifiers = Modifiers::empty();
        modifiers.set(Modifiers::SHIFT, shift);
        modifiers.set(Modifiers::CONTROL, ctrl);
        modifiers.set(Modifiers::ALT, alt);
        modifiers.set(Modifiers::META, meta);
        let state = if down { KeyState::Down } else { KeyState::Up };
        self.input(InputEvent::Keyboard(KeyboardEvent::new_without_event(
            state,
            key,
            code,
            Location::Standard,
            modifiers,
            repeat,
            false,
        )));
    }

    pub fn edit(&self, action: &str) {
        let action = match action {
            "copy" => EditingActionEvent::Copy,
            "cut" => EditingActionEvent::Cut,
            "paste" => EditingActionEvent::Paste,
            _ => return,
        };
        self.input(InputEvent::EditingAction(action));
    }

    /// Spin Servo once; paint and publish a frame if the active WebView changed.
    /// Returns how long the caller may sleep before the next tick is needed.
    pub fn tick(&mut self) -> Option<Duration> {
        let mut wait = None;
        if let Some((new_size, at)) = self.pending_resize {
            let current = self.rendering_context.size();
            if new_size == current {
                self.pending_resize = None;
            } else if at.elapsed() >= RESIZE_DEBOUNCE {
                self.pending_resize = None;
                match self.webviews.values().next() {
                    Some(w) => w.resize(new_size),
                    None => self.rendering_context.resize(new_size),
                }
                self.shared.needs_paint.set(true);
            } else {
                wait = Some(RESIZE_DEBOUNCE.saturating_sub(at.elapsed()));
            }
        }

        self.servo.spin_event_loop();

        if self.shared.needs_paint.replace(false) {
            self.paint();
        }
        wait
    }

    fn paint(&mut self) {
        let Some(webview) = self.active_webview().cloned() else {
            return;
        };
        if let Err(e) = self.rendering_context.make_current() {
            emit(&Event::Error {
                message: format!("make_current: {e:?}"),
            });
            return;
        }
        webview.paint();
        let size = self.rendering_context.size();
        let rect = DeviceIntRect::new(
            Point2D::origin().cast_unit(),
            Point2D::new(size.width as i32, size.height as i32).cast_unit(),
        );
        if let Some(rgba) = self.rendering_context.read_to_image(rect) {
            let (w, h) = (rgba.width(), rgba.height());
            if let Err(e) = self.frames.write(w, h, rgba.as_raw()) {
                emit(&Event::Error {
                    message: format!("frame write: {e}"),
                });
            }
        }
        self.rendering_context.present();
    }

    pub fn shutdown(mut self) {
        self.frames.cleanup();
        self.shared.popups.borrow_mut().clear();
        self.webviews.clear();
        self.servo.spin_event_loop();
    }
}
