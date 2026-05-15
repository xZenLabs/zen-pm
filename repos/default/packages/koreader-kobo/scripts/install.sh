#!/bin/sh
set -eu

ONBOARD_DIR="/mnt/onboard"
ADDS_DIR="$ONBOARD_DIR/.adds"
NM_DIR="$ADDS_DIR/nm"
KO_DIR="$ADDS_DIR/koreader"
KO_PREV_DIR="$ADDS_DIR/koreader.previous"
TMP_DIR="$ADDS_DIR/zenpm/tmp/koreader-install"
KOBO_CONF="$ONBOARD_DIR/.kobo/Kobo/Kobo eReader.conf"

if [ ! -d "$ONBOARD_DIR" ]; then
    echo "Kobo storage /mnt/onboard not found"
    exit 1
fi

mkdir -p "$TMP_DIR" "$NM_DIR" "$ADDS_DIR/zenpm/tmp"

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

resolve_koreader_url() {
    api_url="https://api.github.com/repos/koreader/koreader/releases/latest"

    if command -v curl >/dev/null 2>&1; then
        url=$(curl -fsSL "$api_url" | grep -Eo 'https://[^\"]+koreader-kobo-[^\"]+\.zip' | head -n 1 || true)
    elif command -v wget >/dev/null 2>&1; then
        url=$(wget -qO- "$api_url" | grep -Eo 'https://[^\"]+koreader-kobo-[^\"]+\.zip' | head -n 1 || true)
    else
        url=""
    fi

    if [ -n "$url" ]; then
        printf '%s\n' "$url"
        return 0
    fi

    echo "Unable to resolve KOReader Kobo release URL"
    return 1
}

extract_zip() {
    archive="$1"
    destination="$2"

    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$archive" -d "$destination"
        return 0
    fi

    if command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$archive" -C "$destination"
        return 0
    fi

    echo "No zip extractor found (need unzip or bsdtar)"
    return 1
}

ensure_exclude_sync_folders() {
    conf_path="$1"
    needle='ExcludeSyncFolders=(\\.(?!kobo|adobe).+|([^.][^/]*/)+\\..+)'

    if [ ! -f "$conf_path" ]; then
        return 0
    fi

    if grep -Fq "$needle" "$conf_path"; then
        return 0
    fi

    tmp_conf="$TMP_DIR/Kobo eReader.conf"
    cp "$conf_path" "$tmp_conf"

    if grep -Fq "[FeatureSettings]" "$tmp_conf"; then
        awk -v line="$needle" '
            BEGIN { in_section = 0; inserted = 0 }
            {
                print $0
                if ($0 == "[FeatureSettings]") {
                    in_section = 1
                    next
                }
                if (in_section && $0 ~ /^\[/ && inserted == 0) {
                    print line
                    inserted = 1
                    in_section = 0
                }
            }
            END {
                if (in_section && inserted == 0) {
                    print line
                }
            }
        ' "$tmp_conf" > "$tmp_conf.new"
        mv "$tmp_conf.new" "$tmp_conf"
    else
        printf '\n[FeatureSettings]\n%s\n' "$needle" >> "$tmp_conf"
    fi

    cp "$tmp_conf" "$conf_path"
}

KO_URL=$(resolve_koreader_url)
KO_ARCHIVE="$TMP_DIR/koreader-kobo.zip"

download_file "$KO_URL" "$KO_ARCHIVE"
extract_zip "$KO_ARCHIVE" "$TMP_DIR"

if [ ! -d "$TMP_DIR/koreader" ]; then
    echo "Archive did not contain a koreader directory"
    exit 1
fi

rm -rf "$KO_PREV_DIR"
if [ -d "$KO_DIR" ]; then
    mv "$KO_DIR" "$KO_PREV_DIR"
fi

mv "$TMP_DIR/koreader" "$KO_DIR"
chmod +x "$KO_DIR/koreader.sh"

cat > "$NM_DIR/zenpm-koreader" <<'EOF'
menu_item:main:KOReader:cmd_spawn:quiet:exec /mnt/onboard/.adds/koreader/koreader.sh
EOF

ensure_exclude_sync_folders "$KOBO_CONF"

rm -rf "$TMP_DIR"
sync

echo "KOReader installed to $KO_DIR"
echo "NickelMenu entry created at $NM_DIR/zenpm-koreader"
