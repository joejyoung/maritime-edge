#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# argus_jetpack_check.sh — JetPack SDK installation state and diagnostics
#
# Third in the Argus diagnostic set:
#     capture_env.sh          — per-session provenance snapshot
#     argus_camcheck.sh       — camera / USB link preflight
#     argus_jetpack_check.sh  — JetPack SDK state (this script)
#
# PURPOSE
#   Distinguishes the two independent install stages that are easily
#   conflated on Jetson:
#
#       Stage A  BSP flashed  -> kernel, bootloader, drivers, /etc/nv_tegra_release
#       Stage B  SDK installed -> CUDA, cuDNN, TensorRT, VPI, multimedia API
#
#   A board can pass Stage A completely and have none of Stage B. The symptom
#   is a working camera and a missing nvcc. This script reports each stage
#   separately and never infers one from the other.
#
# USAGE
#   ./argus_jetpack_check.sh              # human-readable report
#   ./argus_jetpack_check.sh --save       # also write manifests/jetpack-*.txt
#   ./argus_jetpack_check.sh --quiet      # exit code only, for scripting
#
# EXIT CODES
#   0  SDK present and functional
#   1  SDK absent or incomplete (remediation printed)
#   2  BSP problem — SDK questions are premature
#
# Read-only. Installs nothing, changes no state. Safe to run at any time.
# ---------------------------------------------------------------------------

set -uo pipefail

SAVE=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --save)  SAVE=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
  esac
done

# ----- output helpers -------------------------------------------------------
if [ -t 1 ] && [ "$QUIET" -eq 0 ]; then
  B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; Z=$'\e[0m'
else
  B=""; R=""; G=""; Y=""; C=""; Z=""
fi

FAIL=0; WARN=0
say()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
hdr()  { say ""; say "${B}${C}=== $* ${Z}"; }
ok()   { say "  ${G}[ OK ]${Z}   $*"; }
bad()  { say "  ${R}[FAIL]${Z}   $*"; FAIL=1; }
warn() { say "  ${Y}[WARN]${Z}   $*"; WARN=1; }
info() { say "           $*"; }
hint() { say "           ${C}-> $*${Z}"; }

have() { command -v "$1" >/dev/null 2>&1; }

# CUDA is installed outside the default PATH; look for it directly.
CUDA_DIR=""
for d in /usr/local/cuda /usr/local/cuda-*; do
  [ -d "$d" ] && CUDA_DIR="$d" && break
done
NVCC=""
[ -n "$CUDA_DIR" ] && [ -x "$CUDA_DIR/bin/nvcc" ] && NVCC="$CUDA_DIR/bin/nvcc"
have nvcc && NVCC="$(command -v nvcc)"

TRTEXEC=""
for p in /usr/src/tensorrt/bin/trtexec /usr/bin/trtexec; do
  [ -x "$p" ] && TRTEXEC="$p" && break
done

# ===========================================================================
say "${B}Argus — JetPack SDK diagnostic${Z}"
say "$(date -u +'%Y-%m-%d %H:%M:%SZ')  |  $(hostname)"

# ---------------------------------------------------------------------------
hdr "STAGE A — BSP (flash) identity"

