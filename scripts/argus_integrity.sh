#!/usr/bin/env bash
# argus_integrity.sh — post-unclean-shutdown integrity audit
#
# Detects damage from hard power cuts across the storage stack, the package
# database, the git repo, the Python environment, and project data artifacts.
#
# Read-only. This script never modifies, repairs, or deletes anything. Where a
# repair is warranted it prints the command and leaves the decision to you.
#
# Usage:
#   argus_integrity.sh                 run the audit
#   argus_integrity.sh baseline        record a checksum manifest for future runs
#   argus_integrity.sh --full          audit including large capture files
#   argus_integrity.sh --out FILE      also write the report to FILE
#   argus_integrity.sh --help
#
# Exit: 0 clean · 1 warnings present · 2 failures present

set -uo pipefail

# ---------------------------------------------------------------- configuration

PROJECT_ROOT="${ARGUS_PROJECT_ROOT:-$HOME/projects/computer-vision/maritime-edge}"
VENV_DIR="${ARGUS_VENV:-$PROJECT_ROOT/.venv}"
STATE_DIR="${ARGUS_STATE_DIR:-$HOME/.local/state/argus/integrity}"
BASELINE_FILE="$STATE_DIR/manifest.sha256"
COUNTER_FILE="$STATE_DIR/nvme_counters"

# Files larger than this are skipped by the checksum baseline unless --full.
MAX_HASH_BYTES=$((64 * 1024 * 1024))

# Raw YUYV frame geometries this rig produces: label:width:height
YUYV_GEOMETRIES=("4K:3840:2160" "1080p:1920:1080" "720p:1280:720")

# ---------------------------------------------------------------------- globals

MODE="check"
FULL=0
OUT_FILE=""
WARN_COUNT=0
FAIL_COUNT=0
SUDO_OK=0

# ------------------------------------------------------------------- formatting

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_HEAD=$'\033[1;36m'; C_OK=$'\033[0;32m'; C_WARN=$'\033[0;33m'
    C_FAIL=$'\033[0;31m'; C_DIM=$'\033[0;90m'; C_OFF=$'\033[0m'
else
    C_HEAD=""; C_OK=""; C_WARN=""; C_FAIL=""; C_DIM=""; C_OFF=""
fi

emit() {
    printf '%s\n' "$1"
    [[ -n "$OUT_FILE" ]] && printf '%s\n' "$(sed 's/\x1b\[[0-9;]*m//g' <<<"$1")" >>"$OUT_FILE"
    return 0
}

section() { emit ""; emit "${C_HEAD}=== $* ${C_OFF}"; }
ok()      { emit "  ${C_OK}[ OK ]${C_OFF}   $*"; }
warn()    { emit "  ${C_WARN}[WARN]${C_OFF}   $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail()    { emit "  ${C_FAIL}[FAIL]${C_OFF}   $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info()    { emit "  ${C_DIM}[ -- ]${C_OFF}   $*"; }
detail()  { emit "           ${C_DIM}$*${C_OFF}"; }

# ------------------------------------------------------------------ arg parsing

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        baseline)  MODE="baseline"; shift ;;
        check)     MODE="check";    shift ;;
        --full)    FULL=1;          shift ;;
        --out)     OUT_FILE="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
done

[[ -n "$OUT_FILE" ]] && : >"$OUT_FILE"
mkdir -p "$STATE_DIR"

# ------------------------------------------------------------------- privileges

# Non-interactive sudo probe. Several checks (dmesg, tune2fs, nvme) need root.
# A failure here is itself worth reporting: it is why unattended captures lose
# their power-state block.
if sudo -n true 2>/dev/null; then
    SUDO_OK=1
fi

sudo_run() {
    if [[ $SUDO_OK -eq 1 ]]; then
        sudo -n "$@" 2>/dev/null
    else
        return 127
    fi
}

# ------------------------------------------------------------------------ banner

emit "Argus — post-unclean-shutdown integrity audit"
emit "$(date -u '+%Y-%m-%d %H:%M:%SZ')  |  $(hostname)  |  mode: $MODE"
emit "project: $PROJECT_ROOT"

if [[ $SUDO_OK -eq 0 ]]; then
    section "PRIVILEGES"
    warn "passwordless sudo unavailable — root-only checks will be skipped"
    detail "run 'sudo -v' first to cache credentials, then re-run this script"
    detail "this is the same condition that drops jetson_clocks from captured manifests"
fi

# ============================================================ STAGE A — ledger

