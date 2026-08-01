#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# capture_env.sh — provenance snapshot for the Argus edge node.
#
# Writes a single timestamped manifest recording the software version spine,
# power state, USB link speed, and full camera capability table. Every
# reproducibility field in the daily experiment log should be able to point
# back at one of these files.
#
# Usage:  ./capture_env.sh [video_device]      # default: /dev/video0
# Output: manifests/env-<host>-<UTC timestamp>.txt
#
# Run this on the Jetson. It is deliberately read-only: it changes no state,
# installs nothing, and is safe to run before every capture session.
# ---------------------------------------------------------------------------

set -uo pipefail   # no -e: several probes are expected to fail on some hosts

VIDEO_DEV="${1:-/dev/video0}"
OUTDIR="${OUTDIR:-manifests}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTFILE="${OUTDIR}/env-$(hostname)-${STAMP}.txt"

mkdir -p "$OUTDIR"

have() { command -v "$1" >/dev/null 2>&1; }

section() {
  printf '\n===============================================================\n' >>"$OUTFILE"
  printf '  %s\n' "$1" >>"$OUTFILE"
  printf -- '===============================================================\n' >>"$OUTFILE"
}

# Run a command, capturing stdout+stderr, with a clear marker if unavailable.
probe() {
  local label="$1"; shift
  printf '\n--- %s\n' "$label" >>"$OUTFILE"
  if have "$1"; then
    "$@" >>"$OUTFILE" 2>&1 || printf '[command exited non-zero]\n' >>"$OUTFILE"
  else
    printf '[not available: %s not on PATH]\n' "$1" >>"$OUTFILE"
  fi
}

# Emit a file's contents, or note its absence.
show_file() {
  local label="$1" path="$2"
  printf '\n--- %s (%s)\n' "$label" "$path" >>"$OUTFILE"
  if [ -r "$path" ]; then cat "$path" >>"$OUTFILE" 2>&1
  else printf '[not readable or not present]\n' >>"$OUTFILE"; fi
}

# ---------------------------------------------------------------------------
: >"$OUTFILE"
printf 'ARGUS ENVIRONMENT MANIFEST\n' >>"$OUTFILE"
printf 'Captured (UTC): %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S')" >>"$OUTFILE"
printf 'Host:           %s\n' "$(hostname)" >>"$OUTFILE"
printf 'User:           %s\n' "$(whoami)" >>"$OUTFILE"
printf 'Video device:   %s\n' "$VIDEO_DEV" >>"$OUTFILE"

# ---------------------------------------------------------------------------
section "1. PLATFORM / VERSION SPINE"
show_file "L4T release" /etc/nv_tegra_release
show_file "Board model" /proc/device-tree/model
show_file "OS release"  /etc/os-release
probe "Kernel"          uname -a
probe "JetPack meta"    dpkg-query --show nvidia-l4t-core
probe "JetPack bundle"  dpkg-query --show nvidia-jetpack
probe "CUDA compiler"   nvcc --version

printf '\n--- TensorRT / cuDNN (dpkg)\n' >>"$OUTFILE"
if have dpkg-query; then
  dpkg-query -W -f='${Package} ${Version}\n' 'libnvinfer*' 'libcudnn*' 'cuda-*' \
    >>"$OUTFILE" 2>/dev/null || printf '[no matching packages]\n' >>"$OUTFILE"
fi

printf '\n--- TensorRT (python)\n' >>"$OUTFILE"
python3 - >>"$OUTFILE" 2>&1 <<'PY'
try:
    import tensorrt; print("tensorrt", tensorrt.__version__)
except Exception as e:
    print("[tensorrt import failed]", e)
try:
    import torch
    print("torch", torch.__version__, "| cuda available:", torch.cuda.is_available())
    print("torch cuda build:", torch.version.cuda)
    if torch.cuda.is_available():
        print("device:", torch.cuda.get_device_name(0))
except Exception as e:
    print("[torch import failed]", e)
PY

# ---------------------------------------------------------------------------
section "2. POWER STATE  (latency/energy numbers are void without this)"
probe "Power model"   nvpmodel -q
probe "Clock state"   jetson_clocks --show
probe "Thermals"      cat /sys/devices/virtual/thermal/thermal_zone0/temp

# ---------------------------------------------------------------------------
section "3. USB LINK  (want 5000M — 480M means USB 2 fallback)"
probe "USB topology"  lsusb -t
probe "USB devices"   lsusb

printf '\n--- Negotiated speeds per device\n' >>"$OUTFILE"
for d in /sys/bus/usb/devices/*/; do
  if [ -r "${d}speed" ]; then
    printf '%-12s speed=%-6s product=%s\n' \
      "$(basename "$d")" \
      "$(cat "${d}speed" 2>/dev/null)" \
      "$(cat "${d}product" 2>/dev/null || echo '-')" >>"$OUTFILE"
  fi
done

# ---------------------------------------------------------------------------
section "4. CAMERA CAPABILITY TABLE"
probe "V4L2 devices"      v4l2-ctl --list-devices
probe "Device caps"       v4l2-ctl -d "$VIDEO_DEV" --all
probe "Supported formats" v4l2-ctl -d "$VIDEO_DEV" --list-formats-ext
probe "Controls"          v4l2-ctl -d "$VIDEO_DEV" --list-ctrls-menus

# ---------------------------------------------------------------------------
section "5. STORAGE / MEMORY"
probe "Filesystems"  df -h
probe "Memory"       free -h
probe "Swap"         swapon --show

# ---------------------------------------------------------------------------
section "6. CODE PROVENANCE"
printf '\n--- git\n' >>"$OUTFILE"
if have git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'commit:  %s\n' "$(git rev-parse HEAD)" >>"$OUTFILE"
  printf 'branch:  %s\n' "$(git rev-parse --abbrev-ref HEAD)" >>"$OUTFILE"
  if [ -n "$(git status --porcelain)" ]; then
    printf 'tree:    DIRTY  <-- results from this state are not reproducible\n' >>"$OUTFILE"
    git status --porcelain >>"$OUTFILE"
  else
    printf 'tree:    clean\n' >>"$OUTFILE"
  fi
else
  printf '[not a git repository]\n' >>"$OUTFILE"
fi

# ---------------------------------------------------------------------------
printf '\n=== END OF MANIFEST ===\n' >>"$OUTFILE"
echo "Wrote $OUTFILE"