if [ -r /etc/nv_tegra_release ]; then
  REL_LINE="$(head -1 /etc/nv_tegra_release)"
  L4T_MAJ="$(sed -n 's/^# R\([0-9]*\) (release).*/\1/p' <<<"$REL_LINE")"
  L4T_REV="$(sed -n 's/.*REVISION: \([0-9.]*\),.*/\1/p'  <<<"$REL_LINE")"
  L4T="${L4T_MAJ}.${L4T_REV}"
  ok "L4T R${L4T}"
  info "$REL_LINE"

  # L4T major -> expected userspace. Update this table as releases appear.
  case "$L4T_MAJ" in
    39) EXP_JP="7.2.x"; EXP_UB="24.04"; EXP_PY="3.12"; EXP_CUDA="13.x" ;;
    38) EXP_JP="7.0-7.1"; EXP_UB="24.04"; EXP_PY="3.12"; EXP_CUDA="13.x" ;;
    36) EXP_JP="6.x";   EXP_UB="22.04"; EXP_PY="3.10"; EXP_CUDA="12.x" ;;
    35) EXP_JP="5.x";   EXP_UB="20.04"; EXP_PY="3.8";  EXP_CUDA="11.4" ;;
    *)  EXP_JP="unknown"; EXP_UB="?"; EXP_PY="?"; EXP_CUDA="?" ;;
  esac
  info "expected: JetPack ${EXP_JP}, Ubuntu ${EXP_UB}, Python ${EXP_PY}, CUDA ${EXP_CUDA}"
  [ "$EXP_JP" = "unknown" ] && warn "L4T major R${L4T_MAJ} not in this script's table — verify against NVIDIA docs"
else
  bad "/etc/nv_tegra_release missing — board may not be flashed"
  exit 2
fi

[ -r /proc/device-tree/model ] && info "board: $(tr -d '\0' </proc/device-tree/model)"

UB="$( . /etc/os-release 2>/dev/null && echo "$VERSION_ID" )"
PY="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
if [ "$UB" = "$EXP_UB" ]; then ok "Ubuntu $UB (matches L4T R${L4T_MAJ})"
else warn "Ubuntu $UB — expected $EXP_UB for L4T R${L4T_MAJ}"; fi
if [ "$PY" = "$EXP_PY" ]; then ok "Python $PY (matches L4T R${L4T_MAJ})"
else warn "Python $PY — expected $EXP_PY for L4T R${L4T_MAJ}"; fi

# ---------------------------------------------------------------------------
hdr "STAGE B — SDK component inventory"

# The nvidia-jetpack meta-package is the single authoritative marker.
if dpkg-query -W -f='${Status}' nvidia-jetpack 2>/dev/null | grep -q "install ok installed"; then
  ok "nvidia-jetpack installed: $(dpkg-query -W -f='${Version}' nvidia-jetpack)"
  SDK_META=1
else
  bad "nvidia-jetpack NOT installed — SDK stage never completed"
  SDK_META=0
fi

# Per-component presence, independent of the meta-package.
comp() {  # comp <label> <dpkg-pattern>
  local n
  n="$(dpkg-query -W -f='${binary:Package} ${Version}\n' "$2" 2>/dev/null | grep -c . || true)"
  if [ "${n:-0}" -gt 0 ]; then
    ok "$1: $n package(s)"
    [ "$QUIET" -eq 1 ] || dpkg-query -W -f='             ${binary:Package} ${Version}\n' "$2" 2>/dev/null | head -4
  else
    bad "$1: no packages installed"
  fi
}
comp "CUDA toolkit" 'cuda-toolkit-*'
comp "cuDNN"        'libcudnn*'
comp "TensorRT"     'libnvinfer*'
comp "VPI"          'libnvvpi*'
comp "Multimedia"   'nvidia-l4t-jetson-multimedia-api'

# ---------------------------------------------------------------------------
hdr "APT source configuration"

# Without a correctly configured repo, 'apt install nvidia-jetpack' cannot work.
SRC="$(grep -rhs 'repo.download.nvidia.com' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null)"
if [ -n "$SRC" ]; then
  ok "NVIDIA L4T apt source present"
  [ "$QUIET" -eq 1 ] || sed 's/^/             /' <<<"$SRC" | head -6
  # The repo release string should track the flashed BSP.
  if ! grep -q "r${L4T_MAJ}" <<<"$SRC"; then
    warn "apt source does not reference r${L4T_MAJ} — repo may not match flashed BSP"
    hint "a mismatched repo is the usual cause of 'nvidia-jetpack has no installation candidate'"
  fi
