"""Resolve video pages to directly playable streams for the native player.

Servo has no Media Source Extensions, so MSE-only players (YouTube) cannot play
in-page. The shell plays the resolved HLS manifest with AVPlayer instead, which
also skips the site's ad and telemetry machinery.
"""

from __future__ import annotations

import re
import shutil
import threading
import time
from typing import Any
from urllib.parse import parse_qs, urlparse

_YOUTUBE_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"}
_VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
_CACHE_TTL = 30 * 60
_cache: dict[str, tuple[float, dict[str, Any]]] = {}
_lock = threading.Lock()


class MediaError(Exception):
    pass


def youtube_video_id(url: str) -> str | None:
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    parts = [p for p in parsed.path.split("/") if p]
    candidate: str | None = None
    if host == "youtu.be" and parts:
        candidate = parts[0]
    elif host in _YOUTUBE_HOSTS:
        if parsed.path == "/watch":
            candidate = (parse_qs(parsed.query).get("v") or [None])[0]
        elif len(parts) >= 2 and parts[0] in {"shorts", "live", "embed"}:
            candidate = parts[1]
    if candidate and _VIDEO_ID.match(candidate):
        return candidate
    return None


def _ydl_options() -> dict[str, Any]:
    runtimes: dict[str, dict] = {}
    for name in ("deno", "node", "bun"):
        path = shutil.which(name)
        if path:
            runtimes[name] = {"path": path}
    return {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
        "js_runtimes": runtimes or {"deno": {}},
    }


def _pick_streams(info: dict[str, Any]) -> tuple[str | None, str | None]:
    formats = info.get("formats") or []
    hls = next((f["manifest_url"] for f in formats if f.get("manifest_url")), None)
    if hls is None and info.get("protocol", "").startswith("m3u8"):
        hls = info.get("url")
    muxed = [
        f
        for f in formats
        if f.get("protocol") == "https"
        and f.get("ext") == "mp4"
        and f.get("vcodec") not in (None, "none")
        and f.get("acodec") not in (None, "none")
    ]
    muxed.sort(key=lambda f: f.get("height") or 0)
    progressive = muxed[-1]["url"] if muxed else None
    return hls, progressive


def native_master_playlist(video_id: str) -> str:
    """The HLS master playlist minus variants AVFoundation can't decode (VP9/AV1).

    AVPlayer starts on a low H.264 rendition and then switches up into VP9,
    failing mid-playback with "Cannot Decode"; keeping H.264/HEVC avoids that.
    """
    import requests

    info = resolve(f"https://www.youtube.com/watch?v={video_id}")
    if not info.get("hls_url"):
        raise MediaError("No HLS stream for this video")
    response = requests.get(info["hls_url"], timeout=10)
    response.raise_for_status()
    out: list[str] = []
    skip_uri = False
    for line in response.text.splitlines():
        if line.startswith("#EXT-X-STREAM-INF"):
            codecs = line.split("CODECS=", 1)[-1]
            skip_uri = not ("avc1" in codecs or "hvc1" in codecs)
            if not skip_uri:
                out.append(line)
            continue
        if skip_uri and line and not line.startswith("#"):
            skip_uri = False
            continue
        out.append(line)
    if not any(line.startswith("#EXT-X-STREAM-INF") for line in out):
        raise MediaError("No H.264 renditions in this stream")
    return "\n".join(out) + "\n"


def resolve(url: str) -> dict[str, Any]:
    video_id = youtube_video_id(url)
    if video_id is None:
        raise MediaError("Not a supported video URL")

    now = time.time()
    with _lock:
        hit = _cache.get(video_id)
        if hit and now - hit[0] < _CACHE_TTL:
            return hit[1]

    try:
        import yt_dlp
    except ImportError as exc:
        raise MediaError("yt-dlp is not installed in the BetterWeb environment") from exc

    watch_url = f"https://www.youtube.com/watch?v={video_id}"
    try:
        with yt_dlp.YoutubeDL(_ydl_options()) as ydl:
            info = ydl.extract_info(watch_url, download=False)
    except Exception as exc:  # noqa: BLE001
        message = str(exc).removeprefix("ERROR: ").strip()
        raise MediaError(message or "Could not resolve video") from exc

    hls, progressive = _pick_streams(info or {})
    if not hls and not progressive:
        raise MediaError("No playable stream found for this video")

    result = {
        "id": video_id,
        "title": info.get("title") or "",
        "channel": info.get("channel") or info.get("uploader") or "",
        "duration": info.get("duration"),
        "is_live": bool(info.get("is_live")),
        "thumbnail": info.get("thumbnail"),
        "hls_url": hls,
        "progressive_url": progressive,
    }
    with _lock:
        _cache[video_id] = (now, result)
    return result
