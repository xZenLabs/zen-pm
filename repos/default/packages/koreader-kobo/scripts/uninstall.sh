#!/bin/sh
set -eu

ONBOARD_DIR="/mnt/onboard"
ADDS_DIR="$ONBOARD_DIR/.adds"
NM_DIR="$ADDS_DIR/nm"
KO_DIR="$ADDS_DIR/koreader"
KO_PREV_DIR="$ADDS_DIR/koreader.previous"

if [ ! -d "$ONBOARD_DIR" ]; then
	echo "Kobo storage /mnt/onboard not found"
	exit 1
fi

rm -f "$NM_DIR/zenpm-koreader"

if [ -d "$KO_PREV_DIR" ]; then
	rm -rf "$KO_DIR"
	mv "$KO_PREV_DIR" "$KO_DIR"
	echo "Restored previous KOReader backup"
else
	rm -rf "$KO_DIR"
fi

sync

echo "KOReader uninstall complete"