else
  bad "no NVIDIA L4T apt source configured"
  hint "without it, the SDK cannot be installed via apt at all"
fi

if have apt-cache; then
  CAND="$(apt-cache policy nvidia-jetpack 2>/dev/null | sed -n 's/ *Candidate: //p')"
  if [ -n "$CAND" ] && [ "$CAND" != "(none)" ]; then
    ok "nvidia-jetpack candidate available: $CAND"
    info "NOTE: 'available' is a repo fact, not an installed fact."
  else
    bad "no installation candidate for nvidia-jetpack"
    hint "run 'sudo apt update' first; if still none, the repo does not serve this BSP"
  fi
fi

# ---------------------------------------------------------------------------
hdr "Functional verification"

# CUDA — check the real install path, not just PATH.
if [ -n "$NVCC" ]; then
  ok "nvcc: $("$NVCC" --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/CUDA \1/p')"
  info "path: $NVCC"
  if ! have nvcc; then
    warn "nvcc present but not on PATH"
    hint "echo 'export PATH=${CUDA_DIR}/bin:\$PATH' >> ~/.bashrc"
    hint "echo 'export LD_LIBRARY_PATH=${CUDA_DIR}/lib64:\$LD_LIBRARY_PATH' >> ~/.bashrc"
  fi
else
  bad "nvcc not found (checked PATH and /usr/local/cuda*)"
fi

# TensorRT — trtexec is the component that actually matters for deployment.
if [ -n "$TRTEXEC" ]; then
  ok "trtexec: $TRTEXEC"
  info "$("$TRTEXEC" --version 2>&1 | head -2 | tr '\n' ' ')"
else
  bad "trtexec not found"
  hint "trtexec builds engines on-device; it is required even without PyTorch"
fi

# Shared libraries — catches partial installs the package DB may misreport.
LDCONFIG_CACHE="$(ldconfig -p 2>/dev/null)"
for lib in libnvinfer.so libcudnn.so libcudart.so; do
  if grep -q "$lib" <<<"$LDCONFIG_CACHE"; then ok "linker resolves $lib"
  else bad "linker cannot resolve $lib"; fi
done

# Python bindings are optional for the ONNX -> trtexec deployment path.
py_mod() {
  if python3 -c "import $1" 2>/dev/null; then
    ok "python: $1 $(python3 -c "import $1;print(getattr($1,'__version__',''))" 2>/dev/null)"
  else
    warn "python: $1 not importable"
  fi
}
py_mod tensorrt
py_mod cuda_python 2>/dev/null || true
if python3 -c "import torch" 2>/dev/null; then
  ok "python: torch $(python3 -c 'import torch;print(torch.__version__)')"
  if python3 -c "import torch,sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
    ok "torch CUDA available"
  else
    bad "torch installed but CUDA NOT available — almost certainly a CPU-only wheel"
    hint "never 'pip install torch' on Jetson; use NVIDIA's aarch64 wheel for this L4T"
  fi
else
  info "torch not installed (not required for ONNX -> trtexec deployment)"
fi

# ---------------------------------------------------------------------------
hdr "Build preflight (TensorRT engine builds)"

# Engine builds are memory-hungry; on 8 GB unified memory they OOM without swap.
MEMG="$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)"
SWAPG="$(awk '/SwapTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)"
FREEG="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"

info "RAM ${MEMG} GB (unified CPU/GPU)  |  swap ${SWAPG} GB  |  root free ${FREEG} GB"

if awk "BEGIN{exit !($SWAPG < 4)}"; then
  warn "swap ${SWAPG} GB is low — engine builds and pip compiles may OOM"
  hint "sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile"
  hint "sudo mkswap /swapfile && sudo swapon /swapfile"
else
  ok "swap ${SWAPG} GB"
fi

if [ "${FREEG:-0}" -lt 20 ] && [ "$SDK_META" -eq 0 ]; then
  warn "root free ${FREEG} GB — full SDK install needs roughly 15-20 GB"
