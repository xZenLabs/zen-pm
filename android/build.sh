#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
GRADLE_BIN=${GRADLE_BIN:-gradle}

if ! command -v java >/dev/null 2>&1; then
    echo "Java 17 is required." >&2
    exit 1
fi
java_version=$(java -version 2>&1 | sed -n '1{s/.*version "\([^"]*\)".*/\1/p;}')
case "$java_version" in
    17|17.*) ;;
    *)
        echo "Java 17 is required; found ${java_version:-unknown}." >&2
        exit 1
        ;;
esac

if ! command -v "$GRADLE_BIN" >/dev/null 2>&1; then
    echo "Gradle 8.6 is required. Set GRADLE_BIN to its executable." >&2
    exit 1
fi
gradle_version=$("$GRADLE_BIN" --version | sed -n 's/^Gradle \([0-9][0-9.]*\)$/\1/p')
if [ "$gradle_version" != "8.6" ]; then
    echo "Gradle 8.6 is required by Android Gradle Plugin 8.4.2; found ${gradle_version:-unknown}." >&2
    exit 1
fi

android_home=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
if [ -z "$android_home" ] || [ ! -d "$android_home" ]; then
    echo "Set ANDROID_HOME (or ANDROID_SDK_ROOT) to an Android SDK installation." >&2
    exit 1
fi
export ANDROID_HOME=$android_home

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    ANDROID_NDK_HOME="$ANDROID_HOME/ndk/25.2.9519653"
fi
if [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "Set ANDROID_NDK_HOME to an Android NDK installation." >&2
    exit 1
fi
export ANDROID_NDK_HOME

exec "$GRADLE_BIN" -p "$SCRIPT_DIR" assembleRelease "$@"
