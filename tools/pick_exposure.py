#!/usr/bin/env python3
"""
Pick the camera exposure for the dataset generator from the in-game exposure test.

1. In the mission, fly the camera to a typical view (green field with a few soldiers, from the
   generator's height, 100-300 m away) and press End. The game takes the same picture at every
   aperture value in ZPI_cfg_apertureTest (exposure_A<value>_<frame>.png) plus one automatic.
2. Run:  python tools/pick_exposure.py
   It measures every picture (brightness, clipped highlights, contrast), picks the best value,
   writes it to the mission's zpi\\exposure.sqf and saves exposure_test.jpg (all pictures side by
   side with their values) so you can check the choice by eye.
3. Press Home in the game: the generator reloads exposure.sqf and uses the new value.

Options:
    --shots  "C:\\...\\Arma 3\\Screenshots"             where the screenshots are (default: found automatically)
    --mission "C:\\...\\missions\\ZPI_scenario.Altis"   mission folder (default: the one this tools folder is in)
    --value 30                                          write this value instead of the automatic choice
    --no-write                                          only measure and show
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import zpi_paths  # noqa: E402

TARGET_MEDIAN = 0.42     # wanted median brightness (0..1)
MAX_CLIPPED = 0.01       # at most 1 % of the pixels burnt out


def find_shots() -> list[Path]:
    return [d for d in zpi_paths.screenshot_dirs() if d.exists()]


def find_mission() -> Path | None:
    return zpi_paths.find_mission()      # the mission this tools folder is in


def measure(path: Path) -> dict:
    import numpy as np
    from PIL import Image
    a = np.asarray(Image.open(path).convert("RGB").resize((480, 270)), dtype=np.float32) / 255.0
    lum = a @ np.array([0.299, 0.587, 0.114], np.float32)
    clipped = float((a.max(axis=2) >= 0.98).mean())
    dark = float((a.max(axis=2) <= 0.02).mean())
    return {"median": float(np.median(lum)), "p1": float(np.percentile(lum, 1)), "p99": float(np.percentile(lum, 99)),
            "clipped": clipped, "dark": dark, "contrast": float(lum.std())}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--shots", action="append")
    ap.add_argument("--mission")
    ap.add_argument("--value", type=float)
    ap.add_argument("--no-write", action="store_true")
    args = ap.parse_args()

    dirs = [Path(s) for s in args.shots] if args.shots else find_shots()
    files = [p for d in dirs for p in d.rglob("exposure_A*.png")]
    if not files:
        sys.exit("No exposure test pictures found (exposure_A*.png). Press End in the mission first, "
                 "or pass --shots \"...\\Arma 3\\Screenshots\".")
    newest = max(files, key=lambda p: p.stat().st_mtime).parent          # newest test only
    files = sorted(p for p in newest.glob("exposure_A*.png"))
    rows = []
    for p in files:
        m = re.match(r"exposure_A([0-9.]+|auto)_", p.name)
        if not m:
            continue
        val = m.group(1)
        rows.append((float(val) if val != "auto" else None, p, measure(p)))
    rows.sort(key=lambda r: (r[0] is None, r[0] or 0))

    print(f"exposure test in {newest}\n")
    print(f"{'aperture':>9} {'darkest1%':>9} {'median':>7} {'p99':>6} {'burnt %':>8} {'black %':>8} {'contrast':>9}")
    for v, p, m in rows:
        print(f"{('auto' if v is None else f'{v:g}'):>9} {m['p1']:9.3f} {m['median']:7.3f} {m['p99']:6.3f} {100 * m['clipped']:8.2f} "
              f"{100 * m['dark']:8.2f} {m['contrast']:9.3f}")

    fixed = [(v, p, m) for v, p, m in rows if v is not None]
    ok = [r for r in fixed if r[2]["clipped"] <= MAX_CLIPPED and r[2]["dark"] <= 0.02]
    pool = ok or fixed
    best = min(pool, key=lambda r: abs(r[2]["median"] - TARGET_MEDIAN))
    choice = args.value if args.value else best[0]
    auto = [r for r in rows if r[0] is None]
    if not args.value and auto and abs(auto[0][2]["median"] - TARGET_MEDIAN) < abs(best[2]["median"] - TARGET_MEDIAN) \
            and auto[0][2]["clipped"] <= MAX_CLIPPED:
        print(f"\nautomatic exposure (median {auto[0][2]['median']:.2f}) is closer to the target than every fixed value: keeping automatic")
        best, choice = auto[0], -1
    if best[0] is not None:
        print(f"\nbest: aperture {best[0]:g} (median brightness {best[2]['median']:.2f}, target {TARGET_MEDIAN}, "
          f"{100 * best[2]['clipped']:.2f} % burnt out)")
    if best[2]["p1"] > 0.3:
        print(f"\nNOTE: even the darkest 1 % of the picture is at {best[2]['p1']:.2f} brightness (0 = black): a white veil\n"
              "      (distance haze, bloom) lies over the whole picture. Exposure cannot remove it; the dataset tool's\n"
              "      haze correction does (make_yolo_dataset.py, on by default). Bloom off in the video options helps too.")
    if not ok and choice != -1:
        print("WARNING: every value burns out more than 1 % of the picture or is too dark: extend ZPI_cfg_apertureTest in config.sqf")
    if best[0] is not None and (best is fixed[0] or best is fixed[-1]):
        print("NOTE: the best value is at the end of the tested range; extend ZPI_cfg_apertureTest and test again to be sure.")

    # contact sheet
    try:
        from PIL import Image, ImageDraw
        n = len(rows)
        cols = 4
        tw, th = 480, 270
        sheet = Image.new("RGB", (cols * tw, ((n + cols - 1) // cols) * (th + 22)), (30, 30, 30))
        d = ImageDraw.Draw(sheet)
        for i, (v, p, m) in enumerate(rows):
            x, y = (i % cols) * tw, (i // cols) * (th + 22)
            sheet.paste(Image.open(p).convert("RGB").resize((tw, th)), (x, y + 22))
            tag = ("auto" if v is None else f"aperture {v:g}") + f"   median {m['median']:.2f}  burnt {100 * m['clipped']:.1f}%"
            chosen = (v == choice) or (v is None and choice == -1)
            d.text((x + 6, y + 5), tag + ("   <- chosen" if chosen else ""), fill=(255, 220, 120) if chosen else (230, 230, 230))
        out = newest / "exposure_test.jpg"
        sheet.save(out, quality=88)
        print(f"contact sheet: {out}")
    except Exception as e:
        print(f"(no contact sheet: {e})")

    if args.no_write:
        return
    mission = Path(args.mission) if args.mission else find_mission()
    if not mission or not (mission / "zpi").exists():
        sys.exit("Mission folder not found; pass --mission \"...\\Arma 3\\missions\\<mission>.Altis\"")
    f = mission / "zpi" / "exposure.sqf"
    f.write_text("// Fixed camera exposure for noon / clear weather, written by tools/pick_exposure.py.\n"
                 "// -1 = automatic exposure (over-exposes when the camera looks down at the ground).\n"
                 f"ZPI_cfg_aperture = {choice:g};\n", encoding="utf-8")
    print(f"\nwrote ZPI_cfg_aperture = {choice:g} to {f}\nPress Home in the game: the generator loads it.")


if __name__ == "__main__":
    main()