stage_shutdown_ledger() {
    section "STAGE A — unclean shutdown ledger"

    local dev="/dev/nvme0"
    if ! command -v nvme >/dev/null 2>&1; then
        warn "nvme-cli not installed — SMART counters unavailable"
        detail "sudo apt install nvme-cli"
        return
    fi

    local smart
    smart="$(sudo_run nvme smart-log "$dev")" || {
        warn "could not read SMART log (needs root)"
        return
    }

    local field
    get() { field="$(grep -m1 "^$1" <<<"$smart" | sed 's/.*: *//' | tr -d ' ')"; }

    get "critical_warning";     local crit="$field"
    get "media_errors";         local media="$field"
    get "num_err_log_entries";  local errlog="$field"
    get "unsafe_shutdowns";     local unsafe="$field"
    get "power_cycles";         local cycles="$field"
    get "percentage_used";      local used="$field"
    get "available_spare";      local spare="$field"

    [[ "$crit" == "0" ]] \
        && ok "critical_warning 0" \
        || fail "critical_warning $crit — controller reports a fault condition"

    [[ "$media" == "0" ]] \
        && ok "media_errors 0 — no uncorrectable read/write errors" \
        || fail "media_errors $media — uncorrectable errors present"

    [[ "$errlog" == "0" ]] \
        && ok "num_err_log_entries 0" \
        || warn "num_err_log_entries $errlog — inspect: sudo nvme error-log $dev"

    ok "wear: ${used} used, ${spare} spare remaining"

    # Delta since last run. A rising count with clean media is expected wear on
    # the journal, not damage — but the trend is what makes it actionable.
    local prev_unsafe=""
    if [[ -f "$COUNTER_FILE" ]]; then
        prev_unsafe="$(grep -m1 '^unsafe_shutdowns=' "$COUNTER_FILE" | cut -d= -f2)"
    fi

    if [[ -n "$prev_unsafe" ]] && [[ "$unsafe" =~ ^[0-9]+$ ]]; then
        local delta=$((unsafe - prev_unsafe))
        if [[ $delta -gt 0 ]]; then
            warn "unsafe_shutdowns $unsafe (+$delta since last audit)"
            detail "each is a hard power cut; the checks below cover their fallout"
        else
            ok "unsafe_shutdowns $unsafe (no change since last audit)"
        fi
    else
        info "unsafe_shutdowns $unsafe of $cycles power cycles (no prior baseline)"
    fi

    {
        echo "unsafe_shutdowns=$unsafe"
        echo "power_cycles=$cycles"
        echo "media_errors=$media"
        echo "recorded=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >"$COUNTER_FILE"
}

# ======================================================== STAGE B — filesystem

stage_filesystem() {
    section "STAGE B — filesystem state"

    local root_src
    root_src="$(findmnt -no SOURCE / 2>/dev/null)"
    info "root device: ${root_src:-unknown}"

    # A root filesystem remounted read-only is the loudest possible signal that
    # the kernel hit an error it could not safely continue through.
    if findmnt -no OPTIONS / 2>/dev/null | grep -qw 'ro'; then
        fail "root is mounted READ-ONLY — the kernel forced it after an error"
        detail "this is not a normal state; do not write to the device until reviewed"
    else
        ok "root mounted read-write"
    fi

    if [[ -n "$root_src" ]]; then
        local tune
        tune="$(sudo_run tune2fs -l "$root_src")" || {
            warn "could not read superblock (needs root)"
            return
        }

        local fsstate errcount lasterr
        fsstate="$(grep -m1 'Filesystem state:' <<<"$tune" | sed 's/.*: *//')"
        errcount="$(grep -m1 'FS Error count:' <<<"$tune" | sed 's/.*: *//')"
        lasterr="$(grep -m1 'Last error time:' <<<"$tune" | sed 's/.*: *//')"

        case "$fsstate" in
            clean)
                ok "superblock state: clean" ;;
            "clean with errors")
                fail "superblock state: clean with errors — errors were recorded"
                detail "schedule a check: sudo touch /forcefsck && sudo reboot" ;;
            *)
                warn "superblock state: ${fsstate:-unreadable}" ;;
        esac

        if [[ -n "$errcount" ]]; then
            fail "FS Error count: $errcount (last: ${lasterr:-unknown})"
            detail "these persist in the superblock until fsck clears them"
        else
            ok "no errors recorded in superblock"
        fi
    fi

    # Journal replay for the current boot. Its presence means the last shutdown
    # was unclean and the journal did its job; its absence means a clean unmount.
    local kmsg
    kmsg="$(sudo_run dmesg)" || {
        warn "kernel buffer unreadable (kernel.dmesg_restrict=1, needs root)"
        return
    }

    if grep -q 'EXT4-fs.*recovery complete' <<<"$kmsg"; then
        ok "journal replay completed this boot — unclean shutdown was recovered"
    else
        ok "no journal replay this boot — last shutdown was clean"
    fi

    if grep -qiE 'EXT4-fs error|orphan|inode.*corrupt|htree' <<<"$kmsg"; then
        fail "filesystem errors in kernel log:"
        grep -iE 'EXT4-fs error|orphan|inode.*corrupt|htree' <<<"$kmsg" \
            | head -8 | while read -r l; do detail "$l"; done
    else
        ok "no ext4 errors in kernel log"
    fi

    if grep -qiE 'I/O error|blk_update_request|nvme.*(reset|timeout|abort)' <<<"$kmsg"; then
        fail "block layer errors in kernel log:"
        grep -iE 'I/O error|blk_update_request|nvme.*(reset|timeout|abort)' <<<"$kmsg" \
            | head -8 | while read -r l; do detail "$l"; done
    else
        ok "no block I/O errors in kernel log"
    fi
}

