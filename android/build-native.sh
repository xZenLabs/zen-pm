#!/bin/sh
set -eu

: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to an Android NDK installation}"
prebuilt="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt"
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        if [ -d "$prebuilt/darwin-arm64" ]; then host=darwin-arm64; else host=darwin-x86_64; fi
        ;;
    Darwin-*) host=darwin-x86_64 ;;
    Linux-x86_64) host=linux-x86_64 ;;
    *) echo "Unsupported build host" >&2; exit 1 ;;
esac
version=$(sed -n '1p' ../VERSION)

build() {
    abi=$1
    goarch=$2
    cc=$3
    out="app/src/main/jniLibs/$abi/libzenpm.so"
    [ -x "$cc" ] || { echo "Android NDK compiler not found: $cc" >&2; exit 1; }
    mkdir -p "$(dirname "$out")"
    GOOS=android GOARCH="$goarch" CGO_ENABLED=1 CC="$cc" GOTOOLCHAIN=go1.20.14 \
        go build -buildmode=c-shared -ldflags "-s -w -X github.com/xZenLabs/zen-pm/internal/androidbackend.Version=$version" -o "$out" ./backend
}

build armeabi-v7a arm "$prebuilt/$host/bin/armv7a-linux-androideabi19-clang"
build arm64-v8a arm64 "$prebuilt/$host/bin/aarch64-linux-android21-clang"
