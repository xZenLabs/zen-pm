#!/bin/sh
# Name: Zen PM
# Author: ZenPackageManager
# DontUseFBInk
set -eu

APP_ID="com.zenpm.waf"
APP_NAME="Zen Package Manager"
APPREG_DB="/var/local/appreg.db"
MESQUITE_TARGET="/var/local/mesquite/zenpm"

# The zip extracts zenpm/ directly to the Kindle USB root (/mnt/us/zenpm/),
# so no file copying is needed — this script just wires up the app.
PAYLOAD_DIR="/mnt/us/zenpm"

fail() { echo "[zenpm] $*" >&2; exit 1; }

[ -d "$PAYLOAD_DIR" ]                     || fail "Payload missing: $PAYLOAD_DIR"
[ -d "$PAYLOAD_DIR/frontend/kindle" ] || fail "WAF missing: $PAYLOAD_DIR/frontend/kindle"
[ -d "$PAYLOAD_DIR/backend" ]             || fail "Backend missing: $PAYLOAD_DIR/backend"
[ -f "$APPREG_DB" ]                       || fail "appreg.db not found: $APPREG_DB"
command -v sqlite3 >/dev/null 2>&1        || fail "sqlite3 not found"

# Select ABI-appropriate binary and make it executable.
if [ -f /lib/ld-linux-armhf.so.3 ]; then
    ABI=hf
else
    ABI=sf
fi
[ -f "$PAYLOAD_DIR/backend/zenpm-$ABI" ] || fail "Binary missing: zenpm-$ABI"
cp "$PAYLOAD_DIR/backend/zenpm-$ABI" "$PAYLOAD_DIR/backend/zenpm"
chmod +x "$PAYLOAD_DIR/backend/zenpm"

rm -rf "$MESQUITE_TARGET"
mkdir -p "$MESQUITE_TARGET"
cp -R "$PAYLOAD_DIR/frontend/kindle"/. "$MESQUITE_TARGET"/

sqlite3 "$APPREG_DB" <<EOF
INSERT OR IGNORE INTO interfaces(interface) VALUES('application');
INSERT OR IGNORE INTO handlerIds(handlerId) VALUES('$APP_ID');
INSERT OR REPLACE INTO properties(handlerId,name,value) VALUES('$APP_ID','lipcId','$APP_ID');
INSERT OR REPLACE INTO properties(handlerId,name,value) VALUES('$APP_ID','command','/usr/bin/mesquite -l $APP_ID -c file://$MESQUITE_TARGET/');
INSERT OR REPLACE INTO properties(handlerId,name,value) VALUES('$APP_ID','name','$APP_NAME');
INSERT OR REPLACE INTO properties(handlerId,name,value) VALUES('$APP_ID','description','Zen Package Manager WAF');
INSERT OR REPLACE INTO properties(handlerId,name,value) VALUES('$APP_ID','supportedOrientation','U');
EOF

sync

# Always stop any existing daemon so the new binary (with log redirect) takes over.
# An old daemon started without log redirect would leave no log file.
ZENPM_LOG="$PAYLOAD_DIR/zenpm.log"
pkill -f 'zenpm serve' 2>/dev/null || true
sleep 1
nohup "$PAYLOAD_DIR/backend/zenpm" serve --port 8080 >>"$ZENPM_LOG" 2>&1 &

echo "ZenPM installed. Launching..."

# Stop any running instance so mesquite reloads files from disk on next start.
# Without this, 'start' just foregrounds the cached in-memory app.
lipc-set-prop com.lab126.appmgrd stop app://$APP_ID 2>/dev/null || true
sleep 1
pkill -f "mesquite.*$APP_ID" 2>/dev/null || true
sleep 2

nohup lipc-set-prop com.lab126.appmgrd start app://$APP_ID >/dev/null 2>&1 &
