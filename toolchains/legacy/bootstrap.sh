#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
PROJECT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
VERSION=$(sed -n '1p' "$SCRIPT_DIR/VERSION")
PATCH_LEVEL='ZenPM Linux/ARM old-kernel patch 2'
ARCHIVE="$VERSION.src.tar.gz"
EXPECTED=$(sed -n '1{s/[[:space:]].*$//;p;}' "$SCRIPT_DIR/SHA256")
OUTPUT=${1:-"$PROJECT_DIR/.toolchains/$VERSION-kindle-p2"}
CACHE=${ZENPM_TOOLCHAIN_CACHE:-"$PROJECT_DIR/.toolchains/cache"}
SOURCE_ARCHIVE=${ZENPM_GO_SOURCE_ARCHIVE:-"$CACHE/$ARCHIVE"}

case "$VERSION" in
    go1.[0-9]*.[0-9]*) ;;
    *) echo "Invalid pinned Go version: $VERSION" >&2; exit 1 ;;
esac
case "$EXPECTED" in
    *[!0-9a-f]*|'') echo "Invalid source checksum" >&2; exit 1 ;;
esac

if [ -x "$OUTPUT/bin/go" ] &&
    [ "$("$OUTPUT/bin/go" version 2>/dev/null | awk '{print $3}')" = "$VERSION" ] &&
    [ "$(sed -n '1p' "$OUTPUT/ZENPM_PATCH_LEVEL" 2>/dev/null || true)" = "$PATCH_LEVEL" ]; then
    printf '%s\n' "$OUTPUT/bin/go"
    exit 0
fi
if [ -e "$OUTPUT" ]; then
    echo "Refusing to replace an existing incomplete toolchain: $OUTPUT" >&2
    exit 1
fi

mkdir -p "$CACHE" "$(dirname "$OUTPUT")"
if [ ! -f "$SOURCE_ARCHIVE" ]; then
    URL="https://go.dev/dl/$ARCHIVE"
    PART="$SOURCE_ARCHIVE.part"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --proto '=https' --tlsv1.2 --output "$PART" "$URL"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --output-document="$PART" "$URL"
    else
        echo "curl or wget is required to fetch $URL" >&2
        exit 1
    fi
    mv "$PART" "$SOURCE_ARCHIVE"
fi

if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "$SOURCE_ARCHIVE" | awk '{print $1}')
else
    ACTUAL=$(shasum -a 256 "$SOURCE_ARCHIVE" | awk '{print $1}')
fi
if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "Go source checksum mismatch: expected $EXPECTED, got $ACTUAL" >&2
    exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/zenpm-go-toolchain.XXXXXX")
cleanup() {
    case "$WORK" in
        "${TMPDIR:-/tmp}"/zenpm-go-toolchain.*) rm -rf "$WORK" ;;
    esac
}
trap cleanup EXIT INT TERM

tar -xzf "$SOURCE_ARCHIVE" -C "$WORK"
patch -d "$WORK/go" -p1 < "$SCRIPT_DIR/0001-linux-arm-use-epoll-wait.patch"

if [ -z "${GOROOT_BOOTSTRAP:-}" ]; then
    if ! command -v go >/dev/null 2>&1; then
        echo "A supported bootstrap Go toolchain is required" >&2
        exit 1
    fi
    GOROOT_BOOTSTRAP=$(go env GOROOT)
    export GOROOT_BOOTSTRAP
fi

(
    cd "$WORK/go/src"
    ./make.bash
)
printf '%s\n' "$PATCH_LEVEL" > "$WORK/go/ZENPM_PATCH_LEVEL"
mv "$WORK/go" "$OUTPUT"
printf '%s\n' "$OUTPUT/bin/go"
