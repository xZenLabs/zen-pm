#!/bin/sh
# ZenPM self-update — checks latest GitHub release, validates SHA, installs if newer.
set -eu

APP_ID="com.zenlabs.zenpm"
TMPDIR="/mnt/us/ZPM-Update-Temp"
PAYLOAD_DIR="/mnt/us/ZenPM"
VERSION_FILE="$PAYLOAD_DIR/VERSION"
REPO="AnthonyGress/ZenPackageManager"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
ZIP_ASSET="zenpm-kindle.zip"

alert() {
    TITLE="$1"
    TEXT="$2"
    TITLE_ESC=$(printf '%s' "$TITLE" | sed 's/"/\\"/g')
    TEXT_ESC=$(printf '%s' "$TEXT" | sed 's/"/\\"/g')
    JSON='{ "clientParams":{ "alertId":"appAlert1", "show":true, "customStrings":[ { "matchStr":"alertTitle", "replaceStr":"'"$TITLE_ESC"'" }, { "matchStr":"alertText", "replaceStr":"'"$TEXT_ESC"'" } ] } }'
    lipc-set-prop com.lab126.pillow pillowAlert "$JSON"
}

# cleanup() only invoked via trap
# shellcheck disable=SC2317
cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

# semver_cmp a b — echoes -1 if a<b, 0 if a==b, 1 if a>b.
# Strips leading 'v' from both inputs.
semver_cmp() {
    _a=$(printf '%s' "$1" | sed 's/^v//')
    _b=$(printf '%s' "$2" | sed 's/^v//')
    _OFS="$IFS"
    IFS='.'
    # intentional word splitting on IFS='.'
    # shellcheck disable=SC2086
    set -- $_a; _a1=${1:-0}; _a2=${2:-0}; _a3=${3:-0}
    set -- $_b; _b1=${1:-0}; _b2=${2:-0}; _b3=${3:-0}
    IFS="$_OFS"
    if [ "$_a1" -gt "$_b1" ]; then echo 1; return; fi
    if [ "$_a1" -lt "$_b1" ]; then echo -1; return; fi
    if [ "$_a2" -gt "$_b2" ]; then echo 1; return; fi
    if [ "$_a2" -lt "$_b2" ]; then echo -1; return; fi
    if [ "$_a3" -gt "$_b3" ]; then echo 1; return; fi
    if [ "$_a3" -lt "$_b3" ]; then echo -1; return; fi
    echo 0
}

