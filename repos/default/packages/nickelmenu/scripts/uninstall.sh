#!/bin/sh
set -eu

ONBOARD_DIR="/mnt/onboard"
NM_DIR="$ONBOARD_DIR/.adds/nm"

if [ ! -d "$ONBOARD_DIR" ]; then
	echo "Kobo storage /mnt/onboard not found"
	exit 1
fi

mkdir -p "$NM_DIR"

cat > "$NM_DIR/uninstall" <<'EOF'
created by zenpm
EOF

rm -f "$NM_DIR/zenpm-nickelmenu-installed"

echo "NickelMenu uninstall flag created at $NM_DIR/uninstall"
echo "Reboot the Kobo to complete uninstall"
