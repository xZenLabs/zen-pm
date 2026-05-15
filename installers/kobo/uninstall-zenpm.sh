#!/bin/sh
set -eu

ONBOARD_DIR="/mnt/onboard"
ADDS_DIR="$ONBOARD_DIR/.adds"
ZENPM_DIR="$ADDS_DIR/zenpm"
NM_DIR="$ADDS_DIR/nm"

if [ ! -d "$ONBOARD_DIR" ]; then
    echo "Kobo storage /mnt/onboard not found"
    exit 1
fi

rm -f "$NM_DIR/zenpm-main"
rm -rf "$ZENPM_DIR"
sync

echo "ZenPM Kobo uninstall complete"
