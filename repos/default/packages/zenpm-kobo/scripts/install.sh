#!/bin/sh
set -eu

ONBOARD_DIR="/mnt/onboard"
ADDS_DIR="$ONBOARD_DIR/.adds"
ZENPM_DIR="$ADDS_DIR/zenpm"
BIN_DIR="$ZENPM_DIR/bin"
LOG_DIR="$ZENPM_DIR/logs"
NM_DIR="$ADDS_DIR/nm"

if [ ! -d "$ONBOARD_DIR" ]; then
    echo "Kobo storage /mnt/onboard not found"
    exit 1
fi

mkdir -p "$BIN_DIR" "$LOG_DIR" "$NM_DIR"

cat > "$BIN_DIR/zenpm-menu.sh" <<'EOF'
#!/bin/sh
set -eu

BACKEND="/mnt/onboard/.adds/zenpm/backend/zenpm.sh"
LOG_FILE="/mnt/onboard/.adds/zenpm/logs/menu.log"

if [ ! -x "$BACKEND" ]; then
    echo "ZenPM backend not found at $BACKEND" > "$LOG_FILE"
    exit 1
fi

action="${1:-refresh}"

case "$action" in
    refresh)
        "$BACKEND" repo refresh > "$LOG_FILE" 2>&1
        ;;
    list)
        "$BACKEND" package list kobo > "$LOG_FILE" 2>&1
        ;;
    install-koreader)
        "$BACKEND" package install koreader-kobo > "$LOG_FILE" 2>&1
        ;;
    update)
        "$BACKEND" package update > "$LOG_FILE" 2>&1
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
EOF

echo "ZenPM Kobo menu entries installed"
echo "Log file: $LOG_DIR/menu.log"
