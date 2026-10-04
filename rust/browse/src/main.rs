//! BetterWeb browse helper — Servo embed behind a JSON-lines IPC.

mod blocklist;
mod protocol;

#[cfg(feature = "servo-engine")]
mod engine;

use std::{env, io, path::PathBuf};

#[cfg(not(feature = "servo-engine"))]
use protocol::{emit, Event};

fn frame_base() -> PathBuf {
    if let Ok(p) = env::var("BETTERWEB_FRAME_PATH") {
        return PathBuf::from(p);
    }
    let dir = env::temp_dir().join("betterweb");
    let _ = std::fs::create_dir_all(&dir);
    dir.join(format!("frame-{}", std::process::id()))
}

fn profile_dir() -> Option<PathBuf> {
    if let Some(p) = env::var_os("BETTERWEB_PROFILE_DIR") {
        return Some(PathBuf::from(p));
    }
    let home = env::var_os("HOME")?;
    Some(PathBuf::from(home).join("Library/Application Support/BetterWeb/Servo"))
}

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn,betterweb_browse=info")),
        )
        .with_writer(io::stderr)
        .with_ansi(false)
        .init();

    #[cfg(feature = "servo-engine")]
    {
        // Required by Servo's rustls stack.
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
        servo_main::run();
    }

    #[cfg(not(feature = "servo-engine"))]
    {
        emit(&Event::Error {
            message: "betterweb-browse built without servo-engine feature".into(),
        });
        std::process::exit(1);
    }
}

#[cfg(feature = "servo-engine")]
mod servo_main {
    use std::{
        io,
        sync::mpsc::{self, RecvTimeoutError, Sender},
        thread,
        time::Duration,
    };

    use dpi::PhysicalSize;

    use crate::engine::BrowseEngine;
    use crate::protocol::{emit, Command, Event};

    enum Msg {
        Cmd(Command),
        Wake,
        StdinClosed,
    }

    struct ChannelWaker(Sender<Msg>);

    impl servo::EventLoopWaker for ChannelWaker {
        fn clone_box(&self) -> Box<dyn servo::EventLoopWaker> {
            Box::new(ChannelWaker(self.0.clone()))
        }

        fn wake(&self) {
            let _ = self.0.send(Msg::Wake);
        }
    }

    pub fn run() {
        let (tx, rx) = mpsc::channel::<Msg>();
        let waker = Box::new(ChannelWaker(tx.clone()));

        let mut engine = match BrowseEngine::new(
            super::frame_base(),
            super::profile_dir(),
            PhysicalSize::new(1280, 800),
            waker,
        ) {
            Ok(e) => e,
            Err(err) => {
                emit(&Event::Error { message: err });
                std::process::exit(1);
            }
        };

        emit(&Event::Ready {
            engine: "servo".into(),
            version: env!("CARGO_PKG_VERSION").into(),
        });

        thread::spawn(move || {
            for line in io::stdin().lines() {
                let Ok(line) = line else { break };
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Command>(line) {
                    Ok(cmd) => {
                        if tx.send(Msg::Cmd(cmd)).is_err() {
                            return;
                        }
                    }
                    Err(err) => emit(&Event::Error {
                        message: format!("bad command: {err}"),
                    }),
                }
            }
            // The shell went away (quit or crash): never outlive it.
            let _ = tx.send(Msg::StdinClosed);
        });

        // Servo also needs periodic spins for timers/animations it doesn't wake us for.
        let idle = Duration::from_millis(100);
        let mut wait = idle;
        loop {
            let first = match rx.recv_timeout(wait) {
                Ok(m) => Some(m),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => break,
            };
            let mut pending: Vec<Msg> = first.into_iter().collect();
            pending.extend(rx.try_iter());

            for msg in pending {
                match msg {
                    Msg::Wake => {}
                    Msg::StdinClosed => {
                        engine.shutdown();
                        return;
                    }
                    Msg::Cmd(cmd) => {
                        if !handle(&mut engine, cmd) {
                            engine.shutdown();
                            return;
                        }
                    }
                }
            }

            wait = engine.tick().unwrap_or(idle);
        }
        engine.shutdown();
    }

    /// Returns `false` when the helper should exit.
    fn handle(engine: &mut BrowseEngine, cmd: Command) -> bool {
        let report = |r: Result<(), String>| {
            if let Err(message) = r {
                emit(&Event::Error { message });
            }
        };
        match cmd {
            Command::Ping => emit(&Event::Pong),
            Command::Shutdown => return false,
            Command::Open { tab, url } => report(engine.open(&tab, &url)),
            Command::Close { tab } => engine.close(&tab),
            Command::Activate { tab } => engine.activate(tab),
            Command::Navigate { tab, url } => report(engine.navigate(&tab, &url)),
            Command::GoBack { tab } => engine.go_back(&tab),
            Command::GoForward { tab } => engine.go_forward(&tab),
            Command::Reload { tab } => engine.reload(&tab),
            Command::Zoom { factor } => engine.zoom(factor),
            Command::SetBounds {
                width,
                height,
                scale,
            } => engine.set_bounds(width, height, scale),
            Command::Focus => engine.focus(),
            Command::Blur => engine.blur(),
            Command::MouseMove { x, y } => engine.mouse_move(x, y),
            Command::MouseButton { x, y, button, down } => engine.mouse_button(x, y, button, down),
            Command::MouseLeave => engine.mouse_leave(),
            Command::Wheel {
                x,
                y,
                dx,
                dy,
                pixels,
            } => engine.wheel(x, y, dx, dy, pixels),
            Command::Key {
                down,
                key,
                named,
                code,
                shift,
                ctrl,
                alt,
                meta,
                repeat,
            } => engine.key(
                down,
                &key,
                named,
                code.as_deref(),
                shift,
                ctrl,
                alt,
                meta,
                repeat,
            ),
            Command::Edit { action } => engine.edit(&action),
        }
        true
    }
}
