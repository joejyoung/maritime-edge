#!/usr/bin/env python3
"""
argus_correlate.py — join AIS tracks against captured frames to produce
geometric ground truth for the Argus maritime detection dataset.

For every still, this computes which AIS-reporting vessels were inside the
camera's field of view, their slant range, their predicted horizontal pixel
position, and their predicted pixel length. Output is a per-frame CSV that
can be used to:

  * validate the optical model against real targets at known range
  * stratify detection metrics by vessel length and range
  * bootstrap labels for AIS-equipped vessels
  * measure recall against vessels KNOWN to have been present

Run on the workstation after offload, not on the Jetson.

    python3 argus_correlate.py SESSION_DIR [--max-range-km 15]

Requires:  pip install pyais
"""

import argparse
import csv
import json
import math
import sys
from bisect import bisect_left
from datetime import datetime, timezone
from pathlib import Path

# ----------------------------------------------------------------- geometry
# Arducam IMX585, 1/1.2" sensor, 16:9 readout.
SENSOR_W_MM = 12.85 * 16 / math.hypot(16, 9)   # = 11.20 mm
IMAGE_W_PX = 3840
IMAGE_H_PX = 2160
EARTH_R_M = 6_371_000.0


def hfov_rad(focal_mm: float) -> float:
    """Horizontal field of view for a given focal length on this sensor."""
    return 2.0 * math.atan(SENSOR_W_MM / (2.0 * focal_mm))


def haversine_m(lat1, lon1, lat2, lon2) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_R_M * math.asin(math.sqrt(a))


