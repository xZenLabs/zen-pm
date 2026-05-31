#!/bin/sh
set -eu

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT_DIR="$SCRIPT_DIR"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$DIST_DIR/.build"
VERSION_FILE="$ROOT_DIR/VERSION"

usage() {
    echo "Usage: $0"
    echo "Version is read from $VERSION_FILE"
    exit 1
}

read_version_file() {
    if [ ! -f "$VERSION_FILE" ]; then
        echo "Missing version file: $VERSION_FILE"
        echo "Create it with a SemVer value like 0.1.0"
        exit 1
    fi

    value=$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$VERSION_FILE")
    if [ -z "$value" ]; then
        echo "Version file is empty: $VERSION_FILE"
        exit 1
    fi

    printf '%s\n' "$value"
}

normalize_version() {
    raw="$1"
    case "$raw" in
        v*) printf '%s\n' "${raw#v}" ;;
        *) printf '%s\n' "$raw" ;;
    esac
}

validate_semver() {
    candidate="$1"
    printf '%s\n' "$candidate" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
}

[ "$#" -eq 0 ] || usage

VERSION=$(normalize_version "$(read_version_file)")
if ! validate_semver "$VERSION"; then
    echo "Invalid SemVer version in $VERSION_FILE: $VERSION"
    echo "Expected format: MAJOR.MINOR.PATCH (optionally with -prerelease and/or +build metadata)"
    exit 1
fi

KINDLE_STAGE="$BUILD_DIR/kindle"
KOBO_STAGE="$BUILD_DIR/kobo"

copy_tree() {
    src="$1"
    dst="$2"
    mkdir -p "$dst"
    cp -R "$src" "$dst"
}

ensure_exec() {
    target="$1"
    if [ -d "$target" ]; then
        find "$target" -type f \( -name '*.sh' -o -name 'zenpm' -o -name 'zenpm-hf' -o -name 'zenpm-sf' \) -exec chmod +x {} +
    fi
}

cleanup_stage() {
    rm -rf "$BUILD_DIR"
}

build_go() {
    echo "Building Go backend..."
    LDFLAGS="-X main.version=$VERSION"
    GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -ldflags "$LDFLAGS" -o "$BUILD_DIR/zenpm-hf" ./cmd/zenpm
    GOOS=linux GOARCH=arm GOARM=5 CGO_ENABLED=0 go build -ldflags "$LDFLAGS" -o "$BUILD_DIR/zenpm-sf" ./cmd/zenpm
    echo "Go binaries: zenpm-hf (ARMhf) zenpm-sf (ARMsf)"
}

trap cleanup_stage EXIT INT TERM

rm -rf "$DIST_DIR"
mkdir -p "$KINDLE_STAGE" "$KOBO_STAGE" "$DIST_DIR"

build_go

# Payload staged at ZenPM/ (zip root) so it extracts to /mnt/us/ZenPM/ — the final install
# location. Shell scripts outside documents/ are never indexed as Kindle books.
# Only one .sh file lives in documents/ (the scriptlet the user taps to install).
mkdir -p "$KINDLE_STAGE/documents" "$KINDLE_STAGE/ZenPM/backend"
cp "$BUILD_DIR/zenpm-hf" "$KINDLE_STAGE/ZenPM/backend/zenpm-hf"
cp "$BUILD_DIR/zenpm-sf" "$KINDLE_STAGE/ZenPM/backend/zenpm-sf"
copy_tree "$ROOT_DIR/frontend" "$KINDLE_STAGE/ZenPM"
copy_tree "$ROOT_DIR/installers" "$KINDLE_STAGE/ZenPM"
cp "$ROOT_DIR/installers/kindle/ZenPM.sh" "$KINDLE_STAGE/documents/ZenPM.sh"

# Inject version into asset URLs so WebKit cache is busted on each release.
_waf_html="$KINDLE_STAGE/ZenPM/frontend/kindle/index.html"
sed "s/script\.js\"/script.js?v=$VERSION\"/g; s/style\.css\"/style.css?v=$VERSION\"/g" \
    "$_waf_html" > "$_waf_html.tmp" && mv "$_waf_html.tmp" "$_waf_html"

ensure_exec "$KINDLE_STAGE/ZenPM"
ensure_exec "$KINDLE_STAGE/documents"

# Kobo package layout: unzip to Kobo root, then run .adds/ZenPM/installers/kobo/ZenPM.sh
mkdir -p "$KOBO_STAGE/.adds/ZenPM/backend"
cp "$BUILD_DIR/zenpm-hf" "$KOBO_STAGE/.adds/ZenPM/backend/zenpm-hf"
cp "$BUILD_DIR/zenpm-sf" "$KOBO_STAGE/.adds/ZenPM/backend/zenpm-sf"
copy_tree "$ROOT_DIR/docs" "$KOBO_STAGE/.adds/ZenPM"
copy_tree "$ROOT_DIR/installers" "$KOBO_STAGE/.adds/ZenPM"

ensure_exec "$KOBO_STAGE/.adds/ZenPM"

KINDLE_ZIP="$DIST_DIR/ZenPM-kindle-$VERSION.zip"
KOBO_ZIP="$DIST_DIR/ZenPM-kobo-$VERSION.zip"

(
    cd "$KINDLE_STAGE"
    zip -qr "$KINDLE_ZIP" documents ZenPM
)

(
    cd "$KOBO_STAGE"
    zip -qr "$KOBO_ZIP" .adds
)

echo "Build complete"
echo "Version:          $VERSION"
echo "Kindle package: $KINDLE_ZIP"
echo "Kobo package:   $KOBO_ZIP"

# Bump patch for the next build.
_major=$(printf '%s' "$VERSION" | cut -d. -f1)
_minor=$(printf '%s' "$VERSION" | cut -d. -f2)
_patch=$(printf '%s' "$VERSION" | cut -d. -f3)
NEXT_VERSION="$_major.$_minor.$((_patch + 1))"
printf '%s\n' "$NEXT_VERSION" > "$VERSION_FILE"
echo "Next version:     $NEXT_VERSION (VERSION bumped)"
