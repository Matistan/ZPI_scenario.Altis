#!/usr/bin/env python3
"""
Haze and exposure correction for Arma drone screenshots.

Arma's automatic exposure opens up when the camera sees little sky, so a drone camera looking
down at sunlit ground comes out over-exposed. Flat noon light and distance haze add a grey-white
veil. This takes the veil off: a black point at the haze level and a white point (mostly common to
all three colour channels, so colours stay natural, with a little per-channel correction that
removes the haze tint), then a gamma that brings the middle grey to a fixed level, and a slight
saturation lift. Geometry is not changed, so YOLO labels stay valid.

Use the SAME correction on live frames as on training images:

    from zpi_enhance import enhance
    frame = enhance(frame)            # PIL.Image in, PIL.Image out

Command line (writes <name>_enh.png next to each file, or into --out):
    python tools/zpi_enhance.py shot1.png shot2.png [--out folder] [--compare]
"""
from __future__ import annotations

import math

DEFAULTS = {"target": 0.48, "sat": 1.05, "lo_pct": 0.3, "hi_pct": 99.8, "max_gain": 2.5, "wb": 0.25}


def enhance(im, target: float = 0.48, sat: float = 1.05, lo_pct: float = 0.3, hi_pct: float = 99.8,
            max_gain: float = 2.5, wb: float = 0.25):
    """PIL image -> corrected PIL RGB image (same size)."""
    import numpy as np
    from PIL import Image

    a = np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0
    small = a[::8, ::8].reshape(-1, 3)
    lo_c = np.percentile(small, lo_pct, axis=0)             # haze floor per channel
    hi_c = np.percentile(small, hi_pct, axis=0)             # white point per channel
    lo = lo_c.min() + wb * (lo_c - lo_c.min())               # mostly one common stretch ...
    hi = hi_c.max() + wb * (hi_c - hi_c.max())               # ... + a little tint removal
    span = np.maximum(hi - lo, 1.0 / max_gain)               # never stretch more than max_gain x
    lo = np.minimum(lo, hi - span)
    out = np.clip((a - lo) / span, 0.0, 1.0)
    w = np.array([0.299, 0.587, 0.114], np.float32)
    m = float(np.median((out[::8, ::8] @ w)))
    g = min(max(math.log(target) / math.log(min(max(m, 0.05), 0.95)), 0.7), 2.5)
    out = out ** g
    luma = (out @ w)[..., None]
    out = np.clip(luma + (out - luma) * sat, 0.0, 1.0)
    return Image.fromarray((out * 255.0 + 0.5).astype(np.uint8))


def main():
    import argparse
    from pathlib import Path
    from PIL import Image

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("images", nargs="+")
    ap.add_argument("--out", help="output folder (default: next to the input)")
    ap.add_argument("--compare", action="store_true", help="write a side-by-side before/after JPEG instead")
    args = ap.parse_args()
    for f in args.images:
        p = Path(f)
        im = Image.open(p).convert("RGB")
        e = enhance(im)
        dst = Path(args.out) if args.out else p.parent
        dst.mkdir(parents=True, exist_ok=True)
        if args.compare:
            W, H = im.size
            w = Image.new("RGB", (W, H // 2))
            w.paste(im.resize((W // 2, H // 2)), (0, 0))
            w.paste(e.resize((W // 2, H // 2)), (W // 2, 0))
            w.save(dst / f"{p.stem}_compare.jpg", quality=88)
        else:
            e.save(dst / f"{p.stem}_enh.png")
        print(f"{p.name} done")


if __name__ == "__main__":
    main()
