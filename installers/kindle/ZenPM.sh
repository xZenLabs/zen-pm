#!/bin/sh
# Name: ZenPM
# Author: ZenLabs
# Icon: data:image/png;base64,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
# DontUseFBInk
set -eu

APP_ID="com.zenlabs.zenpm"
APP_NAME="Zen Package Manager"
APPREG_DB="/var/local/appreg.db"
MESQUITE_TARGET="/var/local/mesquite/ZenPM"

# The zip extracts ZenPM/ directly to the Kindle USB root (/mnt/us/ZenPM/),
# so no file copying is needed — this script just wires up the app.
PAYLOAD_DIR="/mnt/us/ZenPM"

fail() { echo "[ZenPM] $*" >&2; exit 1; }

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
ZENPM_LOG="$PAYLOAD_DIR/ZenPM.log"
pkill -f 'zenpm serve' 2>/dev/null || true
# Wait for the daemon to exit and free port 8080; SIGKILL if it won't die.
i=0
while pgrep -f 'zenpm serve' >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 5 ]; then
        pkill -9 -f 'zenpm serve' 2>/dev/null || true
        sleep 1
        break
    fi
    sleep 1
done
nohup "$PAYLOAD_DIR/backend/zenpm" serve --port 8080 >>"$ZENPM_LOG" 2>&1 &

echo "ZenPM installed. Launching..."

# Stop any running instance so mesquite reloads files from disk on next start.
# Without this, 'start' just foregrounds the cached in-memory app.
lipc-set-prop com.lab126.appmgrd stop app://$APP_ID 2>/dev/null || true
sleep 1
pkill -f "mesquite.*$APP_ID" 2>/dev/null || true
sleep 2

nohup lipc-set-prop com.lab126.appmgrd start app://$APP_ID >/dev/null 2>&1 &
