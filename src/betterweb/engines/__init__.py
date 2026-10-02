"""Engine adapters: Lightpanda (fetch), Servo & Ladybird (browse)."""

from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
BIN_DIR = REPO_ROOT / "bin"


@dataclass
class EngineStatus:
    id: str
    name: str
    role: str
    available: bool
    path: str | None
    detail: str

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "role": self.role,
            "available": self.available,
            "path": self.path,
            "detail": self.detail,
        }


def _which(name: str) -> str | None:
    return shutil.which(name)


def lightpanda_path() -> str | None:
    env = os.environ.get("BETTERWEB_LIGHTPANDA")
    if env and Path(env).is_file():
        return env
    local = BIN_DIR / "lightpanda"
    if local.is_file() and os.access(local, os.X_OK):
        return str(local)
    return _which("lightpanda")


def servo_path() -> str | None:
    env = os.environ.get("BETTERWEB_SERVO")
    if env and Path(env).exists():
        return env
    app = Path("/Applications/Servo.app/Contents/MacOS/servo")
    if app.is_file():
        return str(app)
    for name in ("servo", "servoshell"):
        found = _which(name)
        if found:
            return found
    return None


def ladybird_path() -> str | None:
    env = os.environ.get("BETTERWEB_LADYBIRD")
    if env and Path(env).exists():
        return env
    for app_name in ("Ladybird.app", "ladybird.app"):
        app = Path("/Applications") / app_name / "Contents/MacOS/Ladybird"
        if app.is_file():
            return str(app)
        # Some builds use a lowercase binary name
        alt = Path("/Applications") / app_name / "Contents/MacOS/ladybird"
        if alt.is_file():
            return str(alt)
    return _which("Ladybird") or _which("ladybird")


def engine_statuses() -> list[EngineStatus]:
    lp = lightpanda_path()
    sv = servo_path()
    lb = ladybird_path()
    return [
        EngineStatus(
            id="craftrank",
            name="CraftRank",
            role="rank",
            available=True,
            path="betterweb.craftrank",
            detail="In-process quality-weighted authority (always on)",
        ),
        EngineStatus(
            id="lightpanda",
            name="Lightpanda",
            role="fetch",
            available=lp is not None,
            path=lp,
            detail=(
                "Non-Chromium headless fetch (JS-capable)"
                if lp
                else "Missing — place binary at bin/lightpanda or set BETTERWEB_LIGHTPANDA"
            ),
        ),
        EngineStatus(
            id="servo",
            name="Servo",
            role="browse",
            available=sv is not None,
            path=sv,
            detail=(
                "Independent embeddable engine for human browsing"
                if sv
                else "Not installed — download from https://servo.org/download/"
            ),
        ),
        EngineStatus(
            id="ladybird",
            name="Ladybird",
            role="browse",
            available=lb is not None,
            path=lb,
            detail=(
                "From-scratch browser engine (preferred long-term shell)"
                if lb
                else "Not installed — build/install from https://ladybird.org/"
            ),
        ),
    ]


def fetch_with_lightpanda(url: str, *, timeout: int = 45) -> str:
    """Fetch rendered HTML via Lightpanda CLI (telemetry disabled)."""
    binary = lightpanda_path()
    if not binary:
        raise RuntimeError("Lightpanda binary not found")
    env = os.environ.copy()
    env["LIGHTPANDA_DISABLE_TELEMETRY"] = "true"
    proc = subprocess.run(
        [
            binary,
            "fetch",
            url,
            "--dump",
            "html",
            "--obey-robots",
            "--wait-ms",
            "8000",
            "--user-agent-suffix",
            " BetterWeb/0.1",
        ],
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
        check=False,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "lightpanda fetch failed").strip()
        raise RuntimeError(err)
    return proc.stdout


def open_with_engine(engine_id: str, url: str) -> dict:
    """Launch a local browse engine with the given URL."""
    if engine_id == "servo":
        path = servo_path()
        if not path:
            raise RuntimeError("Servo not available")
        if path.endswith(".app") or "Servo.app" in path:
            subprocess.Popen(["open", "-a", "Servo", url])
        else:
            subprocess.Popen([path, url])
        return {"opened": True, "engine": "servo", "url": url, "path": path}

    if engine_id == "ladybird":
        path = ladybird_path()
        if not path:
            raise RuntimeError("Ladybird not available")
        if "Ladybird.app" in path or "ladybird.app" in path:
            subprocess.Popen(["open", "-a", "Ladybird", url])
        else:
            subprocess.Popen([path, url])
        return {"opened": True, "engine": "ladybird", "url": url, "path": path}

    raise ValueError(f"Unsupported browse engine: {engine_id}")
