#!/usr/bin/env bash
# argus-session.sh  (rev 1.1) — unattended capture session for the Argus rig.
#
# Rev 1.1 adds:
#   * frame_index.csv     — per-still UTC timestamps, required for AIS correlation
#   * --ais               — co-launch the AIS receiver so both logs share a window
#   * site.conf sourcing  — camera position/azimuth for geometric correlation
#
# Records continuously until Ctrl-C. Do NOT trigger per-vessel: at 300mm a
# 20-knot vessel crosses the frame in under 6 seconds, so manual triggering
# both misses transits and biases the dataset toward conspicuous vessels.
#
#   ./argus-session.sh --ais --note "midday, clear, flood tide"
#   ./argus-session.sh --stills-only --shutter 40
#
# Run inside tmux so an SSH dropout does not kill the capture:
#   tmux new -s argus  ->  run  ->  Ctrl-B D to detach  ->  tmux attach -t argus

set -uo pipefail

# ---------------------------------------------------------------- settings
ROOT="${ARGUS_DATA:-$HOME/argus-data}"
SHUTTER=40           # exposure_time_absolute, 100us units. 40 = 4ms = 1/250s
GAIN=""
STILL_Q=95
CLIP_Q=90
STILL_FPS=1
SEG_SECONDS=60
STILLS_ONLY=0
WITH_AIS=0
NOTE=""
MIN_FREE_GB=50

while [ $# -gt 0 ]; do
  case "$1" in
    --stills-only) STILLS_ONLY=1; shift ;;
    --ais)         WITH_AIS=1; shift ;;
    --shutter)     SHUTTER="$2"; shift 2 ;;
    --gain)        GAIN="$2"; shift 2 ;;
    --note)        NOTE="$2"; shift 2 ;;
    --seg)         SEG_SECONDS="$2"; shift 2 ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SESSION="$ROOT/$STAMP"

# Site geometry — needed for AIS correlation. See site.conf.example.
SITE_LAT=""; SITE_LON=""; SITE_ALT_M=""; SITE_AZIMUTH_DEG=""; FOCAL_MM=""
[ -f "$HERE/site.conf" ] && . "$HERE/site.conf"

# ---------------------------------------------------------------- preflight
echo "=== Argus session $STAMP ==="

if [ -x "$HERE/argus_camcheck.sh" ]; then
  NODE="$("$HERE/argus_camcheck.sh" --quiet)" || {
    echo "FAIL: camera not ready. Run ./argus_camcheck.sh for detail." >&2; exit 1; }
elif [ -e /dev/argus-cam ]; then
  NODE=/dev/argus-cam
else
  echo "FAIL: no argus_camcheck.sh and no /dev/argus-cam." >&2; exit 1
fi
echo "camera: $NODE"

mkdir -p "$SESSION/stills" "$SESSION/clips" "$SESSION/ais"

FREE_GB=$(df -BG --output=avail "$SESSION" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ "${FREE_GB:-0}" -lt "$MIN_FREE_GB" ]; then
  echo "FAIL: only ${FREE_GB}GB free, need >= ${MIN_FREE_GB}GB." >&2; exit 1
fi
if [ "$STILLS_ONLY" -eq 1 ]; then
  echo "space:  ${FREE_GB}GB free  (~10 GB/hr stills-only)"
else
  echo "space:  ${FREE_GB}GB free  (~60-125 GB/hr -> roughly $((FREE_GB/125))-$((FREE_GB/60)) hours)"
fi

# ---------------------------------------------------------------- controls
# auto_exposure MUST be manual before exposure_time_absolute becomes writable.
v4l2-ctl -d "$NODE" --set-ctrl=auto_exposure=1 2>/dev/null
v4l2-ctl -d "$NODE" --set-ctrl=exposure_time_absolute="$SHUTTER" 2>/dev/null
[ -n "$GAIN" ] && v4l2-ctl -d "$NODE" --set-ctrl=gain="$GAIN" 2>/dev/null

CTRLS="$(v4l2-ctl -d "$NODE" --get-ctrl=auto_exposure,exposure_time_absolute,gain 2>/dev/null | tr '\n' ' ')"
echo "controls: $CTRLS"
case "$CTRLS" in
  *"exposure_time_absolute: $SHUTTER"*) ;;
  *) echo "WARN: shutter did not take as requested — check --list-ctrls-menus" >&2 ;;
esac

# ---------------------------------------------------------------- AIS
AIS_PID=""
if [ "$WITH_AIS" -eq 1 ]; then
  if command -v AIS-catcher >/dev/null 2>&1; then
    # -o 5 = JSON lines on stdout. VERIFY against `AIS-catcher -h` for your build.
    # Keep the SDR on the USB2 bus so it does not contend with the camera.
    AIS-catcher -d:0 -o 5 -v 60 > "$SESSION/ais/ais.jsonl" 2> "$SESSION/ais/ais.log" &
    AIS_PID=$!
    sleep 2
    if kill -0 "$AIS_PID" 2>/dev/null; then
      echo "ais:    AIS-catcher running (pid $AIS_PID)"
    else
      echo "WARN: AIS-catcher exited immediately — see ais/ais.log" >&2
      AIS_PID=""
    fi
  else
    echo "WARN: --ais requested but AIS-catcher not found; continuing without." >&2
  fi