# ============================================================ STAGE C — dpkg

stage_packages() {
    section "STAGE C — package database"

    # A power cut mid-apt leaves packages half-configured. This is the most
    # common real casualty of a hard cut on a system that was being updated.
    local audit
    audit="$(dpkg --audit 2>/dev/null)"
    if [[ -z "$audit" ]]; then
        ok "dpkg --audit reports no inconsistencies"
    else
        fail "dpkg reports packages in an inconsistent state:"
        head -12 <<<"$audit" | while read -r l; do detail "$l"; done
        detail "repair with: sudo dpkg --configure -a"
    fi

    local broken
    broken="$(dpkg -l 2>/dev/null | awk '$1 !~ /^(ii|rc)$/ && NR>5 {print $1, $2}')"
    if [[ -z "$broken" ]]; then
        ok "no packages in half-installed or half-configured state"
    else
        warn "packages not fully installed:"
        head -10 <<<"$broken" | while read -r l; do detail "$l"; done
    fi

    if [[ -f /var/lib/dpkg/status ]] && [[ ! -s /var/lib/dpkg/status ]]; then
        fail "/var/lib/dpkg/status is zero-length — package database is destroyed"
        detail "recover from /var/backups/dpkg.status.0"
    fi
}

# ============================================================= STAGE D — repo

stage_repo() {
    section "STAGE D — repository integrity"

    if [[ ! -d "$PROJECT_ROOT/.git" ]]; then
        warn "no git repo at $PROJECT_ROOT — skipping"
        return
    fi

    # git fsck is the only check here that verifies object content rather than
    # metadata: every object is re-hashed and compared to its own name.
    local fsck
    fsck="$(git -C "$PROJECT_ROOT" fsck --no-progress --no-dangling 2>&1)"
    if [[ -z "$fsck" ]]; then
        ok "git fsck clean — all objects hash-verified"
    else
        fail "git fsck reported problems:"
        head -10 <<<"$fsck" | while read -r l; do detail "$l"; done
        detail "recoverable if origin is intact: re-clone and copy untracked work across"
    fi

    local dirty
    dirty="$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)"
    if [[ -z "$dirty" ]]; then
        ok "working tree clean"
    else
        info "working tree has $(wc -l <<<"$dirty") modified/untracked path(s)"
        detail "expected during active work; listed here so truncation is visible"
        head -8 <<<"$dirty" | while read -r l; do detail "$l"; done
    fi

    local stashes
    stashes="$(git -C "$PROJECT_ROOT" stash list 2>/dev/null | wc -l)"
    [[ "$stashes" -gt 0 ]] && info "$stashes stash entr(ies) present"

    # An index written but not fsync'd at the moment of a cut can survive as a
    # truncated file; git will refuse to read it.
    if ! git -C "$PROJECT_ROOT" status >/dev/null 2>&1; then
        fail "git index is unreadable — likely truncated"
        detail "repair: rm $PROJECT_ROOT/.git/index && git -C $PROJECT_ROOT reset"
    fi
}

# ========================================================= STAGE E — python env

