#!/usr/bin/env bash
# argus_opticheck.sh — optics + exposure diagnostics for the Argus rig.
#
# Companion to argus_camcheck.sh (link/enumeration) and argus_frame_stats.py
# (measurement). This script owns the interaction between the mechanical
# controls on the lens barrel and the V4L2 controls on the sensor.
#
#   status          report link, format, controls, and clamp headroom
#   set             apply exposure/gain in the correct order, verify readback
#   shot            capture one frame, measure it, append a DOPE row
#   sweep-exposure  bracket exposure at fixed gain
#   sweep-gain      bracket gain at fixed exposure
#   sweep-focus     interactive focus-ring sweep at locked exposure
#
# The mechanical state (aperture, focus mark, focal length) is INVISIBLE to
# V4L2. It must be supplied by hand or the DOPE log is worthless. See guide 3.6.

set -uo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
VID_PID="04b4:0498"
DEV="${ARGUS_DEV:-}"
WIDTH="${ARGUS_W:-1920}"
HEIGHT="${ARGUS_H:-1080}"
FPS="${ARGUS_FPS:-15}"
SKIP="${ARGUS_SKIP:-9}"
CROP="${ARGUS_CROP:-600x400}"
OUTDIR="${ARGUS_OUTDIR:-./captures}"
DOPE="${ARGUS_DOPE:-./dope_book.csv}"
STATS="${ARGUS_STATS:-$(dirname "$0")/argus_frame_stats.py}"

# Mechanical state — no way to read these back from the device.
LENS="${ARGUS_LENS:-16mm-stock}"
FOCAL="${ARGUS_FOCAL:-16}"
APERTURE="${ARGUS_APERTURE:-unset}"
FOCUS_MARK="${ARGUS_FOCUS:-unset}"
RANGE_M="${ARGUS_RANGE:-unset}"
CONDITIONS="${ARGUS_COND:-bench}"
NOTES="${ARGUS_NOTES:-}"

C_OK=$'\033[0;32m'; C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'
C_HDR=$'\033[1;36m'; C_OFF=$'\033[0m'
[[ -t 1 ]] || { C_OK=""; C_WARN=""; C_ERR=""; C_HDR=""; C_OFF=""; }

ok()   { printf '  %s[ OK ]%s   %s\n' "$C_OK"   "$C_OFF" "$*"; }
warn() { printf '  %s[WARN]%s   %s\n' "$C_WARN" "$C_OFF" "$*"; }
err()  { printf '  %s[FAIL]%s   %s\n' "$C_ERR"  "$C_OFF" "$*"; }
hdr()  { printf '\n%s=== %s%s\n' "$C_HDR" "$*" "$C_OFF"; }
note() { printf '           %s\n' "$*"; }

# --------------------------------------------------------------------------
# Device resolution
# --------------------------------------------------------------------------
resolve_device() {
    [[ -n "$DEV" ]] && { [[ -e "$DEV" ]] || { err "ARGUS_DEV=$DEV does not exist"; exit 1; }; return; }
    [[ -e /dev/argus-cam ]] && { DEV=/dev/argus-cam; return; }

    local node
    for node in /dev/video*; do
        [[ -e "$node" ]] || continue
        local info vid pid
        info=$(udevadm info --query=property --name="$node" 2>/dev/null) || continue
        vid=$(sed -n 's/^ID_VENDOR_ID=//p'  <<<"$info")
        pid=$(sed -n 's/^ID_MODEL_ID=//p'   <<<"$info")
        [[ "${vid}:${pid}" == "$VID_PID" ]] || continue
        # Skip metadata-only nodes: keep the first with a capture format.
        v4l2-ctl -d "$node" --list-formats 2>/dev/null | grep -q "'YUYV'" || continue
        DEV="$node"; return
    done
    err "no device matching $VID_PID with a YUYV capture format"
    exit 1
}

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
# v4l2-ctl prints menu controls as "name: 1 (Manual Mode)" and int controls as
# "name: 200". Take the first token after the colon so both parse to a bare number.
get_ctrl() {
    v4l2-ctl -d "$DEV" --get-ctrl="$1" 2>/dev/null \
        | sed -n 's/^[^:]*:[[:space:]]*//p' | awk '{print $1}'
}

