#!/bin/sh
set -eu

APP_ID="com.zenlabs.zenpm"
APPREG_DB="/var/local/appreg.db"
MESQUITE_TARGET="/var/local/mesquite/ZenPM"
PAYLOAD_DIR="/mnt/us/ZenPM"
PERSIST_DIR="/mnt/us/.ZenPM"
REMOVE_SETTINGS=0

case "${1:-}" in
    "") ;;
    --remove-settings) REMOVE_SETTINGS=1 ;;
    *)
        echo "Usage: $0 [--remove-settings]" >&2
        exit 2
        ;;
esac

pkill -f 'zenpm serve' 2>/dev/null || true
lipc-set-prop com.lab126.appmgrd stop "app://$APP_ID" 2>/dev/null || true
pkill -f "mesquite.*$APP_ID" 2>/dev/null || true

if [ -f "$APPREG_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$APPREG_DB" <<EOF
DELETE FROM properties WHERE handlerId = '$APP_ID';
DELETE FROM handlerIds WHERE handlerId = '$APP_ID';
EOF
fi

rm -rf "$MESQUITE_TARGET" "$PAYLOAD_DIR"
if [ "$REMOVE_SETTINGS" -eq 1 ]; then
    rm -rf "$PERSIST_DIR"
fi
sync

echo "ZenPM Kindle uninstall complete"
