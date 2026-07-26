#!/bin/sh
# ZenPM self-update. This runs outside the daemon that it replaces.
set -eu

TMPDIR="/mnt/us/ZPM-Update-Temp"
PAYLOAD_DIR="/mnt/us/ZenPM"
VERSION_FILE="$PAYLOAD_DIR/VERSION"
REPO="xZenLabs/zen-pm"
API_URL="https://api.github.com/repos/$REPO/releases?per_page=30"

allow_beta=false
if [ "${1:-}" = "--beta" ]; then
    allow_beta=true
fi

alert() {
    title="$1"
    text="$2"
    title=$(printf '%s' "$title" | sed 's/"/\\"/g')
    text=$(printf '%s' "$text" | sed 's/"/\\"/g')
    json='{ "clientParams":{ "alertId":"appAlert1", "show":true, "customStrings":[ { "matchStr":"alertTitle", "replaceStr":"'"$title"'" }, { "matchStr":"alertText", "replaceStr":"'"$text"'" } ] } }'
    lipc-set-prop com.lab126.pillow pillowAlert "$json"
}

if [ -d /mnt/us/kmc/kpm ]; then
    alert "Update Failed!" "Kindle standalone is incompatible with KPM."
    exit 1
fi

cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

semver_cmp() {
    a=$(printf '%s' "$1" | sed 's/^v//')
    b=$(printf '%s' "$2" | sed 's/^v//')
    a_main=${a%%-*}; b_main=${b%%-*}
    case "$a" in *-*) a_pre=${a#*-} ;; *) a_pre="" ;; esac
    case "$b" in *-*) b_pre=${b#*-} ;; *) b_pre="" ;; esac
    old_ifs="$IFS"
    IFS='.'
    # shellcheck disable=SC2086
    set -- $a_main; a1=${1:-0}; a2=${2:-0}; a3=${3:-0}
    # shellcheck disable=SC2086
    set -- $b_main; b1=${1:-0}; b2=${2:-0}; b3=${3:-0}
    IFS="$old_ifs"
    if [ "$a1" -gt "$b1" ]; then echo 1; return; fi
    if [ "$a1" -lt "$b1" ]; then echo -1; return; fi
    if [ "$a2" -gt "$b2" ]; then echo 1; return; fi
    if [ "$a2" -lt "$b2" ]; then echo -1; return; fi
    if [ "$a3" -gt "$b3" ]; then echo 1; return; fi
    if [ "$a3" -lt "$b3" ]; then echo -1; return; fi
    if [ -z "$a_pre" ] && [ -n "$b_pre" ]; then echo 1; return; fi
    if [ -n "$a_pre" ] && [ -z "$b_pre" ]; then echo -1; return; fi
    a_pre_num=$(printf '%s' "$a_pre" | sed 's/[^0-9]//g')
    b_pre_num=$(printf '%s' "$b_pre" | sed 's/[^0-9]//g')
    a_pre_num=${a_pre_num:-0}; b_pre_num=${b_pre_num:-0}
    if [ "$a_pre_num" -gt "$b_pre_num" ]; then echo 1; return; fi
    if [ "$a_pre_num" -lt "$b_pre_num" ]; then echo -1; return; fi
    echo 0
}

