#!/bin/sh
set -eu

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT_DIR="$SCRIPT_DIR"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$DIST_DIR/.build"
VERSION_FILE="$ROOT_DIR/VERSION"
KOREADER_META_FILE="$ROOT_DIR/frontend/koreader/zenpm.koplugin/_meta.lua"
DEV_MODE=false
DEV_PID_FILE="$ROOT_DIR/.dev-kodev.pid"

usage() {
    echo "Usage: $0 [--dev]"
    echo "Without --dev, version is read from $VERSION_FILE"
    exit 1
}

case "$#" in
    0)
        ;;
    1)
        if [ "$1" = "--dev" ]; then
            DEV_MODE=true
        else
            usage
        fi
        ;;
    *)
        usage
        ;;
esac

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

next_version() {
    version="$1"
    case "$version" in
        *-beta)
            printf '%s1\n' "$version"
            return
            ;;
    esac

    beta_number=$(printf '%s\n' "$version" | sed -n 's/.*-beta\([0-9][0-9]*\)$/\1/p')
    if [ -n "$beta_number" ]; then
        printf '%s-beta%s\n' "${version%-beta*}" "$((beta_number + 1))"
        return
    fi

    major=$(printf '%s' "$version" | cut -d. -f1)
    minor=$(printf '%s' "$version" | cut -d. -f2)
    patch=$(printf '%s' "$version" | cut -d. -f3)
    printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))"
}

run_dev() {
    ENV_FILE="$ROOT_DIR/.env"
    if [ ! -f "$ENV_FILE" ]; then
        echo "Missing development configuration: $ENV_FILE"
        exit 1
    fi

    # shellcheck disable=SC1090
    . "$ENV_FILE"
    if [ -z "${KOREADER_DIR:-}" ] || [ ! -d "$KOREADER_DIR" ]; then
        echo "KOREADER_DIR must point to a KOReader checkout"
        exit 1
    fi
    if [ ! -x "$KOREADER_DIR/kodev" ]; then
        echo "KOReader development command not found: $KOREADER_DIR/kodev"
        exit 1
    fi
    if ! command -v rsync >/dev/null 2>&1; then
        echo "rsync is required for development builds"
        exit 1
    fi
    if ! command -v lipo >/dev/null 2>&1; then
        echo "lipo is required to build the macOS universal backend"
        exit 1
    fi

    VERSION=$(normalize_version "$(read_version_file)")
    if ! validate_semver "$VERSION"; then
        echo "Invalid SemVer version in $VERSION_FILE: $VERSION"
        exit 1
    fi

    DEV_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zenpm-dev.XXXXXX")
    trap 'rm -rf "$DEV_BUILD_DIR"' EXIT INT TERM

    echo "Building macOS backend..."
    GOFLAGS="-trimpath -buildvcs=false"
    LDFLAGS="-s -w -buildid= -X main.version=$VERSION"
    GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 GOFLAGS="$GOFLAGS" go build -ldflags "$LDFLAGS" -o "$DEV_BUILD_DIR/zenpm-darwin-arm64" ./cmd/zenpm
    GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 GOFLAGS="$GOFLAGS" go build -ldflags "$LDFLAGS" -o "$DEV_BUILD_DIR/zenpm-darwin-amd64" ./cmd/zenpm
    lipo -create -output "$DEV_BUILD_DIR/zenpm-darwin" "$DEV_BUILD_DIR/zenpm-darwin-amd64" "$DEV_BUILD_DIR/zenpm-darwin-arm64"

    DEV_PLUGIN_DIR="$KOREADER_DIR/plugins/zenpm.koplugin"
    mkdir -p "$DEV_PLUGIN_DIR"
    rsync -a --delete --exclude 'backend/' --exclude 'VERSION' "$ROOT_DIR/frontend/koreader/zenpm.koplugin/" "$DEV_PLUGIN_DIR/"
    rm -rf "$DEV_PLUGIN_DIR/backend"
    mkdir -p "$DEV_PLUGIN_DIR/backend"
    cp "$VERSION_FILE" "$DEV_PLUGIN_DIR/VERSION"
    cp "$VERSION_FILE" "$DEV_PLUGIN_DIR/backend/VERSION"
    cp "$DEV_BUILD_DIR/zenpm-darwin" "$DEV_PLUGIN_DIR/backend/zenpm-darwin"
    chmod +x "$DEV_PLUGIN_DIR/backend/zenpm-darwin"
    echo "Deployed plugin to: $DEV_PLUGIN_DIR"

    find_luajit_child() {
        parent_pid="$1"
        for child_pid in $(pgrep -P "$parent_pid" 2>/dev/null || true); do
            command=$(ps -p "$child_pid" -o comm= 2>/dev/null || true)
            if [ "${command#*luajit}" != "$command" ]; then
                printf '%s\n' "$child_pid"
                return
            fi
            result=$(find_luajit_child "$child_pid")
            if [ -n "$result" ]; then
                printf '%s\n' "$result"
                return
            fi
        done
    }

    focus_koreader() {
        kodev_pid="$1"
        [ "$(uname)" = "Darwin" ] || return

        attempt=1
        while [ "$attempt" -le 120 ]; do
            reader_pid=$(find_luajit_child "$kodev_pid")
            if [ -n "$reader_pid" ]; then
                osascript \
                    -e "tell application \"System Events\"" \
                    -e "tell (first process whose unix id is $reader_pid)" \
                    -e 'if not (exists window 1) then error "KOReader window not ready"' \
                    -e 'set visible to true' \
                    -e 'set frontmost to true' \
                    -e 'perform action "AXRaise" of window 1' \
                    -e 'end tell' \
                    -e 'end tell' \
                    >/dev/null 2>&1 && return
            fi
            attempt=$((attempt + 1))
            sleep 0.5
        done
    }

    terminate_process_tree() {
        parent_pid="$1"
        for child_pid in $(pgrep -P "$parent_pid" 2>/dev/null || true); do
            terminate_process_tree "$child_pid"
        done
        kill "$parent_pid" 2>/dev/null || true
    }

    if [ -f "$DEV_PID_FILE" ]; then
        kodev_pid=$(cat "$DEV_PID_FILE")
        case "$kodev_pid" in
            ''|*[!0-9]*)
                ;;
            *)
                if kill -0 "$kodev_pid" 2>/dev/null; then
                    terminate_process_tree "$kodev_pid"
                fi
                ;;
        esac
    fi

    (
        cd "$KOREADER_DIR"
        nohup "$KOREADER_DIR/kodev" run >/dev/null 2>&1 &
        kodev_pid=$!
        printf '%s\n' "$kodev_pid" > "$DEV_PID_FILE"
        focus_koreader "$kodev_pid" &
    )
    echo "Restarted KOReader development build"
}