# --- Read current version ---
CURRENT_VERSION="0.0.0"
if [ -f "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(head -1 "$VERSION_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
fi
CURRENT_VERSION=$(printf '%s' "$CURRENT_VERSION" | sed 's/^v//')

alert "Checking for Updates..." "Current: v$CURRENT_VERSION"

# --- Fetch latest release info from GitHub API ---
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

API_JSON="$TMPDIR/release.json"
curl -fSL -o "$API_JSON" "$API_URL"

# Parse tag name (e.g. "v0.3.0" or "0.3.0").
LATEST_TAG=$(grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$API_JSON" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
if [ -z "$LATEST_TAG" ]; then
    alert "Update Failed!" "Could not determine latest version."
    exit 1
fi

LATEST_VERSION=$(printf '%s' "$LATEST_TAG" | sed 's/^v//')

# --- Version comparison ---
CMP=$(semver_cmp "$LATEST_VERSION" "$CURRENT_VERSION")
if [ "$CMP" -le 0 ]; then
    alert "ZenPM is up to date!" "You have v$CURRENT_VERSION.\nLatest is v$LATEST_VERSION."
    exit 0
fi

# --- Parse download URL, expected size, and SHA256 from release assets ---
# grep the asset block for zenpm-kindle.zip, then extract url, size, and sha256 digest.
ASSET_BLOCK=$(grep -A 50 '"name"[[:space:]]*:[[:space:]]*"'"$ZIP_ASSET"'"' "$API_JSON")
DOWNLOAD_URL=$(echo "$ASSET_BLOCK" | grep '"browser_download_url"' | head -1 | sed 's/.*"\(https:[^"]*\)".*/\1/')
EXPECTED_SIZE=$(echo "$ASSET_BLOCK" | grep '"size"' | head -1 | sed 's/[^0-9]//g')
# GitHub now exposes SHA256 digests directly in the release API (since 2025-06-03).
# The digest lives in "digests": { "sha256": "..." } within the asset object.
EXPECTED_SHA=$(echo "$ASSET_BLOCK" | sed -n '/"sha256"/{s/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q;}')

if [ -z "$DOWNLOAD_URL" ]; then
    alert "Update Failed!" "Could not find $ZIP_ASSET in release."
    exit 1
fi

alert "Updating ZenPM..." "Downloading v$LATEST_VERSION..."

# --- Download ---
curl -fSL -o "$TMPDIR/$ZIP_ASSET" "$DOWNLOAD_URL"

# --- Validate download ---
ACTUAL_SIZE=$(wc -c < "$TMPDIR/$ZIP_ASSET")
if [ "$ACTUAL_SIZE" -eq 0 ]; then
    alert "Update Failed!" "Downloaded file is empty."
    exit 1
fi

# Check size against GitHub metadata.
if [ -n "$EXPECTED_SIZE" ] && [ "$ACTUAL_SIZE" -ne "$EXPECTED_SIZE" ]; then
    alert "Update Failed!" "Download size mismatch.\nExpected: $EXPECTED_SIZE\nGot: $ACTUAL_SIZE"
    exit 1
fi

# Validate SHA256 digest from GitHub API.
if [ -n "$EXPECTED_SHA" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        ACTUAL_SHA=$(sha256sum "$TMPDIR/$ZIP_ASSET" | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        ACTUAL_SHA=$(openssl sha256 "$TMPDIR/$ZIP_ASSET" | awk '{print $NF}')
    else
        ACTUAL_SHA=""
    fi
    if [ -n "$ACTUAL_SHA" ] && [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
        alert "Update Failed!" "SHA256 mismatch.\nDownload may be corrupted."
        exit 1
    fi
fi

# --- Extract ---
unzip -q "$TMPDIR/$ZIP_ASSET" -d "$TMPDIR"

if [ ! -d "$TMPDIR/ZenPM" ]; then
    alert "Update Failed!" "Extracted payload missing ZenPM/ directory."
    exit 1
fi

alert "Updating ZenPM..." "Installing v$LATEST_VERSION..."

# Stop the daemon and WAF.
pkill -f 'zenpm serve' 2>/dev/null || true
lipc-set-prop com.lab126.appmgrd stop "app://$APP_ID" 2>/dev/null || true
pkill -f "mesquite.*$APP_ID" 2>/dev/null || true
sleep 2

# Replace payload (preserves /mnt/us/.ZenPM/ state).
rm -rf "$PAYLOAD_DIR"
cp -r "$TMPDIR/ZenPM" "$PAYLOAD_DIR"

# Select correct ABI binary.
if [ -f /lib/ld-linux-armhf.so.3 ]; then
    ABI=hf
else
    ABI=sf
fi
cp "$PAYLOAD_DIR/backend/zenpm-$ABI" "$PAYLOAD_DIR/backend/zenpm"
chmod +x "$PAYLOAD_DIR/backend/zenpm"

# Deploy updated WAF.
MESQUITE_TARGET="/var/local/mesquite/ZenPM"
rm -rf "$MESQUITE_TARGET"
mkdir -p "$MESQUITE_TARGET"
cp -R "$PAYLOAD_DIR/frontend/kindle"/. "$MESQUITE_TARGET"/

sync

# Re-register app in case command path changed.
APPREG_DB="/var/local/appreg.db"
sqlite3 "$APPREG_DB" <<EOF
INSERT OR IGNORE INTO interfaces(interface) VALUES('application');
INSERT OR IGNORE INTO handlerIds(handlerId) VALUES('$APP_ID');
INSERT OR REPLACE INTO properties(handlerId,name,value) VALUES('$APP_ID','command','/usr/bin/mesquite -l $APP_ID -c file://$MESQUITE_TARGET/');
EOF

sync

# Start daemon and WAF.
ZENPM_LOG="$PAYLOAD_DIR/ZenPM.log"
nohup "$PAYLOAD_DIR/backend/zenpm" serve --port 8080 >>"$ZENPM_LOG" 2>&1 &

sleep 2

# Go home briefly so the WAF restarts fresh, then foreground ZenPM.
lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home
sleep 2
killall mesquite || true
sleep 2

nohup lipc-set-prop com.lab126.appmgrd start "app://$APP_ID" >/dev/null 2>&1 &

alert "Update Complete!" "Updated to v$LATEST_VERSION!\nYou may now use ZenPM."

exit 0
