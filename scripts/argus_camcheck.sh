#!/usr/bin/env bash
# argus_camcheck.sh — preflight check for the Arducam B0498 on Argus (Jetson Orin Nano).
#
# Verifies the camera is enumerated at SuperSpeed (5000M) before any capture run.
# USB2 fallback (480M) is silent and caps the sensor well below 4K30 — this
# catches it up front instead of after an hour of rooftop footage.
#
# Usage:  ./argus_camcheck.sh          # check, attempt recovery, report
#         ./argus_camcheck.sh --quiet  # exit code only (0 = ready, 1 = not)
#
# Exit 0 = SuperSpeed link + capture node found.  Exit 1 = not ready.

set -uo pipefail

VID=04b4
PID=0498
MAX_TRIES=3

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
say() { [ "$QUIET" -eq 1 ] || echo "$@"; }

# Locate the camera in sysfs by vendor:product. The device path changes
# depending on which speed it trains at (1-2.2 at USB2, 2-1.2 at SS),
# so never hardcode it.
find_dev() {
  local d
  for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] || continue
    [ "$(cat "$d/idVendor")" = "$VID" ] || continue
    [ "$(cat "$d/idProduct" 2>/dev/null)" = "$PID" ] || continue
    basename "$d"
    return 0
  done
  return 1
}

# Find the capture node belonging to this camera. Modern UVC devices expose
# a metadata node alongside the video node; only the capture one is useful.
find_node() {
  local v props
  for v in /dev/video*; do
    [ -e "$v" ] || continue
    props=$(udevadm info -q property -n "$v" 2>/dev/null) || continue
    grep -q "ID_MODEL_ID=$PID" <<<"$props" || continue
    grep -q "ID_V4L_CAPABILITIES=.*:capture:" <<<"$props" || continue
    echo "$v"
    return 0
  done
  return 1
}

for try in $(seq 1 "$MAX_TRIES"); do
  dev=$(find_dev) || {
    say "[$try/$MAX_TRIES] Camera not present on USB."
    sleep 2
    continue
  }

  speed=$(cat "/sys/bus/usb/devices/$dev/speed" 2>/dev/null || echo "?")

  if [ "$speed" = "5000" ] || [ "$speed" = "10000" ]; then
    say "OK   link:  $dev @ ${speed}M (SuperSpeed)"

    # Keep the kernel from suspending the camera mid-session.
    ctrl="/sys/bus/usb/devices/$dev/power/control"
    if [ -w "$ctrl" ] || sudo -n true 2>/dev/null; then
      echo on | sudo tee "$ctrl" >/dev/null 2>&1 || true
    fi

    if node=$(find_node); then
      say "OK   node:  $node"
      say "READY"
      [ "$QUIET" -eq 1 ] && echo "$node"
      exit 0
    fi
    say "FAIL node:  SuperSpeed link but no capture node. Is uvcvideo loaded?"
    exit 1
  fi

  say "WARN link:  $dev @ ${speed}M — wanted 5000M. Attempting rebind..."
  echo "$dev" | sudo tee /sys/bus/usb/drivers/usb/unbind >/dev/null 2>&1
  sleep 2
  echo "$dev" | sudo tee /sys/bus/usb/drivers/usb/bind   >/dev/null 2>&1
  sleep 3
done

cat >&2 <<'EOF'
FAIL: no SuperSpeed link after repeated attempts.

Rebinding re-enumerates on the bus the device is already attached to, so it
often cannot recover a link that failed to train as SuperSpeed in the first
place. If this keeps happening:

  1. Physically unplug and replug (this is what actually works today).
  2. Swap to the cable that shipped with the B0498 — marginal SS pairs are
     the most common cause of intermittent link training.
  3. Try a different Type-A USB 3 port on the carrier board.
  4. For a scriptable equivalent of a replug, uhubctl can cut port power:
       sudo uhubctl -l <hub> -p <port> -a cycle
EOF
exit 1
