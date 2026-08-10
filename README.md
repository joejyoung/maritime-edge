# Argus-Sentinel

**Long-range maritime vessel detection on edge hardware.**

A fixed-view camera system for detecting and tracking vessels in a commercial shipping
lane at multi-kilometer range, running inference on a low-power embedded GPU platform.

The working thesis of this repository is that in a deployed long-range maritime vision
system, the binding constraint is the **capture chain** — optics, sensor format, link
bandwidth, and exposure control — not GPU throughput or model architecture. Most of the
current material here is therefore instrumentation and measurement of that chain, not
model training.

---

## Table of Contents

- [Problem Statement](#problem-statement)
- [Hardware Stack](#hardware-stack)
- [Software Environment](#software-environment)
- [Optical Budget](#optical-budget)
- [Capture Chain Constraints](#capture-chain-constraints)
- [Known Issues](#known-issues)
- [Tooling](#tooling)
- [Measured Findings](#measured-findings)
- [Roadmap](#roadmap)
- [License](#license)

---

## Problem Statement

Standard object-detection pipelines are tuned for terrestrial scenes at moderate range.
Over open water at 1–3 miles, several assumptions break simultaneously:

1. **Tiny-object scale.** A mid-size vessel occupies tens of pixels on the sensor and
   single-digit pixels after the resize into a detector's input resolution. Backbone
   downsampling erases the target before the detection head ever sees it.
2. **Specular clutter.** Sun glint, wakes, and whitecaps produce high-contrast blobs with
   edge statistics similar to distant hulls, driving false positives.
3. **Atmospheric degradation.** Haze, humidity, and thermal shimmer reduce target contrast
   and warp boundaries before the light reaches the front element.
4. **Jitter amplification.** Long focal lengths convert sub-millimeter mount flex into
   large frame-to-frame displacement, which breaks IOU-based tracking association.
5. **Domain gap.** Public maritime datasets are dominated by close-to-medium-range harbor
   imagery with rich visual detail. At operational range, a vessel is a featureless blob.

The system is a static installation on a fixed rooftop mount with an unobstructed
sightline to a shipping lane. The mount does not pan or tilt; the field of view is fixed
and framed once per configuration.

---

## Hardware Stack

### Compute

| Item | Spec |
|---|---|
| Board | NVIDIA Jetson Orin Nano Developer Kit, 8 GB |
| Memory | 7.3 GB unified CPU/GPU + 8 GB swap |
| Storage | NVMe SSD, NVMe boot |
| Power mode | 15 W (must be recorded alongside every latency figure) |
| Video engines | NVDEC present; **no NVENC** (H.264/265 encode is CPU-bound); NVJPG present |

The absence of a hardware encoder is a real design constraint: sustained recording either
burns CPU on software encode or writes NVJPG stills via `nvjpegenc`.

### Camera

| Item | Spec |
|---|---|
| Module | Arducam B0498 (USB 3.0, 8.3 MP) |
| Sensor | Sony IMX585, STARVIS 2, 1/1.2" optical format, 2.9 µm pixels |
| Interface | USB 3.0 UVC (`uvcvideo`), **not** MIPI CSI |
| Mount | CS-mount body, ships with 5 mm C-ring |
| Pixel format | **YUYV 4:2:2 only** — no MJPEG, no compressed path |
| Colorspace | sRGB, BT.601 encoding, limited range |

Because the module is USB/UVC rather than CSI, the capture stage uses `v4l2src`, not
`nvarguscamerasrc`, and the camera's on-board ISP is used instead of the Jetson hardware
ISP.

**Supported modes:**

| Resolution | Frame rates |
|---|---|
| 3840 × 2160 | 15 / 10 / 5 fps |
| 1920 × 1080 | 60 / 30 / 15 fps |
| 1280 × 720 | 90 / 60 / 30 / 15 fps |

**Exposed V4L2 controls:** `brightness` (−64…64), `contrast` (0…20), `saturation` (0…15),
`white_balance_automatic`, `white_balance_temperature` (2300…6500), `gain` (100…4000),
`backlight_compensation`, `power_line_frequency`, `auto_exposure` (Auto / Manual),
`exposure_time_absolute` (5…250000, units of ~100 µs per UVC convention).

### Optics

| Item | Role |
|---|---|
| 16 mm f/1.4 C-mount fixed lens (stock) | Wide baseline; lane survey; chroma/exposure characterization |
| Canon EF 75–300 mm telephoto | Reach configuration; ~250–1000 mm equivalent after crop |
| Passive EF → C-mount adapter | No electronic contacts |
| 58 mm lens hood | Suppresses sun glint and veiling haze |
| Tripod collar ring | Carries lens mass at its center of gravity |

**Crop factor.** A full-frame EF lens (43 mm image circle) on a 1/1.2" sensor
(12.85 mm diagonal) gives a **~3.35× crop**. The full-frame image circle massively
over-covers the sensor, so there is no vignetting.

**Passive adapter caveat.** With no electronic contacts, aperture behavior depends on the
lens. The 75–300 mm uses a mechanical aperture ring, so it can be stopped down manually.
Canon EF lenses with electromagnetic diaphragms will sit at their default aperture and
cannot be controlled through a passive adapter — verify per lens before assuming
aperture control exists.

**Deferred: IR-pass filtering.** The IMX585 is IR-enhanced, but the module retains an
internal IR-cut window. A front IR-pass filter fights that internal filter and yields a
near-black image unless the internal filter is removed (destructive). NIR is treated as a
deliberate later-phase comparative experiment with a characterized band-pass filter
(720 / 850 nm), not as default configuration.

### Development and Training Hardware

| Role | Platform |
|---|---|
| Primary development | x86 workstation under WSL2, RTX 4070 Laptop 8 GB |
| Edge deployment / on-device latency | Jetson Orin Nano (above) |
| Production training | Institutional HPC cluster (A100 / H100) |

These are separate machines and the distinction is load-bearing. ONNX export happens
off-device on x86; TensorRT engine builds and all latency measurements happen on the
Jetson. Any figure quoted from this repository is labeled with the machine it came from.

---

## Software Environment

| Component | Version |
|---|---|
| JetPack | 7.2-b187 |
| L4T | R39.2.0 |
| OS | Ubuntu 24.04 LTS |
| Kernel | 6.8 (tegra) |
| Python | 3.12 |
| CUDA | 13.2 |
| cuDNN | 9.20.0.46 |
| TensorRT | 10.16.2.10 |
| VPI | 4.1.3 |
| PyTorch | 2.13.0+cu132 (JetPack-managed) |

### Environment Topology

Three environments, deliberately separated:

1. **Workstation dev environment** (x86 / WSL2) — detector experiments and ONNX export.
   Pinned to keep the detector version consistent across analysis runs.
2. **On-device project venv** (Jetson) — created with `--system-site-packages`. This flag
   is **mandatory**: the TensorRT Python bindings are system-installed and are not
   available inside an isolated venv. The JetPack-managed PyTorch build must never be
   touched by `pip`.
3. **No Python environment for `trtexec`** — it is a compiled system binary at
   `/usr/src/tensorrt/bin/trtexec`.

### Known Environment Gotchas

- **PyTorch `sm_87` compatibility warning is a false alarm.** The build's static
  architecture list contains no PTX entry for `sm_87`, but CUDA minor-version forward
  binary compatibility allows `sm_80` cubins to execute on `sm_87`. No JIT occurs —
  there is no PTX to compile from. Deployment latency is unaffected because TensorRT
  compiles natively for `sm_87` on-device.
- **`cuda-python` is not importable** on this image. Allocate CUDA memory through
  PyTorch `.data_ptr()` instead.
- **TensorRT 10 uses the tensor-addressed v3 API**, not the older bindings-based v2 API.
- **`trtexec` workspace flag:** use `--memPoolSize=workspace:2048`; `--workspace` is
  deprecated.

---

## Optical Budget

The pixel budget is the first-order constraint and it is unforgiving.

**Worked example — 3 m vessel at 5 km:**

| Stage | Result |
|---|---|
| Projected size on sensor | ~62 px |
| After naive downscale to `imgsz=640` | ~10.4 px |
| P3 (stride-8) feature cells covered | ~1.30 |

A target that lands on roughly one stride-8 cell is not detectable by a standard
single-shot head. **SAHI tiling is mandatory, not optional.**

Note the crop-versus-bin distinction: a center crop to 640 preserves the full ~62 px
target; a naive full-frame downscale to 640 gives roughly half that. The choice of
resize strategy is worth more than most architecture changes at this scale.

**Geometric field of view and pixels-on-target (40 ft vessel at 1 mile, 3840 × 2160):**

| Lens | FOV (H × V) | Scene width @ 1 mi | Vessel size | Note |
|---|---|---|---|---|
| 16 mm stock | 38.5° × 22.4° | 1,125 m | 42 × 21 px | At the feature-collapse edge |
| 75 mm (wide end) | 8.5° × 4.8° | 240 m | 196 × 96 px | Good for lane coverage / acquisition |
| 300 mm (tele end) | 2.1° × 1.2° | 60 m | 784 × 386 px | Supports classification |
| 900 mm equivalent | 0.7° × 0.4° | 20 m | 2351 × 1157 px | FOV too tight for lane survey |

*Geometric best case. Real usable pixels are lower after atmospheric contrast loss and
residual mount jitter, both amplified by the crop factor.*

**Hyperfocal note.** At 16 mm, f/5.6, with a circle of confusion of ~8.6 µm, the
hyperfocal distance is ~5.33 m and the near limit ~2.67 m. At this focal length, focus
setting is never a factor for distant subjects — everything past a few meters is sharp.
This stops being true on the telephoto configuration.

---

## Capture Chain Constraints

**Link bandwidth is the ceiling, not the sensor.** The USB bridge tops out around
2 Gbps. YUYV 4:2:2 is uncompressed at 2 bytes per pixel, so:

```
3840 × 2160 × 2 × 15 fps = 248,832,000 B/s  ≈ 1.99 Gbps
1920 × 1080 × 2 × 60 fps = 248,832,000 B/s  ≈ 1.99 Gbps
```

4K@15 and 1080p@60 are **byte-identical** on the wire. The mode table is not a menu of
independent options; it is a set of points on one bandwidth budget. With no MJPEG path
available, there is no way to buy back headroom through compression.

**USB link negotiation.** The module intermittently enumerates at USB 2 speed (480M) on
first connection. SuperSpeed (5000M) requires a physical replug — a soft reset does not
recover it. Verify the negotiated speed before trusting any capture; a USB 2 link
silently caps the camera at low resolution and frame rate. The device serial suffix is
the programmatic indicator that the SuperSpeed path came up.

**USB adapter power management.** Selective-suspend behavior on some USB Ethernet
adapter chipsets drops carrier during idle sessions. This was the confirmed root cause of
earlier connection instability and is not a network configuration problem.

---

## Known Issues

### 1. Exposure / integration decoupling (OPEN)

Writes to `exposure_time_absolute` are accepted and echoed back exactly (8000, 30000,
60000 all read back correctly; the control reports active and unclamped). **Frame period
responds** — roughly 670 ms at 8000 units, ~2.4 s above 20000. **Luma does not.** A
confirmed 1.9-stop increase in commanded integration time produced no change in frame
brightness.

Gain, by contrast, responds normally and monotonically:

| Gain | Mean Y |
|---|---|
| 100 | 5.0 |
| 400 | 10.6 |
| 1600 | 27.6 |
| 4000 | 53.3 |

Leading hypothesis: the firmware extends frame length (VMAX) without moving the shutter
position register (SHR), so frames lengthen but the integration window does not.
Exposure units are order 100 µs, confirmed by frame-timing evidence.

*Pending test:* daylight downward sweep (100 → 16000 units) at the gain floor, to locate
the point at which luma stops tracking exposure.

### 2. V4L2 control ordering (root cause confirmed)

Setting `auto_exposure=1` (Manual) *activates* `exposure_time_absolute`, which then
adopts whatever value is cached in the driver. The default cached value is 5 (~500 µs),
which produces a black frame. Setting the two controls in separate calls inherits the
stale value.

**Fix — one comma-separated write:**

```bash
v4l2-ctl -d /dev/video0 -c auto_exposure=1,exposure_time_absolute=20000
```

Corollary: while a control is flagged inactive, its reported `value=` field is inert and
says nothing about sensor state. Do not read it as ground truth.

### 3. Green color cast (mechanism confirmed)

Chroma channels are **not** arriving as zero — U and V carry measured real signal. The
OpenCV double-conversion hypothesis and the `nvvidconv`/YUY2 hypothesis were both
eliminated for `v4l2-ctl` captures.

Actual mechanism: at low luma, the BT.601 luma term `1.164 × (Y − 16)` shrinks until the
chroma difference terms dominate, driving R negative, where it clips to 0 while G
survives. **The green cast is a downstream symptom of underexposure, not a color
conversion bug.** Fix exposure, not the conversion code.

### 4. Storage I/O timeouts

NVMe APST (autonomous power state transition) is the likely cause of intermittent I/O
timeouts. Test with a runtime disable before applying any persistent fix.

---

## Tooling

| Script | Purpose |
|---|---|
| `argus_opticheck.sh` | Optical/capture configuration check and capture harness |
| `argus_frame_stats.py` | Per-frame luma/chroma statistics from raw captures |
| `argus-session.sh` | Session orchestration and provenance logging |
| `argus_correlate.py` | Correlates capture logs against session metadata |
| `argus_raw2png.sh` | Raw YUYV → PNG conversion for inspection |
| `chroma_sweep.py` | Chroma-degradation ablation harness (see below) |

Supporting stack: `v4l2-ctl`, GStreamer (`v4l2src`, `nvvidconv`, `nvjpegenc`,
`splitmuxsink`), `jtop`, `trtexec`.

### `chroma_sweep.py`

An ablation harness that isolates the color-conversion step from every other confound.
It takes **one** raw YUYV multi-frame capture, applies controlled signed offsets to U, V,
and UV in software, runs the detector at a fixed confidence threshold, and reports
detection count and confidence per offset with paired per-frame deltas.

The single-capture design is the point: applying offsets in software to one capture means
scene content, exposure, gain, and atmospheric conditions are held identical across all
conditions. Channel addressing on the `(H, W, 2)` YUYV layout is validated.

Note that the detector for this harness runs **off-device on the x86 workstation**. These
are capture-chain figures, not edge inference benchmarks, and must not be quoted as
latency results.

---

## Measured Findings

**Exposure and gain.**

- "Push exposure first, gain for the residual" presumes exposure has headroom. **Once
  exposure saturates, gain is the only remaining instrument** — declining to use it
  produces an unusable frame, not a cleaner one.
- The assessment that gain above ~800 is wasted range was made at bench light levels and
  does not transfer to low-light field scenes.
- Reciprocity holds 1:1 across at least a 4× range, which makes matched-brightness noise
  comparison between the two paths valid.
- At matched brightness, the exposure path is consistently cleaner than the gain path.

**Detector normalization.** Ultralytics YOLO models normalize by simple `/255` — there is
**no ImageNet mean/std subtraction**. Detector failure under color degradation must
therefore be explained by outright channel loss through clipping, not by a
normalization-statistic mismatch.

**Chroma sweep, preliminary night run.** Baseline 1.12 detections/frame at mean Y = 19.6.
Failure knee between offsets −42 and −60. Mean confidence degrades roughly two conditions
before detection count drops, making **confidence a leading indicator** of chroma-driven
failure. This baseline luma is too low to carry a claim; a daylight recapture targeting
mean Y ≈ 110 is required before these numbers are reported as results.

---

## Roadmap

- [ ] Daylight chroma-sweep recapture at operational luma
- [ ] Daylight exposure downward sweep to localize the integration decoupling fault
- [ ] Telephoto lens configuration swap and re-characterization
- [ ] SeaShips VOC → YOLO conversion (complete) → YOLOv11 training pipeline
- [ ] Investigate maritime-specific attention modules on a YOLOv11n backbone
- [ ] SAHI tiling integration and latency characterization on-device
- [ ] TensorRT FP16 / INT8 quantization and on-device latency benchmarking
- [ ] Baseline-vs-fine-tuned ablation using auto-labeled field footage
- [ ] Deferred: NIR-vs-RGB spectral comparison with a characterized band-pass filter

---

## Reporting Conventions

Enforced throughout this repository:

- Every latency figure is labeled with the **power mode** and identified as an
  **on-device measurement**.
- Off-device detector figures are labeled as capture-chain results, never as edge
  inference benchmarks.
- The `ultralytics` version used for any ONNX export is recorded alongside the exported
  artifact.
- No host names, device host names, or site identifiers appear in committed files.

---

## License

Not yet licensed. This repository is private pending review; a license will be selected
before any public release.