# Exposure is in 100 us units, and cannot exceed one frame period.
max_exposure_for_fps() { awk -v f="$1" 'BEGIN{printf "%d", int(10000/f)}'; }
exposure_ms()          { awk -v e="$1" 'BEGIN{printf "%.2f", e/10}'; }
exposure_frac()        { awk -v e="$1" 'BEGIN{if(e>0) printf "1/%d", 10000/e; else printf "n/a"}'; }
gain_x()               { awk -v g="$1" 'BEGIN{printf "%.2f", g/100}'; }

link_speed() {
    local sysdev
    for sysdev in /sys/bus/usb/devices/*; do
        [[ -f "$sysdev/idVendor" && -f "$sysdev/idProduct" ]] || continue
        local v p
        v=$(<"$sysdev/idVendor"); p=$(<"$sysdev/idProduct")
        [[ "${v}:${p}" == "$VID_PID" ]] || continue
        [[ -f "$sysdev/speed" ]] && { cat "$sysdev/speed"; return; }
    done
    echo "unknown"
}

require_mechanical() {
    local missing=0
    [[ "$APERTURE"   == unset ]] && { warn "aperture not declared  — export ARGUS_APERTURE=2.8"; missing=1; }
    [[ "$FOCUS_MARK" == unset ]] && { warn "focus mark not declared — export ARGUS_FOCUS='2cm-from-near'"; missing=1; }
    [[ $missing -eq 1 ]] && note "Recording without these makes the row unreproducible."
    return 0
}

# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------
cmd_status() {
    hdr "LINK"
    local sp; sp=$(link_speed)
    case "$sp" in
        5000|10000) ok "USB SuperSpeed: ${sp}M" ;;
        480)        err "USB 2 fallback (480M) — replug the camera; 4K will not enumerate" ;;
        *)          warn "link speed: $sp" ;;
    esac
    ok "device: $DEV"

    hdr "FORMAT"
    local cur_fps
    cur_fps=$(v4l2-ctl -d "$DEV" --get-parm 2>/dev/null | sed -n 's/.*Frames per second: \([0-9.]*\).*/\1/p')
    v4l2-ctl -d "$DEV" --get-fmt-video 2>/dev/null | sed -n 's/^\t/           /p' | head -5
    note "frame rate: ${cur_fps:-unknown} fps"

    hdr "EXPOSURE CLAMP HEADROOM"
    note "Exposure cannot exceed one frame period, whatever value you write."
    printf '           %-8s %-14s %-12s %s\n' "fps" "period" "max value" "= shutter"
    local f
    for f in 15 30 60 90; do
        local mx; mx=$(max_exposure_for_fps "$f")
        printf '           %-8s %-14s %-12s %s\n' \
            "$f" "$(awk -v x="$f" 'BEGIN{printf "%.2f ms", 1000/x}')" "$mx" "$(exposure_frac "$mx")"
    done
    local mx_now; mx_now=$(max_exposure_for_fps "${cur_fps:-15}")
    note ""
    note "At ${cur_fps:-15} fps your ceiling is exposure_time_absolute=$mx_now."

    hdr "SENSOR CONTROLS"
    local ae exp gain wb plf
    ae=$(get_ctrl auto_exposure); exp=$(get_ctrl exposure_time_absolute)
    gain=$(get_ctrl gain); wb=$(get_ctrl white_balance_automatic)
    plf=$(get_ctrl power_line_frequency)

    if [[ "$ae" == "1" ]]; then
        ok "auto_exposure = 1 (Manual) — measurements are valid"
    else
        err "auto_exposure = ${ae:-?} (Auto) — AE will move exposure between shots"
        note "Any A/B comparison taken like this is uninterpretable. See guide 5.1."
    fi
    ok "exposure_time_absolute = ${exp:-?}  ($(exposure_ms "${exp:-0}") ms, $(exposure_frac "${exp:-0}") s)"
    [[ -n "$exp" && "$exp" -gt "$mx_now" ]] && \
        err "requested $exp exceeds the ${cur_fps:-15} fps ceiling of $mx_now — silently clamped"
    ok "gain = ${gain:-?}  ($(gain_x "${gain:-100}")x)"
    [[ "$wb" == "1" ]] && warn "white_balance_automatic = 1 — colour will drift between shots"
    [[ "$plf" == "0" ]] && warn "power_line_frequency = 0 (Disabled) — set 2 for 60 Hz indoors"

    hdr "MECHANICAL STATE (not readable from the device)"
    note "lens          $LENS"
    note "focal length  ${FOCAL} mm"
    note "aperture      f/${APERTURE}"
    note "focus mark    $FOCUS_MARK"
    note ""
    note "V4L2 cannot see the barrel. If these are wrong, every number below"
    note "is attached to the wrong configuration. See guide 3.6."
}

