#!/usr/bin/env python3
"""
Frame-number bar: decode it from a captured frame, and strip it before detection.

Layout (must match description.ext, in screen pixels):
  squares of SIZE x SIZE px in one row starting at (X0, Y0)
  square 0 = white sentinel, square 1 = black sentinel,
  squares 2..25 = bits 0..23 of diag_frameNo, LSB first (white = 1).

Works with numpy arrays as returned by dxcam / mss / OpenCV (H x W x 3, uint8).
Channel order does not matter (the bar is pure black/white).
"""
from __future__ import annotations

import numpy as np

X0, Y0, SIZE, NBITS = 4, 4, 8, 24
N_SQUARES = NBITS + 2
BAR_W = X0 + SIZE * N_SQUARES + 4   # region to blank out, with a small margin
BAR_H = Y0 + SIZE + 4


def _square_level(img: np.ndarray, k: int) -> float:
    """Mean brightness of the inner 4x4 px of square k (robust to sub-pixel offsets)."""
    x = X0 + SIZE * k + SIZE // 2
    y = Y0 + SIZE // 2
    patch = img[y - 2:y + 2, x - 2:x + 2]
    return float(patch.mean())


def decode(img: np.ndarray, threshold: float = 128.0) -> int | None:
    """Return the frame number encoded in the bar, or None if the sentinels are missing."""
    if img.shape[0] < BAR_H or img.shape[1] < BAR_W:
        return None
    if _square_level(img, 0) < 200 or _square_level(img, 1) > 55:
        return None  # no bar (UI hidden, wrong crop, or a fade in progress)
    value = 0
    for i in range(NBITS):
        if _square_level(img, 2 + i) >= threshold:
            value |= 1 << i
    return value


def strip(img: np.ndarray) -> np.ndarray:
    """Return a copy with the bar region blacked out, ready for the detector."""
    out = img.copy()
    out[:BAR_H, :BAR_W] = 0
    return out


def render(frame: int, width: int = 1920, height: int = 1080) -> np.ndarray:
    """Draw the bar exactly like the game does (used for tests)."""
    img = np.full((height, width, 3), 90, np.uint8)  # grey "terrain"

    def fill(k: int, white: bool):
        x = X0 + SIZE * k
        img[Y0:Y0 + SIZE, x:x + SIZE] = 255 if white else 0

    fill(0, True)
    fill(1, False)
    for i in range(NBITS):
        fill(2 + i, bool((frame >> i) & 1))
    return img


if __name__ == "__main__":
    rng = np.random.default_rng(0)
    for f in [0, 1, 184233, 2**24 - 1, *rng.integers(0, 2**24, 200)]:
        img = render(int(f))
        img = np.clip(img.astype(int) + rng.integers(-20, 21, img.shape), 0, 255).astype(np.uint8)  # JPEG-ish noise
        assert decode(img) == int(f), f
    assert decode(np.full((1080, 1920, 3), 90, np.uint8)) is None
    assert strip(render(5))[:BAR_H, :BAR_W].max() == 0
    print("frame_code self-test passed")
