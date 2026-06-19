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
KOREADER_PLUGIN_BASE_STAGE="$BUILD_DIR/koreader-plugin-base"
KOREADER_EREADER_STAGE="$BUILD_DIR/koreader-ereader"
KOREADER_MACOS_STAGE="$BUILD_DIR/koreader-macos"
KOREADER_LINUX_STAGE="$BUILD_DIR/koreader-linux"

copy_tree() {
    src="$1"
    dst="$2"
    mkdir -p "$dst"
    cp -R "$src" "$dst"
}

ensure_exec() {
    target="$1"
    if [ -d "$target" ]; then
        find "$target" -type f \( -name '*.sh' -o -name 'zenpm' -o -name 'zenpm-hf' -o -name 'zenpm-sf' -o -name 'zenpm-ereader' -o -name 'zenpm-linux' -o -name 'zenpm-linux-arm64' -o -name 'zenpm-linux-amd64' -o -name 'zenpm-darwin' -o -name 'zenpm-darwin-arm64' -o -name 'zenpm-darwin-amd64' \) -exec chmod +x {} +
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
    GOOS=linux GOARCH=arm GOARM=5 CGO_ENABLED=0 go build -ldflags "$LDFLAGS" -o "$BUILD_DIR/zenpm-ereader" ./cmd/zenpm
    GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "$LDFLAGS" -o "$BUILD_DIR/zenpm-linux-arm64" ./cmd/zenpm
    GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "$LDFLAGS" -o "$BUILD_DIR/zenpm-linux-amd64" ./cmd/zenpm
    GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "$LDFLAGS" -o "$BUILD_DIR/zenpm-darwin-arm64" ./cmd/zenpm
    GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "$LDFLAGS" -o "$BUILD_DIR/zenpm-darwin-amd64" ./cmd/zenpm
    command -v lipo >/dev/null 2>&1 || {
        echo "lipo not found; required to build the macOS universal KOReader backend"
        exit 1
    }
    lipo -create -output "$BUILD_DIR/zenpm-darwin" "$BUILD_DIR/zenpm-darwin-amd64" "$BUILD_DIR/zenpm-darwin-arm64"
    cat > "$BUILD_DIR/zenpm-linux" <<'EOF'
#!/bin/sh
set -eu

DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MACHINE=$(uname -m 2>/dev/null || echo unknown)

case "$MACHINE" in
    x86_64|amd64)
        exec "$DIR/zenpm-linux-amd64" "$@"
        ;;
    arm64|aarch64)
        exec "$DIR/zenpm-linux-arm64" "$@"
        ;;
    *)
        echo "Unsupported Linux architecture: $MACHINE" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$BUILD_DIR/zenpm-linux"
    echo "Go binaries: zenpm-hf (ARMhf) zenpm-sf (ARMsf) zenpm-ereader zenpm-linux zenpm-linux-arm64 zenpm-linux-amd64 zenpm-darwin"
}

trap cleanup_stage EXIT INT TERM

rm -rf "$DIST_DIR"
mkdir -p "$KINDLE_STAGE" "$KOBO_STAGE" "$KOREADER_PLUGIN_BASE_STAGE" "$DIST_DIR"

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
# Process all HTML files under the pages/ directory.
find "$KINDLE_STAGE/ZenPM/frontend/kindle/pages" -name '*.html' | while IFS= read -r f; do
    sed -E \
        -e "s/(polyfill\.js)\"/\1?v=$VERSION\"/g" \
        -e "s/(utils\.js)\"/\1?v=$VERSION\"/g" \
        -e "s/(style\.css)\"/\1?v=$VERSION\"/g" \
        -e "s/(script\.js)\"/\1?v=$VERSION\"/g" \
        -e "s/(sources\.js)\"/\1?v=$VERSION\"/g" \
        -e "s/(installed\.js)\"/\1?v=$VERSION\"/g" \
        -e "s/(log\.js)\"/\1?v=$VERSION\"/g" \
        "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

ensure_exec "$KINDLE_STAGE/ZenPM"
ensure_exec "$KINDLE_STAGE/documents"

# Kobo package layout: unzip to Kobo root, then run .adds/ZenPM/installers/kobo/ZenPM.sh
mkdir -p "$KOBO_STAGE/.adds/ZenPM/backend"
cp "$BUILD_DIR/zenpm-hf" "$KOBO_STAGE/.adds/ZenPM/backend/zenpm-hf"
cp "$BUILD_DIR/zenpm-sf" "$KOBO_STAGE/.adds/ZenPM/backend/zenpm-sf"
copy_tree "$ROOT_DIR/docs" "$KOBO_STAGE/.adds/ZenPM"
copy_tree "$ROOT_DIR/installers" "$KOBO_STAGE/.adds/ZenPM"