stage_python() {
    section "STAGE E — python environment"

    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        warn "no venv interpreter at $VENV_DIR/bin/python — skipping"
        return
    fi

    if ! "$VENV_DIR/bin/python" -c 'pass' 2>/dev/null; then
        fail "venv interpreter will not start"
        return
    fi
    ok "venv interpreter starts"

    # --system-site-packages is load-bearing for the TensorRT bindings; if the
    # pyvenv.cfg was truncated the venv silently loses visibility of them.
    if [[ -f "$VENV_DIR/pyvenv.cfg" ]]; then
        if grep -qi 'include-system-site-packages *= *true' "$VENV_DIR/pyvenv.cfg"; then
            ok "pyvenv.cfg intact — system site-packages enabled"
        else
            fail "pyvenv.cfg does not enable system site-packages"
            detail "TensorRT bindings will not import; the file may be truncated"
        fi
    else
        fail "pyvenv.cfg missing"
    fi

    local mod
    for mod in numpy cv2 tensorrt torch; do
        if "$VENV_DIR/bin/python" -c "import $mod" 2>/dev/null; then
            ok "import $mod"
        else
            warn "import $mod failed"
            detail "may be uninstalled rather than corrupt — check before reinstalling"
        fi
    done

    # Truncated .pyc files raise at import; compileall re-reads every source file
    # in the tree, which surfaces truncated .py sources too.
    local compile_out
    compile_out="$("$VENV_DIR/bin/python" -m compileall -q "$PROJECT_ROOT" 2>&1 \
                   | grep -viE 'error.*\.venv|^Listing|^Compiling')"
    if [[ -z "$compile_out" ]]; then
        ok "all project sources parse"
    else
        fail "source files failed to parse:"
        head -8 <<<"$compile_out" | while read -r l; do detail "$l"; done
    fi
}

# ======================================================== STAGE F — truncation

stage_truncation() {
    section "STAGE F — truncated and zero-length files"

    if [[ ! -d "$PROJECT_ROOT" ]]; then
        warn "project root not found — skipping"
        return
    fi

    # Zero-length files are the characteristic signature of a power cut: the
    # inode was allocated and the metadata journalled, but the data never landed.
    local zeros
    zeros="$(find "$PROJECT_ROOT" -type f -empty \
             -not -path '*/.git/*' \
             -not -path '*/.venv/*' \
             -not -name '__init__.py' \
             -not -name '.gitkeep' \
             -not -name 'py.typed' \
             -not -name '.gitignore' 2>/dev/null)"

    if [[ -z "$zeros" ]]; then
        ok "no unexpected zero-length files in project tree"
    else
        warn "$(wc -l <<<"$zeros") zero-length file(s) — candidates for truncation:"
        head -12 <<<"$zeros" | while read -r l; do detail "$l"; done
    fi

    # Files written near the moment of a cut are the only ones at real risk.
    # Everything synced earlier is safe regardless of how the machine died.
    local recent
    recent="$(find "$PROJECT_ROOT" -type f -newermt '-24 hours' \
              -not -path '*/.git/*' -not -path '*/.venv/*' 2>/dev/null | wc -l)"
    info "$recent file(s) modified in the last 24h — the at-risk window"
}

# ====================================================== STAGE G — data artifacts

