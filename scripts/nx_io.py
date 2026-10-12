"""Shared image helpers for the Python side of nyx.

Why this module exists
----------------------
``mi.util.write_bitmap()`` is **asynchronous**. It queues the write on Mitsuba's
thread pool and returns before the file exists, so code that stats or reads the
file straight afterwards sees "no such file" and concludes, reasonably but
wrongly, that it lacks permission to write. That misdiagnosis cost real time
while this repository was being set up; every write in nyx therefore goes
through :func:`write_exr`.

``mi.Thread.thread().wait_for_tasks()`` drains the queue and makes the write
deterministic (measured: 5/5 synchronised writes landed, versus 0/5 when checked
immediately).

Reading is synchronous and needs no special handling.
"""

from __future__ import annotations

import time
from pathlib import Path

import numpy as np

__all__ = ["write_exr", "load_exr", "tonemap_reinhard"]


def write_exr(path: str | Path, bitmap, *, timeout: float = 15.0, verify: bool = True) -> Path:
    """Write an EXR and return its path once the file is really on disk.

    ``bitmap`` may be a ``mi.Bitmap`` or anything ``mi.Bitmap`` accepts,
    including a float32 numpy array.
    """
    import mitsuba as mi

    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)

    mi.util.write_bitmap(str(target), bitmap)
    # Drain the thread pool: without this the file may not exist yet.
    mi.Thread.thread().wait_for_tasks()

    if not verify:
        return target

    deadline = time.monotonic() + timeout
    last_size = -1
    while time.monotonic() < deadline:
        if target.exists():
            size = target.stat().st_size
            # Stable and non-empty: the writer is done with it.
            if size > 0 and size == last_size:
                return target
            last_size = size
        time.sleep(0.02)

    raise RuntimeError(
        f"{target} did not settle after being written; "
        "mitsuba queued the write but the file never became readable"
    )


def load_exr(path: str | Path) -> np.ndarray:
    """Read an EXR into a float32 numpy array in linear light.

    Always RGBA: Mitsuba's reader expands whatever the file holds, and nyx
    compares linear light without any tone mapping applied.
    """
    import mitsuba as mi

    return np.asarray(mi.Bitmap(str(path)), dtype=np.float32)


def tonemap_reinhard(image: np.ndarray, exposure: float = 0.0) -> np.ndarray:
    """Tone map for *display only*.

    Metrics are always computed on the linear values: tone mapping first hides
    exactly the energy errors the Mitsuba-versus-Forge loop exists to find.
    """
    scaled = np.clip(image * (2.0**exposure), 0.0, None)
    return scaled / (1.0 + scaled)