# --------------------------------------------------------------------------
# set
# --------------------------------------------------------------------------
cmd_set() {
    local want_exp="$1" want_gain="$2"
    hdr "APPLYING"

    v4l2-ctl -d "$DEV" --set-parm="$FPS" >/dev/null 2>&1
    ok "frame rate -> $FPS fps"

    local mx; mx=$(max_exposure_for_fps "$FPS")
    if (( want_exp > mx )); then
        err "exposure $want_exp exceeds the $FPS fps ceiling of $mx"
        note "Lower the frame rate or the exposure. Clamping silently otherwise."
        return 1
    fi

    # ORDER MATTERS: exposure_time_absolute is flagged inactive under AE.
    v4l2-ctl -d "$DEV" --set-ctrl=auto_exposure=1 >/dev/null 2>&1
    ok "auto_exposure -> 1 (Manual)   [must precede exposure write]"

    v4l2-ctl -d "$DEV" --set-ctrl=exposure_time_absolute="$want_exp" >/dev/null 2>&1
    v4l2-ctl -d "$DEV" --set-ctrl=gain="$want_gain"                  >/dev/null 2>&1
    v4l2-ctl -d "$DEV" --set-ctrl=white_balance_automatic=0          >/dev/null 2>&1
    v4l2-ctl -d "$DEV" --set-ctrl=power_line_frequency=2             >/dev/null 2>&1

    hdr "READBACK"
    local got_exp got_gain
    got_exp=$(get_ctrl exposure_time_absolute); got_gain=$(get_ctrl gain)

    if [[ "$got_exp" == "$want_exp" ]]; then
        ok "exposure_time_absolute = $got_exp ($(exposure_ms "$got_exp") ms, $(exposure_frac "$got_exp") s)"
    else
        err "exposure: wrote $want_exp, device reports $got_exp — clamped or rejected"
    fi
    if [[ "$got_gain" == "$want_gain" ]]; then
        ok "gain = $got_gain ($(gain_x "$got_gain")x)"
    else
        err "gain: wrote $want_gain, device reports $got_gain"
    fi
}

# --------------------------------------------------------------------------
# capture
# --------------------------------------------------------------------------
capture_raw() {
    local dest="$1"
    v4l2-ctl -d "$DEV" \
        --set-fmt-video=width="$WIDTH",height="$HEIGHT",pixelformat=YUYV \
        --stream-mmap --stream-count=1 --stream-skip="$SKIP" \
        --stream-to="$dest" >/dev/null 2>&1
    local want=$(( WIDTH * HEIGHT * 2 ))
    local got; got=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if [[ "$got" != "$want" ]]; then
        err "capture wrote $got B, expected $want B"
        return 1
    fi
    return 0
}

dope_header() {
    [[ -f "$DOPE" ]] && return
    echo "utc,session,lens,focal_mm,f_stop,focus_mark,range_m,conditions,res,fps,exp_val,exp_ms,gain_val,gain_x,luma_mean,luma_max,clip_pct,crush_pct,lap_var,lap_norm,file,notes" > "$DOPE"
}

