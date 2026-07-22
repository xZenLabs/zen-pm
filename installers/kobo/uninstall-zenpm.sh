#!/bin/sh
set -eu

ONBOARD_DIR="/mnt/onboard"
ADDS_DIR="$ONBOARD_DIR/.adds"
ZENPM_DIR="$ADDS_DIR/ZenPM"
NM_DIR="$ADDS_DIR/nm"
PERSIST_DIR="$ADDS_DIR/.ZenPM"
REMOVE_SETTINGS=0

case "${1:-}" in
    "") ;;
    --remove-settings) REMOVE_SETTINGS=1 ;;
    *)
        echo "Usage: $0 [--remove-settings]" >&2
        exit 2
        ;;
esac

if [ ! -d "$ONBOARD_DIR" ]; then
    echo "Kobo storage /mnt/onboard not found"
    exit 1
fi

rm -f "$NM_DIR/ZenPM-main"
rm -rf "$ZENPM_DIR"
if [ "$REMOVE_SETTINGS" -eq 1 ]; then
    rm -rf "$PERSIST_DIR"
fi
sync

echo "ZenPM Kobo uninstall complete"
