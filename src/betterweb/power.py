"""Whether background crawl/GLiNER may run. AC/UPS only on macOS."""

from __future__ import annotations

import subprocess
import sys

_PMSET = "/usr/bin/pmset"


def on_ac_power() -> bool:
    if sys.platform != "darwin":
        return True
    try:
        out = subprocess.run(
            [_PMSET, "-g", "batt"],
            check=True,
            capture_output=True,
            text=True,
            timeout=2,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return "AC Power" in out or "UPS Power" in out