ensure_exec "$KOBO_STAGE/.adds/ZenPM"

copy_tree "$ROOT_DIR/frontend/koreader/zenpm.koplugin" "$KOREADER_PLUGIN_BASE_STAGE"
cp "$ROOT_DIR/VERSION" "$KOREADER_PLUGIN_BASE_STAGE/zenpm.koplugin/VERSION"
sed -E "s/version = \"[^\"]*\"/version = \"$VERSION\"/" "$KOREADER_PLUGIN_BASE_STAGE/zenpm.koplugin/_meta.lua" > "$KOREADER_PLUGIN_BASE_STAGE/zenpm.koplugin/_meta.lua.tmp" && mv "$KOREADER_PLUGIN_BASE_STAGE/zenpm.koplugin/_meta.lua.tmp" "$KOREADER_PLUGIN_BASE_STAGE/zenpm.koplugin/_meta.lua"

stage_koreader_plugin() {
    stage="$1"
    rm -rf "$stage"
    mkdir -p "$stage"
    cp -R "$KOREADER_PLUGIN_BASE_STAGE/zenpm.koplugin" "$stage/"
    rm -rf "$stage/zenpm.koplugin/backend"
    mkdir -p "$stage/zenpm.koplugin/backend"
    cp "$ROOT_DIR/VERSION" "$stage/zenpm.koplugin/backend/VERSION"
}

stage_koreader_plugin "$KOREADER_EREADER_STAGE"
cp "$BUILD_DIR/zenpm-ereader" "$KOREADER_EREADER_STAGE/zenpm.koplugin/backend/zenpm-ereader"
ensure_exec "$KOREADER_EREADER_STAGE/zenpm.koplugin"

stage_koreader_plugin "$KOREADER_MACOS_STAGE"
cp "$BUILD_DIR/zenpm-darwin" "$KOREADER_MACOS_STAGE/zenpm.koplugin/backend/zenpm-darwin"
ensure_exec "$KOREADER_MACOS_STAGE/zenpm.koplugin"

stage_koreader_plugin "$KOREADER_LINUX_STAGE"
cp "$BUILD_DIR/zenpm-linux" "$KOREADER_LINUX_STAGE/zenpm.koplugin/backend/zenpm-linux"
cp "$BUILD_DIR/zenpm-linux-arm64" "$KOREADER_LINUX_STAGE/zenpm.koplugin/backend/zenpm-linux-arm64"
cp "$BUILD_DIR/zenpm-linux-amd64" "$KOREADER_LINUX_STAGE/zenpm.koplugin/backend/zenpm-linux-amd64"
ensure_exec "$KOREADER_LINUX_STAGE/zenpm.koplugin"

KINDLE_ZIP="$DIST_DIR/ZenPM-kindle-$VERSION.zip"
KOBO_ZIP="$DIST_DIR/ZenPM-kobo-$VERSION.zip"
KOREADER_EREADER_ZIP="$DIST_DIR/ZenPM-koreader-ereader-$VERSION.zip"
KOREADER_MACOS_ZIP="$DIST_DIR/ZenPM-koreader-macos-$VERSION.zip"
KOREADER_LINUX_ZIP="$DIST_DIR/ZenPM-koreader-linux-$VERSION.zip"

(
    cd "$KINDLE_STAGE"
    zip -qr "$KINDLE_ZIP" documents ZenPM
)

(
    cd "$KOBO_STAGE"
    zip -qr "$KOBO_ZIP" .adds
)

(
    cd "$KOREADER_EREADER_STAGE"
    zip -qr "$KOREADER_EREADER_ZIP" zenpm.koplugin
)

(
    cd "$KOREADER_MACOS_STAGE"
    zip -qr "$KOREADER_MACOS_ZIP" zenpm.koplugin
)

(
    cd "$KOREADER_LINUX_STAGE"
    zip -qr "$KOREADER_LINUX_ZIP" zenpm.koplugin
)

echo "Build complete"
echo "Version:          $VERSION"
echo "Kindle package: $KINDLE_ZIP"
echo "Kobo package:   $KOBO_ZIP"
echo "KOReader e-reader plugin: $KOREADER_EREADER_ZIP"
echo "KOReader macOS plugin:    $KOREADER_MACOS_ZIP"
echo "KOReader Linux plugin:    $KOREADER_LINUX_ZIP"

# Bump patch for the next build.
_major=$(printf '%s' "$VERSION" | cut -d. -f1)
_minor=$(printf '%s' "$VERSION" | cut -d. -f2)
_patch=$(printf '%s' "$VERSION" | cut -d. -f3)
NEXT_VERSION="$_major.$_minor.$((_patch + 1))"
printf '%s\n' "$NEXT_VERSION" > "$VERSION_FILE"
echo "Next version:     $NEXT_VERSION (VERSION bumped)"
