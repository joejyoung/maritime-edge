#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# argus_raw2png.sh — render headerless YUYV 4:2:2 captures as viewable PNGs.
#
# Companion to the capture/measure half of the Argus diagnostic set:
#     argus_opticheck.sh      — optics/exposure control, writes the .raw files
#     argus_frame_stats.py    — numeric measurement of those .raw files
#     argus_raw2png.sh        — visual inspection of those .raw files (this)
#
# PURPOSE
#   argus_opticheck.sh writes headerless YUYV frames (shot_*.raw,
#   sweep_*.raw) and argus_frame_stats.py reduces them to numbers. Nothing
#   in the set lets you LOOK at one. That gap matters most exactly where the
#   numbers are least trustworthy: Laplacian variance rewards sensor noise,
#   so a gain sweep can show a rising "sharpness" figure while the frame is
#   visibly falling apart. Convert and eyeball before believing a sweep.
#
#   Defaults mirror argus_opticheck.sh (ARGUS_W/ARGUS_H/ARGUS_OUTDIR/ARGUS_CROP)
#   so a bare invocation converts the current capture directory in place.
#
# USAGE
#   ./argus_raw2png.sh                        # captures/*.raw -> captures/*.png
#   ./argus_raw2png.sh captures/sweep_gain_*.raw
#   ./argus_raw2png.sh -W 3840 -H 2160 shot.raw
#   ./argus_raw2png.sh --all --crop-box captures/sweep_focus_*.raw
#   ./argus_raw2png.sh --scale 1280x720 --out /tmp/preview captures/*.raw
#
# EXIT CODES
#   0  every requested file converted
#   1  one or more files failed (geometry, truncation, encoder error)
#   2  prerequisite missing (ffmpeg) or bad arguments
#
# Read-only with respect to the .raw source files. Never overwrites an
# existing PNG unless --force is given.
# ---------------------------------------------------------------------------

set -uo pipefail

# --------------------------------------------------------------------------
# Configuration — same environment variables as argus_opticheck.sh
# --------------------------------------------------------------------------
WIDTH="${ARGUS_W:-1920}"
HEIGHT="${ARGUS_H:-1080}"
OUTDIR="${ARGUS_OUTDIR:-./captures}"
CROP="${ARGUS_CROP:-600x400}"

# The camera reports Quantization: Limited Range (Y 16-235). Converting as
# if it were full range crushes blacks and flattens the image. Override with
# --range full if a firmware update changes this. See NOTE at the bottom.
RANGE="${ARGUS_RANGE_MODE:-limited}"

FRAME=0
ALL_FRAMES=0
CROP_BOX=0
FORCE=0
DRY_RUN=0
QUIET=0
SCALE=""
DESTDIR=""          # empty = write alongside each source file

C_OK=$'\033[0;32m'; C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'
C_HDR=$'\033[1;36m'; C_OFF=$'\033[0m'
[[ -t 1 ]] || { C_OK=""; C_WARN=""; C_ERR=""; C_HDR=""; C_OFF=""; }

say()  { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*"; }
ok()   { say "  ${C_OK}[ OK ]${C_OFF}   $*"; }
warn() { say "  ${C_WARN}[WARN]${C_OFF}   $*"; }
err()  { printf '  %s[FAIL]%s   %s\n' "$C_ERR" "$C_OFF" "$*" >&2; }
hdr()  { say ""; say "${C_HDR}=== $* ${C_OFF}"; }
note() { say "           $*"; }

usage() { sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'; }

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
FILES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -W|--width)   WIDTH="$2";   shift 2 ;;
        -H|--height)  HEIGHT="$2";  shift 2 ;;
        -f|--frame)   FRAME="$2";   shift 2 ;;
        --all)        ALL_FRAMES=1; shift ;;
        --out)        DESTDIR="$2"; shift 2 ;;
        --scale)      SCALE="$2";   shift 2 ;;
        --range)      RANGE="$2";   shift 2 ;;
        --crop-box)   CROP_BOX=1;   shift ;;
        --force)      FORCE=1;      shift ;;
        --dry-run)    DRY_RUN=1;    shift ;;
        --quiet)      QUIET=1;      shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           err "unknown option: $1"; usage >&2; exit 2 ;;
        *)            FILES+=("$1"); shift ;;
    esac
