#!/bin/sh
set -eu

ONBOARD_DIR="/mnt/onboard"
ADDS_DIR="$ONBOARD_DIR/.adds"
NM_DIR="$ADDS_DIR/nm"
ZENPM_DIR="$ADDS_DIR/zenpm"

if [ ! -d "$ONBOARD_DIR" ]; then
	echo "Kobo storage /mnt/onboard not found"
	exit 1
fi

rm -f "$NM_DIR/zenpm-main"
rm -f "$ZENPM_DIR/bin/zenpm-menu.sh"

if [ -d "$ZENPM_DIR/logs" ] && [ -z "$(ls -A "$ZENPM_DIR/logs" 2>/dev/null)" ]; then
	rmdir "$ZENPM_DIR/logs" 2>/dev/null || true
fi

if [ -d "$ZENPM_DIR/bin" ] && [ -z "$(ls -A "$ZENPM_DIR/bin" 2>/dev/null)" ]; then
	rmdir "$ZENPM_DIR/bin" 2>/dev/null || true
fi

echo "ZenPM Kobo launcher entries removed"