fi

# ---------------------------------------------------------------- manifest
{
  echo "session:      $STAMP"
  echo "note:         $NOTE"
  echo "host:         $(hostname)"
  echo "node:         $NODE"
  echo "controls:     $CTRLS"
  echo "still_q:      $STILL_Q @ ${STILL_FPS}fps"
  echo "clip_q:       $CLIP_Q @ 15fps, ${SEG_SECONDS}s segments"
  echo "stills_only:  $STILLS_ONLY"
  echo "ais:          $([ -n "$AIS_PID" ] && echo yes || echo no)"
  echo "site_lat:     ${SITE_LAT:-unset}"
  echo "site_lon:     ${SITE_LON:-unset}"
  echo "site_alt_m:   ${SITE_ALT_M:-unset}"
  echo "site_azimuth: ${SITE_AZIMUTH_DEG:-unset}"
  echo "focal_mm:     ${FOCAL_MM:-unset}"
  echo "nvpmodel:     $(nvpmodel -q 2>/dev/null | tr '\n' ' ')"
  echo "ntp_synced:   $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
  echo "git:          $(cd "$HERE" && git rev-parse --short HEAD 2>/dev/null || echo n/a)"
  echo "started:      $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
} > "$SESSION/manifest.txt"

# NTP sync is a hard requirement for AIS correlation — warn loudly if absent.
if [ "$WITH_AIS" -eq 1 ] && \
   [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]; then
  echo "WARN: clock not NTP-synced. AIS/frame correlation will be unreliable." >&2
fi

# ---------------------------------------------------------------- pipeline
# tee on the raw YUY2 stream. The stills branch drops 14 of 15 frames with
# videorate BEFORE conversion, so it costs almost nothing. A queue on each
# tee branch is mandatory — without it the branches deadlock.
STILL_BRANCH="t. ! queue max-size-buffers=4 leaky=downstream \
  ! videorate ! video/x-raw,framerate=${STILL_FPS}/1 \
  ! nvvidconv ! video/x-raw(memory:NVMM),format=I420 \
  ! nvjpegenc quality=$STILL_Q \
  ! multifilesink location=$SESSION/stills/still_%06d.jpg"

CLIP_BRANCH=""
if [ "$STILLS_ONLY" -eq 0 ]; then
  CLIP_BRANCH="t. ! queue max-size-buffers=8 \
    ! nvvidconv ! video/x-raw(memory:NVMM),format=I420 \
    ! nvjpegenc quality=$CLIP_Q ! jpegparse \
    ! splitmuxsink muxer-factory=matroskamux \
        max-size-time=$((SEG_SECONDS * 1000000000)) \
        location=$SESSION/clips/clip_%04d.mkv"
fi

cleanup() { [ -n "$AIS_PID" ] && kill -TERM "$AIS_PID" 2>/dev/null; }
trap cleanup EXIT

echo
echo "recording -> $SESSION"
echo "Ctrl-C to stop cleanly (finalises the last clip segment)."
echo

# -e sends EOS on SIGINT so splitmuxsink closes the final file properly.
gst-launch-1.0 -e \
  v4l2src device="$NODE" io-mode=2 \
  ! video/x-raw,format=YUY2,width=3840,height=2160,framerate=15/1 \
  ! tee name=t \
  $STILL_BRANCH \
  $CLIP_BRANCH

cleanup; trap - EXIT

# ------------------------------------------------- frame index (for AIS join)
# multifilesink cannot embed timestamps in filenames, so the index is built
# from file mtime. On ext4 this is sub-second and adequate: AIS position
# reports arrive every 2-10s and are interpolated during correlation anyway.
echo "building frame index..."
{
  echo "filename,utc_iso,epoch"
  find "$SESSION/stills" -name '*.jpg' -printf '%f\t%T@\n' 2>/dev/null | sort |
  while IFS=$'\t' read -r f epoch; do
    printf '%s,%s,%s\n' "$f" "$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%S.%3NZ)" "$epoch"
  done
} > "$SESSION/frame_index.csv"

# ---------------------------------------------------------------- wrap up
NSTILL=$(find "$SESSION/stills" -name '*.jpg' | wc -l)
NCLIP=$(find "$SESSION/clips" -name '*.mkv' | wc -l)
NAIS=0
[ -f "$SESSION/ais/ais.jsonl" ] && NAIS=$(wc -l < "$SESSION/ais/ais.jsonl")
SIZE=$(du -sh "$SESSION" | cut -f1)
{
  echo "ended:        $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  echo "stills:       $NSTILL"
  echo "clips:        $NCLIP"
  echo "ais_messages: $NAIS"
  echo "size:         $SIZE"
} >> "$SESSION/manifest.txt"

echo
echo "=== session complete ==="
echo "  stills: $NSTILL   clips: $NCLIP   ais msgs: $NAIS   size: $SIZE"
echo "  $SESSION"
echo
echo "Offload:  rsync -avh --progress argus.local:$SESSION/ ./$STAMP/"
echo "Log this session in the DOPE book before you leave the site."