dope_append() {
    local file="$1" extra_notes="${2:-}"
    local exp gain metrics
    exp=$(get_ctrl exposure_time_absolute); gain=$(get_ctrl gain)
    metrics=$(python3 "$STATS" "$file" -W "$WIDTH" -H "$HEIGHT" --crop "$CROP" --csv 2>/dev/null)
    [[ -z "$metrics" ]] && { err "measurement failed for $file"; return 1; }

    dope_header
    # metrics is already the comma-joined block: mean,max,clip,crush,lap,lapnorm
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%sx%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SESSION:-adhoc}" \
        "$LENS" "$FOCAL" "$APERTURE" "$FOCUS_MARK" "$RANGE_M" "$CONDITIONS" \
        "$WIDTH" "$HEIGHT" "$FPS" \
        "$exp" "$(exposure_ms "$exp")" "$gain" "$(gain_x "$gain")" \
        "$metrics" "$(basename "$file")" "${NOTES}${extra_notes}" >> "$DOPE"
}

cmd_shot() {
    require_mechanical
    mkdir -p "$OUTDIR"
    local ae; ae=$(get_ctrl auto_exposure)
    [[ "$ae" != "1" ]] && warn "auto_exposure is not Manual — this row will not be reproducible"

    local stamp dest
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    dest="$OUTDIR/shot_${stamp}.raw"

    hdr "CAPTURE"
    capture_raw "$dest" || return 1
    ok "wrote $dest"

    hdr "MEASUREMENT"
    python3 "$STATS" "$dest" -W "$WIDTH" -H "$HEIGHT" --crop "$CROP"

    dope_append "$dest" && ok "DOPE row appended to $DOPE"
}

# --------------------------------------------------------------------------
# sweeps
# --------------------------------------------------------------------------
sweep_report_header() {
    printf '\n           %-8s %-10s %-9s %-8s %-8s %-10s %s\n' \
        "$1" "mean" "max" "clip%" "crush%" "lap" "lap_norm"
    printf '           %s\n' "--------------------------------------------------------------------"
}

sweep_row() {
    local label="$1" file="$2"
    local m; m=$(python3 "$STATS" "$file" -W "$WIDTH" -H "$HEIGHT" --crop "$CROP" --csv 2>/dev/null)
    IFS=, read -r mean mx clip crush lap lapn <<<"$m"
    printf '           %-8s %-10s %-9s %-8s %-8s %-10s %s\n' \
        "$label" "$mean" "$mx" "$clip" "$crush" "$lap" "$lapn"
}

cmd_sweep_exposure() {
    require_mechanical
    mkdir -p "$OUTDIR"
    local gain="${1:-100}"
    local mx; mx=$(max_exposure_for_fps "$FPS")
    hdr "EXPOSURE SWEEP  (gain fixed at $gain = $(gain_x "$gain")x, $FPS fps, ceiling $mx)"
    note "Doubling the value should double the light. Where it stops doubling,"
    note "you have found the clamp, the noise floor, or a nonlinear response."
    sweep_report_header "exp"

    local e
    for e in 20 40 80 160 320 640; do
        (( e > mx )) && { printf '           %-8s CLAMPED at %s fps (ceiling %s)\n' "$e" "$FPS" "$mx"; continue; }
        cmd_set "$e" "$gain" >/dev/null 2>&1
        local dest="$OUTDIR/sweep_exp_${e}.raw"
        capture_raw "$dest" || continue
        sweep_row "$e" "$dest"
        NOTES="sweep-exposure" dope_append "$dest" >/dev/null 2>&1
    done
    note ""
    note "Target: mean 90-140, clip < 1%, crush < 5%, max near 250 but not at it."
}

