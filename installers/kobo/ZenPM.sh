#!/bin/sh
set -eu

ONBOARD_DIR="/mnt/onboard"
ADDS_DIR="$ONBOARD_DIR/.adds"
ZENPM_DIR="$ADDS_DIR/zenpm"
BIN_DIR="$ZENPM_DIR/bin"
LOG_DIR="$ZENPM_DIR/logs"
NM_DIR="$ADDS_DIR/nm"
BACKEND="$ZENPM_DIR/backend/zenpm"

if [ ! -d "$ONBOARD_DIR" ]; then
    echo "Kobo storage /mnt/onboard not found"
    exit 1
fi

# Select ABI-appropriate binary.
if [ -f /lib/ld-linux-armhf.so.3 ]; then ABI=hf; else ABI=sf; fi
[ -f "$ZENPM_DIR/backend/zenpm-$ABI" ] || { echo "Binary missing: zenpm-$ABI"; exit 1; }
cp "$ZENPM_DIR/backend/zenpm-$ABI" "$BACKEND"
chmod +x "$BACKEND"

mkdir -p "$BIN_DIR" "$LOG_DIR" "$NM_DIR"

if [ ! -f /usr/local/Kobo/imageformats/libnm.so ]; then
    NM_INSTALLER="$ZENPM_DIR/repos/default/packages/nickelmenu/scripts/install.sh"
    if [ -x "$NM_INSTALLER" ]; then
        echo "NickelMenu not detected, staging NickelMenu install package"
        "$NM_INSTALLER"
        echo "Reboot to apply NickelMenu install, then run this installer again"
        exit 0
    fi
    echo "NickelMenu is not installed and package installer is unavailable"
    exit 1
fi

cat > "$BIN_DIR/zenpm-menu.sh" <<'EOF'
#!/bin/sh
set -eu

BACKEND="/mnt/onboard/.adds/zenpm/backend/zenpm"
LOG_FILE="/mnt/onboard/.adds/zenpm/logs/menu.log"

if [ ! -x "$BACKEND" ]; then
    echo "ZenPM backend missing at $BACKEND" > "$LOG_FILE"
    exit 1
fi

action="${1:-refresh}"

case "$action" in
    refresh)
        ZENPM_PLATFORM=kobo "$BACKEND" repo refresh > "$LOG_FILE" 2>&1
        ;;
    list)
        ZENPM_PLATFORM=kobo "$BACKEND" package list kobo > "$LOG_FILE" 2>&1
        ;;
    install-koreader)
        ZENPM_PLATFORM=kobo "$BACKEND" package install koreader-kobo > "$LOG_FILE" 2>&1
        ;;
    update)
        ZENPM_PLATFORM=kobo "$BACKEND" package update > "$LOG_FILE" 2>&1
        ;;
    logs)
        ZENPM_PLATFORM=kobo "$BACKEND" logs --tail 120 > "$LOG_FILE" 2>&1
        ;;
    *)
        echo "Unknown action: $action" > "$LOG_FILE"
        exit 2
        ;;
esac
EOF
chmod +x "$BIN_DIR/zenpm-menu.sh"

cat > "$NM_DIR/zenpm-main" <<'EOF'
menu_item:main:ZenPM Refresh Repos:cmd_spawn:quiet:exec /mnt/onboard/.adds/zenpm/bin/zenpm-menu.sh refresh
menu_item:main:ZenPM List Kobo Packages:cmd_spawn:quiet:exec /mnt/onboard/.adds/zenpm/bin/zenpm-menu.sh list
menu_item:main:ZenPM Install KOReader:cmd_spawn:quiet:exec /mnt/onboard/.adds/zenpm/bin/zenpm-menu.sh install-koreader
menu_item:main:ZenPM Update Packages:cmd_spawn:quiet:exec /mnt/onboard/.adds/zenpm/bin/zenpm-menu.sh update
menu_item:main:ZenPM Show Last Log:cmd_spawn:quiet:exec /mnt/onboard/.adds/zenpm/bin/zenpm-menu.sh logs
EOF

ZENPM_PLATFORM=kobo "$BACKEND" repo refresh > "$LOG_DIR/install-refresh.log" 2>&1 || true
sync

echo "ZenPM Kobo install complete"
echo "NickelMenu entry file: $NM_DIR/zenpm-main"
echo "Action log: $LOG_DIR/menu.log"
