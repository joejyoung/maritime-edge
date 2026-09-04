#!/usr/bin/env python3
"""
chroma_sweep.py — capture-chain degradation ablation.

Takes a single raw YUYV422 capture containing N frames, applies controlled
chroma offsets in software, and measures detector response at each offset.

The point: quantify how much capture-chain color error a pretrained detector
tolerates before performance collapses. Same source bytes forked at the
conversion step, so nothing is confounded by lighting, exposure, or scene
motion between conditions.

Capture with:
  v4l2-ctl -d /dev/argus-cam \
    --set-fmt-video=width=1920,height=1080,pixelformat=YUYV \
    --stream-mmap --stream-skip=45 --stream-count=100 --stream-to=session.raw

Usage:
  python chroma_sweep.py session.raw --axis V --offsets 0,-10,-20,-30,-42,-60,-128
  python chroma_sweep.py session.raw --axis V --dry-run        # stats only, no model
"""

import argparse
import csv
import os
import sys

import numpy as np

# ---------------------------------------------------------------------------
# YUYV handling
#
# YUYV422 packs two pixels into four bytes: Y0 U0 Y1 V0
# Reshaped to (H, W, 2):
#   [:, :, 0]      -> luma, one sample per pixel
#   [:, 0::2, 1]   -> U (Cb), one sample per pixel pair
#   [:, 1::2, 1]   -> V (Cr), one sample per pixel pair
# ---------------------------------------------------------------------------


def frame_view(mm, index, width, height):
    """Return a read-only (H, W, 2) view of frame `index` without copying."""
    stride = width * height * 2
    start = index * stride
    return mm[start:start + stride].reshape(height, width, 2)


def apply_offset(frame, axis, offset):
    """
    Return a new frame with `offset` added to the requested chroma channel(s).

    axis: 'U', 'V', or 'UV'. Offset is applied in signed space and clipped to
    the valid 8-bit range, which is the same clipping the real defect would
    experience.
    """
    out = frame.astype(np.int16)
    if axis in ("U", "UV"):
        out[:, 0::2, 1] += offset
    if axis in ("V", "UV"):
        out[:, 1::2, 1] += offset
    return np.clip(out, 0, 255).astype(np.uint8)


def channel_stats(frame):
    """Mean of each channel, for provenance in the output CSV."""
    return (
        float(frame[:, :, 0].mean()),
        float(frame[:, 0::2, 1].mean()),
        float(frame[:, 1::2, 1].mean()),
    )


def to_bgr(frame):
    """YUYV -> BGR via OpenCV's BT.601 conversion."""
    import cv2
    return cv2.cvtColor(frame, cv2.COLOR_YUV2BGR_YUY2)


# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------


def run(args):
    stride = args.width * args.height * 2
    size = os.path.getsize(args.raw)
    n_frames = size // stride

    if n_frames == 0:
        sys.exit(f"{args.raw}: {size} bytes is less than one "
                 f"{args.width}x{args.height} frame ({stride} bytes)")
    if size % stride:
        print(f"warning: {size} bytes = {size / stride:.2f} frames; "
              f"trailing {size % stride} bytes ignored", file=sys.stderr)

    if args.limit:
        n_frames = min(n_frames, args.limit)

    offsets = [int(x) for x in args.offsets.split(",")]
    print(f"{args.raw}: {n_frames} frames @ {args.width}x{args.height}")
    print(f"sweeping {args.axis} over {offsets}")

    model = None
    if not args.dry_run:
        from ultralytics import YOLO
        model = YOLO(args.model)
        print(f"model {args.model} @ conf={args.conf} imgsz={args.imgsz}")

    mm = np.memmap(args.raw, dtype=np.uint8, mode="r")
    rows = []

    for offset in offsets:
        for i in range(n_frames):
            src = frame_view(mm, i, args.width, args.height)
            frame = apply_offset(src, args.axis, offset)
            y, u, v = channel_stats(frame)

            row = {
                "offset": offset,
                "frame": i,
                "y_mean": round(y, 2),
                "u_mean": round(u, 2),
                "v_mean": round(v, 2),
                "n_det": "",
                "mean_conf": "",
            }

            if model is not None:
                bgr = to_bgr(frame)
                res = model(bgr, conf=args.conf, imgsz=args.imgsz,
                            verbose=False)[0]
                confs = res.boxes.conf.cpu().numpy() if len(res.boxes) else np.array([])
                row["n_det"] = int(len(confs))
                row["mean_conf"] = round(float(confs.mean()), 4) if confs.size else 0.0

            rows.append(row)

            if args.sample_dir and i == args.sample_frame:
                save_sample(frame, offset, args)

        done = [r for r in rows if r["offset"] == offset]
        summarize_offset(offset, done, args.dry_run)

    write_csv(args.out, rows)
    print(f"\nwrote {args.out} ({len(rows)} rows)")

    if not args.dry_run:
        report(rows, offsets, n_frames)