cmd_sweep_gain() {
    require_mechanical
    mkdir -p "$OUTDIR"
    local exp="${1:-200}"
    hdr "GAIN SWEEP  (exposure fixed at $exp = $(exposure_ms "$exp") ms)"
    note "This sweep IS the low-light budget. On the roof, shutter is pinned"
    note "short by vessel motion, so gain is the only variable left. Where the"
    note "image degrades here is where dusk operation ends. See guide 8.4."
    sweep_report_header "gain"

    local g
    for g in 100 200 400 800 1600 3200 4000; do
        cmd_set "$exp" "$g" >/dev/null 2>&1
        local dest="$OUTDIR/sweep_gain_${g}.raw"
        capture_raw "$dest" || continue
        sweep_row "$g" "$dest"
        NOTES="sweep-gain" dope_append "$dest" >/dev/null 2>&1
    done
    note ""
    note "CAUTION: sensor noise inflates the Laplacian. A rising lap number at"
    note "high gain is noise, not sharpness. Look at the frame, not just the row."
}

cmd_sweep_focus() {
    require_mechanical
    mkdir -p "$OUTDIR"
    local ae; ae=$(get_ctrl auto_exposure)
    if [[ "$ae" != "1" ]]; then
        err "auto_exposure is not Manual. A focus sweep under AE is invalid:"
        note "racking focus changes scene contrast, AE reacts, exposure moves,"
        note "and you measure focus and AE response tangled together."
        return 1
    fi
    hdr "FOCUS SWEEP  (exposure locked, framing must not move)"
    note "Do not touch the tripod. After each ring adjustment, wait 5 s for the"
    note "rig to settle before pressing Enter, or you log settling vibration."
    sweep_report_header "position"

    local i=1
    while true; do
        read -r -p "           focus mark (blank to finish): " mark
        [[ -z "$mark" ]] && break
        sleep 5
        local dest="$OUTDIR/sweep_focus_$(printf '%02d' "$i")_${mark//\//-}.raw"
        capture_raw "$dest" || continue
        sweep_row "$mark" "$dest"
        FOCUS_MARK="$mark" NOTES="sweep-focus" dope_append "$dest" >/dev/null 2>&1
        i=$(( i + 1 ))
    done
    note ""
    note "Best focus is the peak of lap_norm. If the curve is flat, the softness"
    note "is optical or motion, not focus error."
}

# --------------------------------------------------------------------------
usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Environment:
  ARGUS_DEV, ARGUS_W, ARGUS_H, ARGUS_FPS, ARGUS_SKIP, ARGUS_CROP
  ARGUS_OUTDIR, ARGUS_DOPE, ARGUS_STATS
  ARGUS_LENS, ARGUS_FOCAL, ARGUS_APERTURE, ARGUS_FOCUS, ARGUS_RANGE
  ARGUS_COND, ARGUS_NOTES, SESSION

Examples:
  export ARGUS_APERTURE=2.8 ARGUS_FOCUS='2cm-from-near' SESSION=bench-01
  ./argus_opticheck.sh status
  ./argus_opticheck.sh set 400 800
  ./argus_opticheck.sh shot
  ./argus_opticheck.sh sweep-exposure 100
  ./argus_opticheck.sh sweep-gain 200
  ./argus_opticheck.sh sweep-focus
EOF
}

main() {
    command -v v4l2-ctl >/dev/null || { err "v4l2-ctl not found (apt install v4l-utils)"; exit 1; }
    [[ -f "$STATS" ]] || { err "measurement engine not found at $STATS"; exit 1; }

    local cmd="${1:-status}"; shift || true
    case "$cmd" in
        status)          resolve_device; cmd_status ;;
        set)             resolve_device; cmd_set "${1:?exposure value}" "${2:-100}" ;;
        shot)            resolve_device; cmd_shot ;;
        sweep-exposure)  resolve_device; cmd_sweep_exposure "${1:-100}" ;;
        sweep-gain)      resolve_device; cmd_sweep_gain "${1:-200}" ;;
        sweep-focus)     resolve_device; cmd_sweep_focus ;;
        -h|--help|help)  usage ;;
        *)               err "unknown command: $cmd"; usage; exit 1 ;;
    esac
    echo
}

main "$@"