if [ "$DEV_MODE" = true ]; then
    run_dev
    exit 0
fi

VERSION=$(normalize_version "$(read_version_file)")
if ! validate_semver "$VERSION"; then
    echo "Invalid SemVer version in $VERSION_FILE: $VERSION"
    echo "Expected format: MAJOR.MINOR.PATCH (optionally with -prerelease and/or +build metadata)"
    exit 1
fi

KINDLE_STAGE="$BUILD_DIR/kindle-standalone"
# Kobo packages are not available yet; keep their paths ready for when they are enabled.
# shellcheck disable=SC2034
KOBO_HF_STAGE="$BUILD_DIR/kobo-hf"
# shellcheck disable=SC2034
KOBO_SF_STAGE="$BUILD_DIR/kobo-sf"
KOREADER_PLUGIN_BASE_STAGE="$BUILD_DIR/koreader-plugin-base"
KOREADER_EREADER_STAGE="$BUILD_DIR/koreader-ereader"
KOREADER_EREADER_ARM64_STAGE="$BUILD_DIR/koreader-ereader-arm64"
KOREADER_ANDROID_STAGE="$BUILD_DIR/koreader-android"
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
        find "$target" -type f \( -name '*.sh' -o -name 'zenpm' -o -name 'zenpm-hf' -o -name 'zenpm-sf' -o -name 'zenpm-arm64' -o -name 'zenpm-linux' -o -name 'zenpm-linux-arm64' -o -name 'zenpm-linux-amd64' -o -name 'zenpm-darwin' -o -name 'zenpm-darwin-arm64' -o -name 'zenpm-darwin-amd64' \) -exec chmod +x {} +
    fi
}

set_koreader_meta_version() {
    meta_file="$1"
    version="$2"
    sed -E "s/version = \"[^\"]*\"/version = \"$version\"/" "$meta_file" > "$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
}

cleanup_stage() {
    rm -rf "$BUILD_DIR"
}

