#!/bin/sh
set -eu

ONBOARD_DIR="/mnt/onboard"
KOBO_DIR="$ONBOARD_DIR/.kobo"
NM_DIR="$ONBOARD_DIR/.adds/nm"
DOWNLOAD_URL="https://github.com/pgaskin/NickelMenu/releases/latest/download/KoboRoot.tgz"
TARGET_TGZ="$KOBO_DIR/KoboRoot.tgz"

if [ ! -d "$ONBOARD_DIR" ] || [ ! -d "$KOBO_DIR" ]; then
    echo "Kobo storage paths not found"
    exit 1
fi

mkdir -p "$NM_DIR"

download_file() {
    url="$1"
    output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$output"
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -qO "$output" "$url"
        return 0
    fi

    echo "Neither curl nor wget is available"
    return 1
}

if [ -f "$TARGET_TGZ" ]; then
    cp "$TARGET_TGZ" "$TARGET_TGZ.zenpm.bak"
fi

download_file "$DOWNLOAD_URL" "$TARGET_TGZ"
sync

cat > "$NM_DIR/zenpm-nickelmenu-installed" <<'EOF'
NickelMenu package staged by Zen Package Manager.
KoboRoot.tgz has been copied to .kobo.
Eject and unplug your Kobo so firmware applies the update.
EOF

echo "NickelMenu install package copied to $TARGET_TGZ"
echo "Eject and unplug the Kobo to complete installation"