def save_sample(frame, offset, args):
    """Write one representative frame per offset, for slides."""
    import cv2
    os.makedirs(args.sample_dir, exist_ok=True)
    tag = f"{offset:+d}".replace("+", "p").replace("-", "m")
    path = os.path.join(args.sample_dir, f"{args.axis}_{tag}.png")
    cv2.imwrite(path, to_bgr(frame))


def summarize_offset(offset, rows, dry_run):
    y = np.mean([r["y_mean"] for r in rows])
    u = np.mean([r["u_mean"] for r in rows])
    v = np.mean([r["v_mean"] for r in rows])
    line = f"  {offset:+5d}  Y {y:6.1f}  U {u:6.1f}  V {v:6.1f}"
    if not dry_run:
        n = np.array([r["n_det"] for r in rows], dtype=float)
        line += f"  det {n.mean():6.2f} ± {n.std():5.2f}"
    print(line)


def write_csv(path, rows):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)


def report(rows, offsets, n_frames):
    """
    Paired analysis. Because every offset sees the identical source frames,
    per-frame differences against the unmodified baseline are meaningful and
    much tighter than a comparison of group means.
    """
    by_offset = {o: np.array([r["n_det"] for r in rows if r["offset"] == o],
                             dtype=float) for o in offsets}

    if 0 not in by_offset:
        print("\n(no zero-offset baseline in sweep; skipping paired analysis)")
        return

    base = by_offset[0]
    base_mean = base.mean()

    print(f"\nbaseline: {base_mean:.2f} detections/frame (n={n_frames})\n")
    print(f"{'offset':>7} {'det/frame':>11} {'sd':>7} {'Δ paired':>10} {'retained':>10}")
    for o in offsets:
        arr = by_offset[o]
        delta = (arr - base).mean()
        retained = arr.mean() / base_mean if base_mean else float("nan")
        print(f"{o:>7d} {arr.mean():>11.2f} {arr.std():>7.2f} "
              f"{delta:>10.2f} {retained:>9.1%}")

    knee = next((o for o in sorted(offsets, key=abs)
                 if base_mean and by_offset[o].mean() / base_mean < 0.5), None)
    if knee is not None:
        print(f"\n50% retention crossed at offset {knee:+d}")
    else:
        print("\nno offset in this sweep dropped below 50% retention")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("raw", help="raw YUYV422 capture (may contain many frames)")
    p.add_argument("--width", type=int, default=1920)
    p.add_argument("--height", type=int, default=1080)
    p.add_argument("--axis", choices=["U", "V", "UV"], default="V",
                   help="chroma channel to offset (default: V, which drives green)")
    p.add_argument("--offsets", default="0,-10,-20,-30,-42,-60,-128",
                   help="comma-separated signed offsets applied to the axis")
    p.add_argument("--model", default="yolo11n.pt")
    p.add_argument("--conf", type=float, default=0.25,
                   help="fixed confidence threshold, held constant across sweep")
    p.add_argument("--imgsz", type=int, default=640,
                   help="detector input size; note this downscales 1080p")
    p.add_argument("--limit", type=int, default=0, help="cap frames processed")
    p.add_argument("--out", default="chroma_sweep.csv")
    p.add_argument("--sample-dir", default="samples",
                   help="write one example frame per offset here ('' to skip)")
    p.add_argument("--sample-frame", type=int, default=0)
    p.add_argument("--dry-run", action="store_true",
                   help="channel statistics only; no model, no OpenCV")
    run(p.parse_args())


if __name__ == "__main__":
    main()