else
  ok "root free ${FREEG} GB"
fi

if pgrep -x Xorg >/dev/null 2>&1 || systemctl is-active --quiet graphical.target 2>/dev/null; then
  warn "graphical target active — consumes unified memory needed by engine builds"
  hint "sudo systemctl set-default multi-user.target"
fi

# ---------------------------------------------------------------------------
hdr "Power state (must accompany every latency figure)"

if have nvpmodel; then
  info "$(nvpmodel -q 2>/dev/null | tr '\n' ' ')"
else
  warn "nvpmodel not found"
fi
have jetson_clocks && info "$(jetson_clocks --show 2>/dev/null | head -3 | tr '\n' ' ')"
have jtop || hint "install telemetry: sudo pip3 install jetson-stats  (then: jtop)"

for z in /sys/devices/virtual/thermal/thermal_zone*/; do
  [ -r "$z/type" ] && [ -r "$z/temp" ] || continue
  t="$(cat "$z/temp")"
  printf '           %-12s %s C\n' "$(cat "$z/type")" "$((t/1000))" 2>/dev/null
done | head -5 | while read -r l; do say "$l"; done

# ---------------------------------------------------------------------------
hdr "Hardware engine inventory"

# Orin Nano has NVDEC but no NVENC. Encoding plans must account for this.
if have gst-inspect-1.0; then
  ENC="$(gst-inspect-1.0 2>/dev/null | grep -ciE 'nvv4l2h26[45]enc' || true)"
  JPG="$(gst-inspect-1.0 2>/dev/null | grep -ci 'nvjpegenc' || true)"
  DEC="$(gst-inspect-1.0 2>/dev/null | grep -ci 'nvv4l2decoder' || true)"
  [ "${DEC:-0}" -gt 0 ] && ok "NVDEC present (nvv4l2decoder)" || warn "nvv4l2decoder not found"
  if [ "${ENC:-0}" -gt 0 ]; then
    ok "hardware H.264/H.265 encode available"
  else
    info "no NVENC — expected on Orin Nano; H.264/265 encode is CPU-bound"
  fi
  [ "${JPG:-0}" -gt 0 ] && ok "NVJPG present (nvjpegenc) — use for still capture" \
                        || warn "nvjpegenc not found"
else
  warn "gst-inspect-1.0 not found — cannot inventory hardware engines"
fi

# ---------------------------------------------------------------------------
hdr "Summary"

if [ "$SDK_META" -eq 0 ]; then
  say "  ${R}${B}SDK NOT INSTALLED${Z} — BSP is flashed but JetPack components are absent."
  say ""
  say "  Remediation:"
  say "    sudo apt update"
  say "    sudo apt install nvidia-jetpack        # ~15 GB"
  say "    echo 'export PATH=/usr/local/cuda/bin:\$PATH' >> ~/.bashrc"
  say "    source ~/.bashrc && ./argus_jetpack_check.sh"
  say ""
  say "  If apt reports no installation candidate, the repo does not serve this"
  say "  BSP. Treat that as a rollback decision point, not a packaging puzzle."
elif [ "$FAIL" -eq 1 ]; then
  say "  ${Y}${B}PARTIAL${Z} — meta-package present but checks failed above."
else
  say "  ${G}${B}SDK OPERATIONAL${Z}"
fi
[ "$WARN" -eq 1 ] && say "  Warnings present — review before logging any measured result."

# ---------------------------------------------------------------------------
if [ "$SAVE" -eq 1 ]; then
  mkdir -p manifests
  OUT="manifests/jetpack-$(hostname)-$(date -u +%Y%m%dT%H%M%SZ).txt"
  "$0" --quiet >/dev/null 2>&1
  { QUIET=1; "$0" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; } >"$OUT"
  say ""
  say "  Saved: $OUT"
fi

exit "$FAIL"