build_go() {
    echo "Building Go backend..."
    GOFLAGS="-trimpath -buildvcs=false"
    LDFLAGS="-s -w -buildid= -X main.version=$VERSION"
    # Older e-readers need legacy Go runtimes. Go 1.19 retains the epoll_wait
    # syscall required by Kindle PW1 firmware.
    GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 GOFLAGS="$GOFLAGS" GOTOOLCHAIN=go1.20.14 go build -ldflags "$LDFLAGS" -o "$BUILD_DIR/zenpm-hf" ./cmd/zenpm
    GOOS=linux GOARCH=arm GOARM=5 CGO_ENABLED=0 GOFLAGS="$GOFLAGS" GOTOOLCHAIN=go1.19.13 go build -ldflags "$LDFLAGS" -o "$BUILD_DIR/zenpm-sf" ./cmd/zenpm
    GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOFLAGS="$GOFLAGS" go build -ldflags "$LDFLAGS" -o "$BUILD_DIR/zenpm-linux-arm64" ./cmd/zenpm
    GOOS=linux GOARCH=amd64 CGO_ENABLED=0 GOFLAGS="$GOFLAGS" go build -ldflags "$LDFLAGS" -o "$BUILD_DIR/zenpm-linux-amd64" ./cmd/zenpm
    GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 GOFLAGS="$GOFLAGS" go build -ldflags "$LDFLAGS" -o "$BUILD_DIR/zenpm-darwin-arm64" ./cmd/zenpm
    GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 GOFLAGS="$GOFLAGS" go build -ldflags "$LDFLAGS" -o "$BUILD_DIR/zenpm-darwin-amd64" ./cmd/zenpm
    if command -v upx >/dev/null 2>&1; then
        # ARMsf is not compressed for compatibility.
        echo "Packing Linux and ARM Go binaries with UPX..."
        upx --best --lzma \
            "$BUILD_DIR/zenpm-hf" \
            "$BUILD_DIR/zenpm-linux-arm64" \
            "$BUILD_DIR/zenpm-linux-amd64"
    else
        echo "upx not found; skipping UPX packing"
    fi
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
    echo "Go binaries: zenpm-hf (ARMhf) zenpm-sf (ARMsf) zenpm-linux zenpm-linux-arm64 zenpm-linux-amd64 zenpm-darwin"
}

trap cleanup_stage EXIT INT TERM

rm -rf "$DIST_DIR"
mkdir -p "$KOREADER_PLUGIN_BASE_STAGE" "$DIST_DIR"

build_go

stage_kindle() {
    stage="$1"
    # Payload staged at ZenPM/ (zip root) so it extracts to /mnt/us/ZenPM/ — the final install
    # location. Shell scripts outside documents/ are never indexed as Kindle books.
    mkdir -p "$stage/documents" "$stage/ZenPM/backend"
    cp "$BUILD_DIR/zenpm-hf" "$stage/ZenPM/backend/zenpm-hf"
    cp "$BUILD_DIR/zenpm-sf" "$stage/ZenPM/backend/zenpm-sf"
    copy_tree "$ROOT_DIR/frontend" "$stage/ZenPM"
    copy_tree "$ROOT_DIR/installers" "$stage/ZenPM"
    cp "$ROOT_DIR/installers/kindle/ZenPM.sh" "$stage/documents/ZenPM.sh"

    find "$stage/ZenPM/frontend/kindle/pages" -name '*.html' | while IFS= read -r f; do
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

    ensure_exec "$stage/ZenPM"
    ensure_exec "$stage/documents"
}

stage_kobo() {
    abi="$1"
    stage="$2"
    # Kobo package layout: unzip to Kobo root, then run .adds/ZenPM/installers/kobo/ZenPM.sh
    mkdir -p "$stage/.adds/ZenPM/backend"
    cp "$BUILD_DIR/zenpm-$abi" "$stage/.adds/ZenPM/backend/zenpm-$abi"
    copy_tree "$ROOT_DIR/docs" "$stage/.adds/ZenPM"
    copy_tree "$ROOT_DIR/installers" "$stage/.adds/ZenPM"

    ensure_exec "$stage/.adds/ZenPM"
}

stage_kindle "$KINDLE_STAGE"
# Kobo packages are not available yet.
# stage_kobo hf "$KOBO_HF_STAGE"
# stage_kobo sf "$KOBO_SF_STAGE"

copy_tree "$ROOT_DIR/frontend/koreader/zenpm.koplugin" "$KOREADER_PLUGIN_BASE_STAGE"
cp "$ROOT_DIR/VERSION" "$KOREADER_PLUGIN_BASE_STAGE/zenpm.koplugin/VERSION"
set_koreader_meta_version "$KOREADER_PLUGIN_BASE_STAGE/zenpm.koplugin/_meta.lua" "$VERSION"

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
cp "$BUILD_DIR/zenpm-hf" "$KOREADER_EREADER_STAGE/zenpm.koplugin/backend/zenpm-hf"
cp "$BUILD_DIR/zenpm-sf" "$KOREADER_EREADER_STAGE/zenpm.koplugin/backend/zenpm-sf"
ensure_exec "$KOREADER_EREADER_STAGE/zenpm.koplugin"