current_version="0.0.0"
if [ -f "$VERSION_FILE" ]; then
    current_version=$(head -1 "$VERSION_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
fi
current_version=$(printf '%s' "$current_version" | sed 's/^v//')
alert "Checking for Updates..." "Current: v$current_version"

rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"
api_json="$TMPDIR/release.json"
if [ "$allow_beta" = true ]; then
    curl -fSL -o "$api_json" "$API_URL"
else
    curl -fSL -o "$api_json" "https://api.github.com/repos/$REPO/releases/latest"
fi

latest_tag=""
if [ "$allow_beta" = true ]; then
    tags_file="$TMPDIR/tags"
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$api_json" > "$tags_file"
    while IFS= read -r tag; do
        version=$(printf '%s' "$tag" | sed 's/^v//')
        asset="ZenPM-kindle-standalone-$version.zip"
        if grep -q '"name"[[:space:]]*:[[:space:]]*"'"$asset"'"' "$api_json"; then
            latest_tag="$tag"
            break
        fi
    done < "$tags_file"
else
    latest_tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$api_json" | head -1)
fi
if [ -z "$latest_tag" ]; then
    alert "Update Failed!" "Could not find a Kindle standalone release."
    exit 1
fi
latest_version=$(printf '%s' "$latest_tag" | sed 's/^v//')
zip_asset="ZenPM-kindle-standalone-$latest_version.zip"

if [ "$(semver_cmp "$latest_version" "$current_version")" -le 0 ]; then
    alert "ZenPM is up to date!" "You have v$current_version.\nLatest is v$latest_version."
    exit 0
fi

asset_block=$(grep -A 50 '"name"[[:space:]]*:[[:space:]]*"'"$zip_asset"'"' "$api_json")
download_url=$(printf '%s\n' "$asset_block" | grep '"browser_download_url"' | head -1 | sed 's/.*"\(https:[^"]*\)".*/\1/')
expected_size=$(printf '%s\n' "$asset_block" | grep '"size"' | head -1 | sed 's/[^0-9]//g')
expected_sha=$(printf '%s\n' "$asset_block" | sed -n '/"sha256"/{s/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q;}')
if [ -z "$download_url" ]; then
    alert "Update Failed!" "Could not find $zip_asset in release."
    exit 1
fi

alert "Updating ZenPM..." "Downloading v$latest_version..."
archive="$TMPDIR/$zip_asset"
curl -fSL -o "$archive" "$download_url"
actual_size=$(wc -c < "$archive")
if [ "$actual_size" -eq 0 ] || { [ -n "$expected_size" ] && [ "$actual_size" -ne "$expected_size" ]; }; then
    alert "Update Failed!" "Downloaded file failed its size check."
    exit 1
fi
if [ -n "$expected_sha" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        actual_sha=$(sha256sum "$archive" | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        actual_sha=$(openssl sha256 "$archive" | awk '{print $NF}')
    else
        actual_sha=""
    fi
    if [ -n "$actual_sha" ] && [ "$actual_sha" != "$expected_sha" ]; then
        alert "Update Failed!" "SHA256 mismatch. Download may be corrupted."
        exit 1
    fi
fi

unzip -q "$archive" -d "$TMPDIR"
if [ ! -d "$TMPDIR/ZenPM" ]; then
    alert "Update Failed!" "Extracted payload missing ZenPM/ directory."
    exit 1
fi

alert "Updating ZenPM..." "Installing v$latest_version..."
new_payload="$TMPDIR/ZenPM"
if [ -f /lib/ld-linux-armhf.so.3 ]; then ABI=hf; else ABI=sf; fi
[ -f "$new_payload/backend/zenpm-$ABI" ] || {
    alert "Update Failed!" "Binary missing: zenpm-$ABI"
    exit 1
}
cp "$new_payload/backend/zenpm-$ABI" "$new_payload/backend/zenpm"
chmod +x "$new_payload/backend/zenpm"
mkdir -p "$new_payload/bin"
for cli_name in zenpm zpm; do
    cat > "$new_payload/bin/$cli_name" <<EOF
#!/bin/sh
export ZENPM_PLATFORM=kindle
exec "$PAYLOAD_DIR/backend/zenpm" "\$@"
EOF
    chmod +x "$new_payload/bin/$cli_name"
done

mesquite_target="/var/local/mesquite/ZenPM"
cp -R "$new_payload/frontend/kindle"/. "$mesquite_target"/

pkill -f 'zenpm serve' 2>/dev/null || true
sleep 2
mv "$PAYLOAD_DIR" "$TMPDIR/ZenPM.previous"
mv "$new_payload" "$PAYLOAD_DIR"
sync
nohup "$PAYLOAD_DIR/backend/zenpm" serve --port 8080 >>"$PAYLOAD_DIR/ZenPM.log" 2>&1 &
sleep 2
alert "Update Complete!" "Updated to v$latest_version!\nExit and reopen ZenPM to load the new interface."
