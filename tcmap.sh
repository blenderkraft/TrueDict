#!/bin/bash
# Map/unmap a TrueCrypt/VeraCrypt volume, read-only.
#
# Usage:
#   tcmap.sh map <volume_file> [mapping_name] [--veracrypt]
#   tcmap.sh unmap <mapping_name>
#
# Prompts for the sudo password and the volume passphrase interactively
# (both hidden, via sudo's and cryptsetup's own terminal prompts) -
# neither is ever typed in clear text or passed as an argument.
set -eu

usage() {
    cat >&2 <<EOF
Usage:
  $0 map <volume_file> [mapping_name] [--veracrypt]
  $0 unmap <mapping_name>

Examples:
  $0 map ~/volumes/private.tc mydata
  $0 map ~/volumes/private.tc mydata --veracrypt
  $0 unmap mydata
EOF
    exit 1
}

[ $# -ge 1 ] || usage
ACTION="$1"; shift

case "$ACTION" in
    map)
        [ $# -ge 1 ] || usage
        VOL="$1"; shift
        NAME=""
        VERACRYPT=""
        for arg in "$@"; do
            case "$arg" in
                --veracrypt) VERACRYPT="--veracrypt" ;;
                *) NAME="$arg" ;;
            esac
        done

        [ -f "$VOL" ] || { echo "Volume file not found: $VOL" >&2; exit 1; }
        if [ -z "$NAME" ]; then
            NAME="tc_$(basename "$VOL" | sed 's/[^A-Za-z0-9._-]/_/g')"
        fi
        MOUNTPOINT="/mnt/$NAME"

        if [ -e "/dev/mapper/$NAME" ]; then
            echo "Mapping '$NAME' already exists (/dev/mapper/$NAME) - unmap it first." >&2
            exit 1
        fi

        echo "Opening $VOL as '$NAME' (read-only)..."
        # sudo and cryptsetup each prompt on the terminal with echo off - the
        # sudo password and the volume passphrase are never captured into a
        # variable or shown on screen.
        sudo cryptsetup open --type tcrypt --readonly $VERACRYPT "$VOL" "$NAME"

        sudo mkdir -p "$MOUNTPOINT"
        sudo mount -o ro "/dev/mapper/$NAME" "$MOUNTPOINT"
        echo "Mounted read-only at $MOUNTPOINT"
        ;;

    unmap)
        [ $# -ge 1 ] || usage
        NAME="$1"
        MOUNTPOINT="/mnt/$NAME"

        if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
            sudo umount "$MOUNTPOINT"
        fi
        if [ -d "$MOUNTPOINT" ]; then
            sudo rmdir "$MOUNTPOINT" 2>/dev/null || true
        fi
        if [ -e "/dev/mapper/$NAME" ]; then
            sudo cryptsetup close "$NAME"
        fi
        echo "Unmapped '$NAME'"
        ;;

    *)
        usage
        ;;
esac
