#!/bin/bash
# TrueDict: dictionary attack against a single TrueCrypt (optionally VeraCrypt)
# volume - tries every password in a candidate list against it until one opens
# the volume.
#
# Usage:
#   ./truedict.sh <volume_file> <password_list_file> [--veracrypt]
#
# By default only the classic TrueCrypt (tcrypt) format is tried. Pass
# --veracrypt to also run a second pass with VeraCrypt-compatible KDFs after
# the tcrypt pass fails for every password (this is much slower per attempt,
# so it's opt-in).
#
# Requires: cryptsetup (with tcrypt support), zenity (for the sudo password
# prompt). On success, the volume is briefly mounted read-only to confirm the
# password actually works, then immediately unmounted and closed again - this
# script never leaves a volume mounted. The working password and mount point
# (as it was mounted at the time) are recorded in truedict_results.txt (next
# to this script); every attempt is logged to truedict_attempts.log.
set -u

VERACRYPT_FLAG=0
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --veracrypt) VERACRYPT_FLAG=1 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

if [ "${#POSITIONAL[@]}" -ne 2 ]; then
    echo "Usage: $0 <volume_file> <password_list_file> [--veracrypt]" >&2
    exit 1
fi

VOL_ARG="${POSITIONAL[0]}"
PWFILE_ARG="${POSITIONAL[1]}"

if [ ! -f "$VOL_ARG" ]; then
    echo "FATAL: volume file not found: $VOL_ARG" >&2
    exit 1
fi
if [ ! -f "$PWFILE_ARG" ]; then
    echo "FATAL: password list not found: $PWFILE_ARG" >&2
    exit 1
fi

VOL="$(realpath "$VOL_ARG")"
PWFILE="$(realpath "$PWFILE_ARG")"
FNAME="$(basename "$VOL")"
MAPNAME="tc_$(echo "$FNAME" | sed 's/[^A-Za-z0-9._-]/_/g')"
MOUNTPOINT="/mnt/$MAPNAME"

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPTDIR/truedict_attempts.log"
RESULTS="$SCRIPTDIR/truedict_results.txt"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG"
}

# Capture the sudo password once via a GUI prompt (works even with no controlling tty).
SUDO_PW=$(zenity --password --title="sudo password: dictionary attack on $FNAME")
if [ -z "$SUDO_PW" ]; then
    log "[FATAL] $FNAME -> no sudo password entered, aborting"
    exit 1
fi
if ! printf '%s\n' "$SUDO_PW" | sudo -k -S true >/dev/null 2>>"$LOG"; then
    log "[FATAL] $FNAME -> sudo authentication failed"
    exit 1
fi

sudo_open() {
    local pw="$1" extra="$2"
    printf '%s\n%s' "$SUDO_PW" "$pw" | sudo -k -S cryptsetup open --type tcrypt $extra --readonly "$VOL" "$MAPNAME" >>"$LOG" 2>&1
}
sudo_plain() {
    printf '%s\n' "$SUDO_PW" | sudo -k -S "$@" >>"$LOG" 2>&1
}

# Idempotency: a prior run may have left this volume open and/or mounted.
if [ -e "/dev/mapper/$MAPNAME" ]; then
    if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
        log "[cleanup] $FNAME -> found leftover mount at $MOUNTPOINT from a prior run, unmounting it first"
        sudo_plain umount "$MOUNTPOINT"
        sudo_plain rmdir "$MOUNTPOINT"
    fi
    log "[cleanup] $FNAME -> found stale mapping $MAPNAME, closing it before retrying"
    sudo_plain cryptsetup close "$MAPNAME"
fi

# Load candidate passwords: strip CRLF, trim leading/trailing whitespace,
# drop blank lines, and drop duplicates (keeping first occurrence).
RAW_COUNT=$(sed 's/\r$//' "$PWFILE" | grep -vc '^[[:space:]]*$')
mapfile -t PASSWORDS < <(
    sed 's/\r$//' "$PWFILE" \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
        | grep -v '^$' \
        | awk '!seen[$0]++'
)
log "[start] $FNAME -> loaded ${#PASSWORDS[@]} unique candidate passwords ($RAW_COUNT lines, $((RAW_COUNT - ${#PASSWORDS[@]})) duplicates/blank removed) from $(basename "$PWFILE")"

MODES=(tcrypt)
[ "$VERACRYPT_FLAG" -eq 1 ] && MODES+=(veracrypt)

FOUND=0
MODE=""
WORKING_PW=""
ATTEMPT=0
for MODE_TRY in "${MODES[@]}"; do
    [ "$FOUND" -eq 1 ] && break
    for PW in "${PASSWORDS[@]}"; do
        ATTEMPT=$((ATTEMPT + 1))
        EXTRA_FLAG=""
        [ "$MODE_TRY" = "veracrypt" ] && EXTRA_FLAG="--veracrypt"
        log "[try] $FNAME attempt $ATTEMPT ($MODE_TRY)"
        if sudo_open "$PW" "$EXTRA_FLAG"; then
            FOUND=1
            MODE="$MODE_TRY"
            WORKING_PW="$PW"
            break
        fi
    done
done

if [ "$FOUND" -eq 1 ]; then
    sudo_plain mkdir -p "$MOUNTPOINT"
    if sudo_plain mount -o ro "/dev/mapper/$MAPNAME" "$MOUNTPOINT"; then
        log "[OK] $FNAME -> password: $WORKING_PW, mounted at $MOUNTPOINT ($MODE) - unmounting now"
        echo "$FNAME -> password: $WORKING_PW   ($MODE)" >> "$RESULTS"
        echo "SUCCESS: $FNAME opened with password '$WORKING_PW' ($MODE)"
        sudo_plain umount "$MOUNTPOINT"
        sudo_plain rmdir "$MOUNTPOINT"
        sudo_plain cryptsetup close "$MAPNAME"
        exit 0
    else
        log "[WARN] $FNAME -> opened with password '$WORKING_PW' but mount failed"
        echo "$FNAME -> password: $WORKING_PW   OPENED but MOUNT FAILED ($MODE)" >> "$RESULTS"
        echo "PARTIAL: $FNAME opened with password '$WORKING_PW' but the filesystem mount failed"
        sudo_plain cryptsetup close "$MAPNAME"
        exit 2
    fi
else
    log "[FAIL] $FNAME -> no candidate password worked"
    echo "$FNAME -> FAILED (no candidate password worked)" >> "$RESULTS"
    echo "FAILED: no password in $(basename "$PWFILE") opened $FNAME"
    exit 1
fi
