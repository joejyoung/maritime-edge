#!/usr/bin/env python3
"""
argus_frame_stats.py — exposure and focus metrics for raw YUYV 4:2:2 captures.

Reads a headerless .raw/.yuv file, extracts the luma plane, and reports
exposure statistics and Laplacian-variance focus metrics.

Usage:
    argus_frame_stats.py FILE [-W 1920] [-H 1080] [-f 0] [--crop 600x400]
    argus_frame_stats.py FILE --csv          # single CSV row, for the DOPE book
    argus_frame_stats.py FILE --linear       # gamma-linearise before stats

Exit codes:
    0  ok
    1  file/geometry error
    2  file truncated (byte count not a whole number of frames)
"""

import argparse
import os
import sys

import numpy as np

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEFAULT_W = 1920
DEFAULT_H = 1080
DEFAULT_CROP = "600x400"
GAMMA = 2.2  # display gamma assumed by the camera ISP; see guide 6.5

# Exposure judgement thresholds (guide 6.1)
MEAN_LO, MEAN_HI = 90.0, 140.0
CLIP_MAX = 1.0     # percent
CRUSH_MAX = 5.0    # percent


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------
def load_luma(path, width, height, frame_index=0, linear=False):
    """Return (luma_plane_float32, n_frames). YUYV 4:2:2 is 2 bytes/pixel;
    every even-indexed byte is a luma sample."""
    frame_bytes = width * height * 2
    size = os.path.getsize(path)

    if size < frame_bytes:
        raise SystemExit(
            f"ERROR: {path} is {size} B, smaller than one {width}x{height} "
            f"frame ({frame_bytes} B). Wrong geometry, or capture failed."
        )

    n_frames = size / frame_bytes
    if abs(n_frames - round(n_frames)) > 1e-9:
        print(
            f"WARNING: {size} B is {n_frames:.3f} frames at {width}x{height}. "
            f"File is truncated or the geometry is wrong.",
            file=sys.stderr,
        )

    n_whole = int(size // frame_bytes)
    if frame_index >= n_whole:
        raise SystemExit(
            f"ERROR: requested frame {frame_index}, file holds {n_whole}."
        )

    raw = np.fromfile(
        path, dtype=np.uint8, count=frame_bytes, offset=frame_index * frame_bytes
    )
    y = raw.reshape(height, width * 2)[:, 0::2].astype(np.float32)

    if linear:
        # Undo display gamma to approximate relative scene luminance.
        y = 255.0 * np.power(y / 255.0, GAMMA)

    return y, n_frames


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------
def exposure_stats(y):
    return {
        "mean": float(y.mean()),
        "min": int(y.min()),
        "max": int(y.max()),
        "clipped_pct": float((y >= 250).mean() * 100.0),
        "crushed_pct": float((y <= 5).mean() * 100.0),
    }


def laplacian(y):
    """4-neighbour discrete Laplacian, interior pixels only."""
    return (
        y[1:-1, 2:] + y[1:-1, :-2] + y[2:, 1:-1] + y[:-2, 1:-1] - 4.0 * y[1:-1, 1:-1]
    )


def focus_stats(y, label):
    lap = laplacian(y)
    var = float(lap.var())
    scene_var = float(y.var())
    # Normalising by the image's own variance cancels most of the dependence
    # on scene contrast and exposure level (guide 6.4).
    norm = var / scene_var if scene_var > 1e-6 else 0.0
    return {
        f"{label}_lap_var": var,
        f"{label}_scene_var": scene_var,
        f"{label}_lap_norm": norm,
    }


def center_crop(y, cw, ch):
    h, w = y.shape
    cw, ch = min(cw, w), min(ch, h)
    y0 = (h - ch) // 2
    x0 = (w - cw) // 2
    return y[y0 : y0 + ch, x0 : x0 + cw]


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
def verdict(ex):
    notes = []
    if ex["mean"] < MEAN_LO:
        notes.append("UNDER: mean below target band")
    elif ex["mean"] > MEAN_HI:
        notes.append("OVER: mean above target band")
    if ex["clipped_pct"] > CLIP_MAX:
        notes.append(f"CLIPPED: {ex['clipped_pct']:.1f}% highlights lost")
    if ex["crushed_pct"] > CRUSH_MAX:
        notes.append(f"CRUSHED: {ex['crushed_pct']:.1f}% shadows lost")
    if ex["max"] < 200:
        notes.append(f"RANGE: peak only {ex['max']}/255, headroom unused")
    return notes or ["OK: within target band"]


def report(path, y_full, y_crop, n_frames, args):
    ex_f = exposure_stats(y_full)
    ex_c = exposure_stats(y_crop)
    fs_f = focus_stats(y_full, "full")
    fs_c = focus_stats(y_crop, "crop")

    print(f"=== {os.path.basename(path)}")
    print(f"    geometry     {args.width}x{args.height} YUYV 4:2:2")
    print(f"    frames       {n_frames:.2f} in file, analysing index {args.frame}")
    if args.linear:
        print(f"    linearised   gamma {GAMMA} removed")
    print()
    print("--- EXPOSURE (full frame)")
    print(f"    luma mean    {ex_f['mean']:7.2f} / 255")
    print(f"    min / max    {ex_f['min']:3d} / {ex_f['max']:3d}")
    print(f"    clipped      {ex_f['clipped_pct']:6.2f} %   (Y >= 250)")
    print(f"    crushed      {ex_f['crushed_pct']:6.2f} %   (Y <=   5)")
    for n in verdict(ex_f):
        print(f"    >> {n}")
    print()
    print(f"--- FOCUS  (crop {y_crop.shape[1]}x{y_crop.shape[0]} centred)")
    print(f"    crop mean    {ex_c['mean']:7.2f} / 255")
    print(f"    lap var      {fs_c['crop_lap_var']:9.2f}   <- compare within a sweep only")
    print(f"    scene var    {fs_c['crop_scene_var']:9.2f}")
    print(f"    normalised   {fs_c['crop_lap_norm']:9.5f}   <- compare across exposures")
    print()
    print("--- FOCUS  (full frame, for reference)")
    print(f"    lap var      {fs_f['full_lap_var']:9.2f}")
    print(f"    normalised   {fs_f['full_lap_norm']:9.5f}")
    print()
    print("    NOTE: Laplacian variance is scene-dependent and rewards sensor")
    print("          noise. Valid only as a peak-finder within one locked-down")
    print("          sweep where framing, aperture and exposure are unchanged.")


def csv_row(y_full, y_crop):
    ex = exposure_stats(y_full)
    fs = focus_stats(y_crop, "crop")
    fields = [
        f"{ex['mean']:.2f}",
        f"{ex['max']}",
        f"{ex['clipped_pct']:.2f}",
        f"{ex['crushed_pct']:.2f}",
        f"{fs['crop_lap_var']:.2f}",
        f"{fs['crop_lap_norm']:.5f}",
    ]
    print(",".join(fields))


# ---------------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("file")
    p.add_argument("-W", "--width", type=int, default=DEFAULT_W)
    p.add_argument("-H", "--height", type=int, default=DEFAULT_H)
    p.add_argument("-f", "--frame", type=int, default=0,
                   help="zero-based frame index within a multi-frame file")
    p.add_argument("--crop", default=DEFAULT_CROP,
                   help="centre crop WxH for the focus metric (default 600x400)")
    p.add_argument("--csv", action="store_true",
                   help="emit one CSV row: mean,max,clip,crush,lap,lapnorm")
    p.add_argument("--linear", action="store_true",
                   help="remove display gamma before computing statistics")
    args = p.parse_args()

    try:
        cw, ch = (int(v) for v in args.crop.lower().split("x"))
    except ValueError:
        raise SystemExit(f"ERROR: --crop wants WxH, got '{args.crop}'")

    y, n_frames = load_luma(args.file, args.width, args.height,
                            args.frame, args.linear)
    y_crop = center_crop(y, cw, ch)

    if args.csv:
        csv_row(y, y_crop)
    else:
        report(args.file, y, y_crop, n_frames, args)


if __name__ == "__main__":
    main()
