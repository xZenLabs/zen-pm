#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
LEGACY="$ROOT/toolchains/legacy"
EXPECTED_VERSION=go1.26.6

VERSION=$(sed -n '1p' "$LEGACY/VERSION")
[ "$VERSION" = "$EXPECTED_VERSION" ] || {
    echo "legacy compiler must remain pinned to $EXPECTED_VERSION; found $VERSION" >&2
    exit 1
}

CHECKSUM=$(awk 'NR == 1 { print $1 }' "$LEGACY/SHA256")
ARCHIVE=$(awk 'NR == 1 { print $2 }' "$LEGACY/SHA256")
[ "$(awk 'NR == 1 { print NF }' "$LEGACY/SHA256")" -eq 2 ] || {
    echo "toolchain checksum file is malformed" >&2
    exit 1
}
[ "${#CHECKSUM}" -eq 64 ] || { echo "toolchain source SHA-256 is malformed" >&2; exit 1; }
case "$CHECKSUM" in *[!0-9a-f]*) echo "toolchain source SHA-256 must be lowercase hexadecimal" >&2; exit 1 ;; esac
[ "$ARCHIVE" = "$EXPECTED_VERSION.src.tar.gz" ] || { echo "toolchain source filename is not pinned" >&2; exit 1; }

PATCH="$LEGACY/0001-linux-arm-use-epoll-wait.patch"
[ -f "$PATCH" ] || { echo "old-kernel compatibility patch is missing" >&2; exit 1; }
grep -q 'defs_linux_arm.go' "$PATCH"
grep -q 'SYS_EPOLL_PWAIT.*252' "$PATCH"
grep -q 'SYS_EPOLL_PWAIT.*346' "$PATCH"
grep -q 'zsyscall_linux_arm.go' "$PATCH"
grep -q 'e1 == ENOSYS' "$PATCH"
grep -q 'Syscall(SYS_ACCEPT,' "$PATCH"
grep -q 'SetNonblock(fd, true)' "$PATCH"
grep -q 'ZENPM_PATCH_LEVEL' "$LEGACY/bootstrap.sh"
grep -q 'ZenPM Linux/ARM old-kernel patch 2' "$LEGACY/bootstrap.sh"
grep -q 'ZenPM Linux/ARM old-kernel patch 2' "$ROOT/build.sh"
grep -q "$EXPECTED_VERSION-kindle-p2" "$ROOT/build.sh"

echo "ok - pinned $EXPECTED_VERSION source and reviewed Linux/ARM epoll/accept patch metadata"