done

case "$RANGE" in
    limited|full) ;;
    *) err "--range wants 'limited' or 'full', got '$RANGE'"; exit 2 ;;
esac
if [[ -n "$SCALE" && ! "$SCALE" =~ ^[0-9]+x[0-9]+$ ]]; then
    err "--scale wants WxH, got '$SCALE'"; exit 2
fi

command -v ffmpeg >/dev/null 2>&1 || {
    err "ffmpeg not found"
    note "sudo apt install ffmpeg    # the jetson/ffmpeg apt source is already configured"
    exit 2
}

# Default target set: everything in the capture directory.
if [[ ${#FILES[@]} -eq 0 ]]; then
    shopt -s nullglob
    FILES=("$OUTDIR"/*.raw "$OUTDIR"/*.yuv)
    shopt -u nullglob
    [[ ${#FILES[@]} -eq 0 ]] && {
        err "no .raw/.yuv files in $OUTDIR"
        note "pass paths explicitly, or set ARGUS_OUTDIR"
        exit 2
    }
fi

FRAME_BYTES=$(( WIDTH * HEIGHT * 2 ))   # YUYV 4:2:2 is exactly 2 bytes/pixel

# --------------------------------------------------------------------------
# Geometry check
#
# A headerless file carries no geometry, so the only available cross-check is
# arithmetic: the size must be a whole number of WIDTH*HEIGHT*2 frames. If it
# is not, the geometry is wrong or the capture was truncated — and ffmpeg
# would happily render a diagonally-sheared image without complaint.
# --------------------------------------------------------------------------
guess_geometry() {
    local size="$1" w h
    for geom in 3840x2160 1920x1080 1280x720 640x480; do
        w="${geom%x*}"; h="${geom#*x}"
        if (( size % (w * h * 2) == 0 )); then
            printf '%s (%d frame(s))' "$geom" $(( size / (w * h * 2) ))
            return 0
        fi
    done
    return 1
}

# --------------------------------------------------------------------------
# Conversion
# --------------------------------------------------------------------------
build_filter() {
    local filters=()

    # Range expansion happens in the YUV->RGB conversion, so it must be the
    # first scale in the chain.
    if [[ "$RANGE" == "limited" ]]; then
        filters+=("scale=in_range=limited:out_range=full")
    else
        filters+=("scale=in_range=full:out_range=full")
    fi

    # Focus ROI overlay: argus_frame_stats.py computes lap_var over this exact
    # centred box, so this shows you what the number was actually measured on.
    if [[ "$CROP_BOX" -eq 1 ]]; then
        local cw="${CROP%x*}" ch="${CROP#*x}"
        (( cw > WIDTH ))  && cw="$WIDTH"
        (( ch > HEIGHT )) && ch="$HEIGHT"
        filters+=("drawbox=x=(iw-${cw})/2:y=(ih-${ch})/2:w=${cw}:h=${ch}:color=red@0.8:t=3")
    fi

    # Preview downscale goes last so the box is drawn at capture scale.
    [[ -n "$SCALE" ]] && filters+=("scale=${SCALE/x/:}:flags=lanczos")

    local IFS=,
    printf '%s' "${filters[*]}"
}

convert_one() {
    local src="$1"
    local base dir stem size n_frames dest vf

    [[ -r "$src" ]] || { err "$src: not readable"; return 1; }

    base="$(basename "$src")"
    stem="${base%.*}"
    dir="${DESTDIR:-$(dirname "$src")}"
    size="$(stat -c%s "$src" 2>/dev/null || echo 0)"

    if (( size < FRAME_BYTES )); then
        err "$base: ${size} B is smaller than one ${WIDTH}x${HEIGHT} frame (${FRAME_BYTES} B)"
        local g; g="$(guess_geometry "$size")" && note "size is consistent with $g"
        return 1
    fi

    n_frames=$(( size / FRAME_BYTES ))
    if (( size % FRAME_BYTES != 0 )); then
        warn "$base: ${size} B is not a whole number of ${WIDTH}x${HEIGHT} frames"
        local g
        if g="$(guess_geometry "$size")"; then
            note "size IS consistent with $g — wrong -W/-H?"
        else
            note "capture truncated; rendering the $n_frames whole frame(s) present"
        fi
    fi

    if (( ALL_FRAMES == 0 && FRAME >= n_frames )); then
        err "$base: requested frame $FRAME, file holds $n_frames"
        return 1
    fi

    vf="$(build_filter)"
    mkdir -p "$dir" 2>/dev/null

    local -a out_files
    if (( ALL_FRAMES == 1 && n_frames > 1 )); then
        dest="$dir/${stem}.f%03d.png"
        out_files=("$dir/${stem}.f001.png")   # ffmpeg's %03d counter starts at 1
    else
        dest="$dir/${stem}.png"
        out_files=("$dest")
    fi

    if [[ -e "${out_files[0]}" && "$FORCE" -eq 0 ]]; then
        warn "$base -> $(basename "${out_files[0]}") exists (use --force)"
        return 0
    fi

    if (( DRY_RUN == 1 )); then
        ok "$base -> $(basename "$dest")   [${WIDTH}x${HEIGHT}, ${n_frames} frame(s), dry run]"
        return 0
    fi

    local -a cmd=(
        ffmpeg -hide_banner -loglevel error -y
        -f rawvideo -pixel_format yuyv422
        -video_size "${WIDTH}x${HEIGHT}" -framerate 1
        -i "$src"
    )
    if (( ALL_FRAMES == 1 && n_frames > 1 )); then
        cmd+=(-vf "$vf")
    else
        # select= is frame-exact and avoids decoding the whole file first.
        cmd+=(-vf "select=eq(n\\,${FRAME}),${vf}" -frames:v 1)
    fi
    cmd+=(-pix_fmt rgb24 "$dest")

    local errout
    if ! errout="$("${cmd[@]}" 2>&1)"; then
        err "$base: ffmpeg failed"
        [[ -n "$errout" ]] && note "$errout"
        return 1
    fi

    local n_written
    n_written=$(find "$dir" -maxdepth 1 \( -name "${stem}.png" -o -name "${stem}.f[0-9][0-9][0-9].png" \) 2>/dev/null | wc -l)
    ok "$base -> ${stem}$( ((ALL_FRAMES==1 && n_frames>1)) && echo ".f*" ).png   (${WIDTH}x${HEIGHT}${SCALE:+ -> $SCALE}, ${n_written} PNG)"
    return 0
}

# --------------------------------------------------------------------------
hdr "RAW -> PNG  (${WIDTH}x${HEIGHT} YUYV 4:2:2, ${RANGE} range)"
note "${#FILES[@]} file(s), ${FRAME_BYTES} B per frame"
[[ "$CROP_BOX" -eq 1 ]] && note "overlaying the ${CROP} focus ROI used by argus_frame_stats.py"
[[ -n "$DESTDIR" ]] && note "output -> $DESTDIR"
say ""

FAILED=0
CONVERTED=0
for f in "${FILES[@]}"; do
    if convert_one "$f"; then CONVERTED=$(( CONVERTED + 1 )); else FAILED=$(( FAILED + 1 )); fi
done

hdr "SUMMARY"
if (( FAILED == 0 )); then
    ok "$CONVERTED file(s) converted, 0 failed"
else
    warn "$CONVERTED file(s) converted, $FAILED failed"
fi
note ""
note "NOTE: these PNGs are for looking at, not for measuring. Range expansion"
note "and RGB conversion both move pixel values, so any exposure number must"
note "come from argus_frame_stats.py reading the .raw, never from the PNG."
say ""

exit $(( FAILED > 0 ? 1 : 0 ))