stage_koreader_plugin "$KOREADER_EREADER_ARM64_STAGE"
cp "$BUILD_DIR/zenpm-linux-arm64" "$KOREADER_EREADER_ARM64_STAGE/zenpm.koplugin/backend/zenpm-arm64"
ensure_exec "$KOREADER_EREADER_ARM64_STAGE/zenpm.koplugin"

stage_koreader_plugin "$KOREADER_ANDROID_STAGE"
ensure_exec "$KOREADER_ANDROID_STAGE/zenpm.koplugin"

stage_koreader_plugin "$KOREADER_MACOS_STAGE"
cp "$BUILD_DIR/zenpm-darwin" "$KOREADER_MACOS_STAGE/zenpm.koplugin/backend/zenpm-darwin"
ensure_exec "$KOREADER_MACOS_STAGE/zenpm.koplugin"

stage_koreader_plugin "$KOREADER_LINUX_STAGE"
cp "$BUILD_DIR/zenpm-linux" "$KOREADER_LINUX_STAGE/zenpm.koplugin/backend/zenpm-linux"
cp "$BUILD_DIR/zenpm-linux-arm64" "$KOREADER_LINUX_STAGE/zenpm.koplugin/backend/zenpm-linux-arm64"
cp "$BUILD_DIR/zenpm-linux-amd64" "$KOREADER_LINUX_STAGE/zenpm.koplugin/backend/zenpm-linux-amd64"
ensure_exec "$KOREADER_LINUX_STAGE/zenpm.koplugin"

KINDLE_ZIP="$DIST_DIR/ZenPM-kindle-standalone-$VERSION.zip"
# shellcheck disable=SC2034
KOBO_HF_ZIP="$DIST_DIR/ZenPM-kobo-hf-$VERSION.zip"
# shellcheck disable=SC2034
KOBO_SF_ZIP="$DIST_DIR/ZenPM-kobo-sf-$VERSION.zip"
KOREADER_EREADER_ZIP="$DIST_DIR/ZenPM-koreader-ereader-$VERSION.zip"
KOREADER_EREADER_ARM64_ZIP="$DIST_DIR/ZenPM-koreader-ereader-arm64-$VERSION.zip"
KOREADER_ANDROID_ZIP="$DIST_DIR/ZenPM-koreader-android-$VERSION.zip"
KOREADER_MACOS_ZIP="$DIST_DIR/ZenPM-koreader-macos-$VERSION.zip"
KOREADER_LINUX_ZIP="$DIST_DIR/ZenPM-koreader-linux-$VERSION.zip"

(
    cd "$KINDLE_STAGE"
    zip -qr "$KINDLE_ZIP" documents ZenPM
)

# (
#     cd "$KOBO_HF_STAGE"
#     zip -qr "$KOBO_HF_ZIP" .adds
# )

# (
#     cd "$KOBO_SF_STAGE"
#     zip -qr "$KOBO_SF_ZIP" .adds
# )

(
    cd "$KOREADER_EREADER_STAGE"
    zip -qr "$KOREADER_EREADER_ZIP" zenpm.koplugin
)

(
    cd "$KOREADER_EREADER_ARM64_STAGE"
    zip -qr "$KOREADER_EREADER_ARM64_ZIP" zenpm.koplugin
)

(
    cd "$KOREADER_ANDROID_STAGE"
    zip -qr "$KOREADER_ANDROID_ZIP" zenpm.koplugin
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
echo "Kindle standalone package:  $KINDLE_ZIP"
# echo "Kobo ARMhf package:         $KOBO_HF_ZIP"
# echo "Kobo ARMsf package:         $KOBO_SF_ZIP"
echo "KOReader e-reader 32-bit:   $KOREADER_EREADER_ZIP"
echo "KOReader e-reader ARM64:    $KOREADER_EREADER_ARM64_ZIP"
echo "KOReader Android plugin:     $KOREADER_ANDROID_ZIP"
echo "KOReader macOS plugin:      $KOREADER_MACOS_ZIP"
echo "KOReader Linux plugin:      $KOREADER_LINUX_ZIP"

# Bump the beta number, or the patch version for stable releases.
NEXT_VERSION=$(next_version "$VERSION")
printf '%s\n' "$NEXT_VERSION" > "$VERSION_FILE"
set_koreader_meta_version "$KOREADER_META_FILE" "$NEXT_VERSION"
echo "Next version:     $NEXT_VERSION (VERSION bumped)"