def bearing_deg(lat1, lon1, lat2, lon2) -> float:
    """Initial true bearing from point 1 to point 2, degrees clockwise from north."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def angle_diff(a, b) -> float:
    """Signed smallest difference a - b, in [-180, 180)."""
    return (a - b + 180.0) % 360.0 - 180.0


def predict_px_length(length_m, range_m, fov) -> float:
    """
    Pixel extent of a broadside vessel via the small-angle approximation.
    Verified: 3 m at 5 km through 300 mm gives 61.7 px, matching the
    hand-computed figure in the hardware reference.
    """
    if range_m <= 0:
        return float("nan")
    return (length_m / range_m) / fov * IMAGE_W_PX


# ------------------------------------------------------------------- config
def load_site(session: Path) -> dict:
    """Pull site geometry out of the session manifest written at capture time."""
    site = {}
    man = session / "manifest.txt"
    if not man.exists():
        sys.exit(f"no manifest.txt in {session}")
    for line in man.read_text().splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            site[k.strip()] = v.strip()
    required = ["site_lat", "site_lon", "site_azimuth", "focal_mm"]
    missing = [k for k in required if site.get(k, "unset") in ("unset", "")]
    if missing:
        sys.exit(
            "manifest is missing site geometry: " + ", ".join(missing) +
            "\nPopulate site.conf before the session, or edit manifest.txt by hand."
        )
    return site


# ---------------------------------------------------------------- AIS input
def load_ais(session: Path):
    """
    Read AIS-catcher JSON-lines output into position reports and static data.

    Position reports  : msg types 1,2,3 (Class A), 18,19 (Class B)
    Static / voyage   : msg types 5 (Class A), 24 (Class B) -> name, type, dims

    Field names vary between AIS-catcher versions; this reads defensively and
    reports what it could not parse rather than failing silently.
    """
    path = session / "ais" / "ais.jsonl"
    if not path.exists():
        sys.exit(f"no AIS log at {path} — was the session run with --ais?")

    positions = {}   # mmsi -> [(epoch, lat, lon, sog, cog), ...]
    static = {}      # mmsi -> {name, ship_type, length_m, beam_m}
    skipped = 0

    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except json.JSONDecodeError:
            skipped += 1
            continue

        mmsi = m.get("mmsi")
        mtype = m.get("type") or m.get("msg_type")
        if mmsi is None or mtype is None:
            skipped += 1
            continue

        # Timestamp: prefer the receiver's rxtime, fall back to any ISO field.
        ts = m.get("rxtime") or m.get("timestamp") or m.get("received_at")
        epoch = None
        if isinstance(ts, (int, float)):
            epoch = float(ts)
        elif isinstance(ts, str):
            for fmt in ("%Y%m%d%H%M%S", "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%SZ"):
                try:
                    dt = datetime.strptime(ts, fmt)
                    if dt.tzinfo is None:
                        dt = dt.replace(tzinfo=timezone.utc)
                    epoch = dt.timestamp()
                    break
                except ValueError:
                    continue
        if epoch is None:
            skipped += 1
            continue

        if mtype in (1, 2, 3, 18, 19):
            lat, lon = m.get("lat"), m.get("lon")
            if lat is None or lon is None or abs(lat) > 90 or abs(lon) > 180:
                skipped += 1
                continue
            positions.setdefault(mmsi, []).append(
                (epoch, float(lat), float(lon), m.get("speed"), m.get("course"))
            )

        if mtype in (5, 19, 24):
            # Dimensions are offsets from the GPS antenna, in metres.
            to_bow = m.get("to_bow") or m.get("dimension_to_bow")
            to_stern = m.get("to_stern") or m.get("dimension_to_stern")
            to_port = m.get("to_port") or m.get("dimension_to_port")
            to_star = m.get("to_starboard") or m.get("dimension_to_starboard")
            rec = static.setdefault(mmsi, {})
            if m.get("shipname"):
                rec["name"] = str(m["shipname"]).strip()
            if m.get("shiptype") is not None:
                rec["ship_type"] = m["shiptype"]
            if to_bow is not None and to_stern is not None:
                rec["length_m"] = float(to_bow) + float(to_stern)
            if to_port is not None and to_star is not None:
                rec["beam_m"] = float(to_port) + float(to_star)

    for mmsi in positions:
        positions[mmsi].sort(key=lambda r: r[0])

    return positions, static, skipped


def interp_position(track, t):
    """Linear interpolation of a vessel track to time t. None if t is outside
    the track window or the bracketing reports are too far apart to trust."""
    times = [r[0] for r in track]
    i = bisect_left(times, t)
    if i == 0 or i >= len(times):
        return None
    t0, lat0, lon0, *_ = track[i - 1]
    t1, lat1, lon1, *_ = track[i]
    gap = t1 - t0
    if gap > 120:          # >2 min between reports: do not interpolate across
        return None
    if gap <= 0:
        return lat0, lon0
    f = (t - t0) / gap
    return lat0 + (lat1 - lat0) * f, lon0 + (lon1 - lon0) * f


# -------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session", type=Path)
    ap.add_argument("--max-range-km", type=float, default=15.0)
    ap.add_argument("--fov-margin", type=float, default=1.2,
                    help="widen FOV by this factor to catch pointing error")
    ap.add_argument("-o", "--output", type=Path, default=None)
    args = ap.parse_args()

    session = args.session
    site = load_site(session)
    cam_lat = float(site["site_lat"])
    cam_lon = float(site["site_lon"])
    cam_az = float(site["site_azimuth"])
    focal = float(site["focal_mm"])
    fov = hfov_rad(focal)
    half_fov_deg = math.degrees(fov) / 2.0 * args.fov_margin

    print(f"site      {cam_lat:.6f}, {cam_lon:.6f}  az {cam_az:.1f}deg")
    print(f"optics    {focal:.0f}mm -> HFOV {math.degrees(fov):.3f}deg "
          f"(+/-{half_fov_deg:.3f}deg with margin)")

    positions, static, skipped = load_ais(session)
    n_reports = sum(len(v) for v in positions.values())
    print(f"ais       {len(positions)} vessels, {n_reports} position reports, "
          f"{len(static)} with static data, {skipped} lines unparsed")

    idx = session / "frame_index.csv"
    if not idx.exists():
        sys.exit(f"no frame_index.csv in {session}")
    with idx.open() as fh:
        frames = list(csv.DictReader(fh))
    print(f"frames    {len(frames)}")

    out_path = args.output or (session / "ais_ground_truth.csv")
    cols = ["filename", "utc_iso", "mmsi", "name", "ship_type",
            "range_m", "bearing_deg", "bearing_offset_deg",
            "predicted_x_px", "length_m", "predicted_px_length"]

    hits = 0
    frames_with_target = 0
    with out_path.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        for fr in frames:
            t = float(fr["epoch"])
            found = False
            for mmsi, track in positions.items():
                p = interp_position(track, t)
                if p is None:
                    continue
                lat, lon = p
                rng = haversine_m(cam_lat, cam_lon, lat, lon)
                if rng > args.max_range_km * 1000:
                    continue
                brg = bearing_deg(cam_lat, cam_lon, lat, lon)
                off = angle_diff(brg, cam_az)
                if abs(off) > half_fov_deg:
                    continue

                st = static.get(mmsi, {})
                length_m = st.get("length_m")
                px_len = (predict_px_length(length_m, rng, fov)
                          if length_m else None)
                # Horizontal pixel position from bearing offset.
                x_px = IMAGE_W_PX / 2 + (math.radians(off) / fov) * IMAGE_W_PX

                w.writerow({
                    "filename": fr["filename"],
                    "utc_iso": fr["utc_iso"],
                    "mmsi": mmsi,
                    "name": st.get("name", ""),
                    "ship_type": st.get("ship_type", ""),
                    "range_m": f"{rng:.0f}",
                    "bearing_deg": f"{brg:.3f}",
                    "bearing_offset_deg": f"{off:.3f}",
                    "predicted_x_px": f"{x_px:.0f}",
                    "length_m": f"{length_m:.0f}" if length_m else "",
                    "predicted_px_length": f"{px_len:.1f}" if px_len else "",
                })
                hits += 1
                found = True
            if found:
                frames_with_target += 1

    pct = frames_with_target / len(frames) * 100 if frames else 0
    print(f"\nwrote     {out_path}")
    print(f"          {hits} frame-vessel pairs across "
          f"{frames_with_target} frames ({pct:.1f}% of session)")
    print("\nNOTE: AIS is high-precision but low-recall ground truth. Vessels")
    print("without transponders — most small craft — are absent from this file")
    print("but present in the imagery. Frames with no AIS hit are NOT negatives.")


if __name__ == "__main__":
    main()