stage_artifacts() {
    section "STAGE G — data artifact validation"

    [[ -d "$PROJECT_ROOT" ]] || { warn "project root not found — skipping"; return; }

    # --- raw YUYV captures: byte count must divide evenly into whole frames ---
    local raws raw sz label w h fsz geo matched checked=0 bad=0
    mapfile -t raws < <(find "$PROJECT_ROOT" -type f \( -name '*.raw' -o -name '*.yuyv' \) 2>/dev/null)

    if [[ ${#raws[@]} -eq 0 ]]; then
        info "no raw YUYV captures found"
    else
        for raw in "${raws[@]}"; do
            sz="$(stat -c%s "$raw" 2>/dev/null)" || continue
            # Empty files are reported by Stage F; skip to avoid double-counting.
            [[ $sz -eq 0 ]] && continue
            matched=""
            for geo in "${YUYV_GEOMETRIES[@]}"; do
                IFS=: read -r label w h <<<"$geo"
                fsz=$((w * h * 2))
                if [[ $sz -ge $fsz ]] && [[ $((sz % fsz)) -eq 0 ]]; then
                    matched="$label ($((sz / fsz)) frames)"; break
                fi
            done
            checked=$((checked + 1))
            if [[ -z "$matched" ]]; then
                bad=$((bad + 1))
                fail "partial frame: $(basename "$raw") ($sz bytes)"
                detail "not a whole multiple of any known geometry — last frame truncated"
            fi
        done
        [[ $bad -eq 0 ]] && ok "$checked raw capture(s): all contain whole frames"
    fi

    # --- PNG: magic bytes plus IEND trailer ---
    local pngs png badpng=0 npng=0
    mapfile -t pngs < <(find "$PROJECT_ROOT" -type f -name '*.png' 2>/dev/null | head -400)
    if [[ ${#pngs[@]} -gt 0 ]]; then
        for png in "${pngs[@]}"; do
            npng=$((npng + 1))
            if ! tail -c 12 "$png" 2>/dev/null | grep -qa 'IEND'; then
                badpng=$((badpng + 1))
                [[ $badpng -le 6 ]] && fail "truncated PNG: $(basename "$png")"
            fi
        done
        [[ $badpng -eq 0 ]] && ok "$npng PNG(s): all have complete IEND trailers"
    fi

    # --- PDF: header plus %%EOF trailer (the navy document series) ---
    local pdfs pdf badpdf=0 npdf=0
    mapfile -t pdfs < <(find "$PROJECT_ROOT" -type f -name '*.pdf' 2>/dev/null | head -200)
    if [[ ${#pdfs[@]} -gt 0 ]]; then
        for pdf in "${pdfs[@]}"; do
            npdf=$((npdf + 1))
            if ! tail -c 32 "$pdf" 2>/dev/null | grep -qa '%%EOF'; then
                badpdf=$((badpdf + 1))
                fail "truncated PDF: $(basename "$pdf")"
            fi
        done
        [[ $badpdf -eq 0 ]] && ok "$npdf PDF(s): all have %%EOF trailers"
    fi

    # --- CSV: uniform column count (catches a half-written final row) ---
    local csvs csv badcsv=0 ncsv=0 cols
    mapfile -t csvs < <(find "$PROJECT_ROOT" -type f -name '*.csv' 2>/dev/null | head -200)
    if [[ ${#csvs[@]} -gt 0 ]]; then
        for csv in "${csvs[@]}"; do
            ncsv=$((ncsv + 1))
            cols="$(awk -F, 'NR>1 {print NF}' "$csv" 2>/dev/null | sort -u | wc -l)"
            if [[ "$cols" -gt 1 ]]; then
                badcsv=$((badcsv + 1))
                warn "ragged CSV: $(basename "$csv") — inconsistent column counts"
                detail "check the final row; a cut mid-append leaves it partial"
            fi
        done
        [[ $badcsv -eq 0 ]] && ok "$ncsv CSV file(s): uniform column counts"
    fi

    # --- JSON / JSON-lines (AIS logs) ---
    if command -v python3 >/dev/null 2>&1; then
        local jsons json badjson=0 njson=0
        mapfile -t jsons < <(find "$PROJECT_ROOT" -type f \
            \( -name '*.json' -o -name '*.jsonl' \) 2>/dev/null | head -200)
        if [[ ${#jsons[@]} -gt 0 ]]; then
            for json in "${jsons[@]}"; do
                njson=$((njson + 1))
                if ! python3 - "$json" <<'PY' 2>/dev/null
import json, sys
p = sys.argv[1]
with open(p, "r", errors="replace") as fh:
    if p.endswith(".jsonl"):
        for line in fh:
            if line.strip():
                json.loads(line)
    else:
        json.load(fh)
PY
                then
                    badjson=$((badjson + 1))
                    fail "unparseable JSON: $(basename "$json")"
                fi
            done
            [[ $badjson -eq 0 ]] && ok "$njson JSON file(s): all parse"
        fi
    fi
}

# ======================================================== STAGE H — checksums

hash_targets() {
    # Scripts and configs always; bulk data only under --full. Hashing every
    # capture would make the baseline too slow to run habitually, and captures
    # are already covered structurally in Stage G.
    if [[ $FULL -eq 1 ]]; then
        find "$PROJECT_ROOT" -type f \
            -not -path '*/.git/*' -not -path '*/.venv/*' \
            -size -"$((MAX_HASH_BYTES / 1024))"k 2>/dev/null
    else
        find "$PROJECT_ROOT" -type f \
            \( -name '*.sh' -o -name '*.py' -o -name '*.md' \
               -o -name '*.toml' -o -name '*.yaml' -o -name '*.yml' \
               -o -name '*.cfg' -o -name '*.json' -o -name '*.jsonl' \
               -o -name '*.csv' \) \
            -not -path '*/.git/*' -not -path '*/.venv/*' 2>/dev/null
    fi
}

stage_baseline() {
    section "BASELINE — recording checksum manifest"

    local count
    hash_targets | sort | xargs -r sha256sum >"$BASELINE_FILE" 2>/dev/null
    count="$(wc -l <"$BASELINE_FILE")"

    if [[ "$count" -eq 0 ]]; then
        warn "recorded 0 checksums — nothing under $PROJECT_ROOT matched the scope"
        detail "use --full to include data files, or check the project root path"
    else
        ok "recorded $count file checksum(s)"
    fi
    detail "manifest: $BASELINE_FILE"
    detail "scope: $([[ $FULL -eq 1 ]] && echo 'all files under size cap' || echo 'source and config only')"
    emit ""
    emit "  Future runs will verify against this manifest. Re-record it after"
    emit "  intentional edits, or the next audit will report your own changes"
    emit "  as corruption."
}

stage_verify() {
    section "STAGE H — checksum verification"

    if [[ ! -f "$BASELINE_FILE" ]]; then
        warn "no baseline manifest — silent corruption cannot be detected"
        detail "record one now: $(basename "$0") baseline"
        detail "without it, the stages above catch structural damage only"
        return
    fi

    local recorded nbase
    recorded="$(date -r "$BASELINE_FILE" '+%Y-%m-%d %H:%M' 2>/dev/null)"
    nbase="$(wc -l <"$BASELINE_FILE")"

    if [[ "$nbase" -eq 0 ]]; then
        warn "baseline manifest is empty — verification is a no-op"
        detail "re-record it: $(basename "$0") baseline"
        return
    fi
    info "baseline recorded $recorded ($nbase files)"

    local result missing changed
    result="$(sha256sum -c "$BASELINE_FILE" 2>/dev/null)"
    changed="$(grep -c ': FAILED$' <<<"$result")"
    missing="$(grep -c 'No such file' <<<"$result")"

    if [[ "$changed" -eq 0 ]]; then
        ok "all baselined files match their recorded checksums"
    else
        warn "$changed file(s) differ from baseline:"
        grep ': FAILED$' <<<"$result" | head -10 \
            | while read -r l; do detail "${l%: FAILED}"; done
        detail "expected if you edited them; investigate any you did not touch"
    fi

    [[ "$missing" -gt 0 ]] && info "$missing baselined file(s) no longer present"
}

# ---------------------------------------------------------------------- summary

summary() {
    section "SUMMARY"

    if [[ $FAIL_COUNT -eq 0 ]] && [[ $WARN_COUNT -eq 0 ]]; then
        emit "  ${C_OK}NO DAMAGE DETECTED${C_OFF}"
        emit "  Storage, package database, repo, environment, and artifacts all check clean."
    elif [[ $FAIL_COUNT -eq 0 ]]; then
        emit "  ${C_WARN}NO CORRUPTION FOUND — $WARN_COUNT WARNING(S)${C_OFF}"
        emit "  No structural damage detected. The warnings above are advisory:"
        emit "  review them before logging measured results."
    else
        emit "  ${C_FAIL}DAMAGE DETECTED — $FAIL_COUNT FAILURE(S), $WARN_COUNT WARNING(S)${C_OFF}"
        emit "  Treat affected artifacts as unusable. Re-capture rather than repair:"
        emit "  a truncated capture cannot be reconstructed, and a partially written"
        emit "  frame will silently skew any statistic computed from it."
    fi

    emit ""
    emit "  ${C_DIM}Scope note: this audit detects structural damage — truncation, parse${C_OFF}"
    emit "  ${C_DIM}failures, filesystem and controller errors. Silent bit-level corruption${C_OFF}"
    emit "  ${C_DIM}is only detectable against a prior checksum baseline. ext4 does not${C_OFF}"
    emit "  ${C_DIM}checksum file data, so a clean result is strong evidence, not proof.${C_OFF}"

    [[ -n "$OUT_FILE" ]] && emit "" && emit "  report written to $OUT_FILE"

    [[ $FAIL_COUNT -gt 0 ]] && return 2
    [[ $WARN_COUNT -gt 0 ]] && return 1
    return 0
}

# ------------------------------------------------------------------------- main

if [[ "$MODE" == "baseline" ]]; then
    stage_baseline
    exit 0
fi

stage_shutdown_ledger
stage_filesystem
stage_packages
stage_repo
stage_python
stage_truncation
stage_artifacts
stage_verify
summary
exit $?
