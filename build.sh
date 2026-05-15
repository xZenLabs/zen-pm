#!/bin/sh
set -eu

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

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_array_from_csv() {
    csv="$1"
    if [ -z "$csv" ]; then
        printf '[]'
        return 0
    fi

    old_ifs="$IFS"
    IFS=','
    first=1
    printf '['
    for item in $csv; do
        trimmed=$(printf '%s' "$item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        escaped=$(json_escape "$trimmed")
        if [ "$first" -eq 0 ]; then
            printf ', '
        fi
        printf '"%s"' "$escaped"
        first=0
    done
    printf ']'
    IFS="$old_ifs"
}

filter_catalog_for_platform() {
    catalog_path="$1"
    platform="$2"
    tmp_path="$catalog_path.tmp"

    awk -F'\t' -v target="$platform" '
        function has_platform(csv, needle, n, i, arr, value) {
            n = split(csv, arr, ",")
            for (i = 1; i <= n; i++) {
                value = arr[i]
                gsub(/^ +| +$/, "", value)
                if (value == needle) {
                    return 1
                }
            }
            return 0
        }
        /^#/ { print; next }
        $1 == "id" { print; next }
        NF == 0 { next }
        has_platform($4, target) { print }
    ' "$catalog_path" > "$tmp_path"

    mv "$tmp_path" "$catalog_path"
}

prune_packages_from_catalog() {
    repo_default_dir="$1"
    catalog_path="$repo_default_dir/catalog.tsv"
    packages_dir="$repo_default_dir/packages"

    if [ ! -d "$packages_dir" ]; then
        return 0
    fi

    for pkg_path in "$packages_dir"/*; do
        [ -e "$pkg_path" ] || continue
        pkg_id=$(basename "$pkg_path")
        if ! awk -F'\t' -v id="$pkg_id" '$1 == id { found = 1 } END { exit found ? 0 : 1 }' "$catalog_path"; then
            rm -rf "$pkg_path"
        fi
    done
}

write_index_from_catalog() {
    repo_default_dir="$1"
    catalog_path="$repo_default_dir/catalog.tsv"
    index_path="$repo_default_dir/index.json"
    tab_char=$(printf '\t')

    {
        printf '{\n'
        printf '  "schema_version": "1",\n'
        printf '  "repo": {\n'
        printf '    "id": "zenpm-default",\n'
        printf '    "name": "Zen PM Default Repository",\n'
        printf '    "url": "file://repos/default"\n'
        printf '  },\n'
        printf '  "packages": [\n'

        first_pkg=1
        while IFS="$tab_char" read -r id name version platforms dependencies install_url uninstall_url manifest_url sha256 size; do
            [ -n "$id" ] || continue
            case "$id" in
                '#'*|id)
                    continue
                    ;;
            esac

            name_esc=$(json_escape "$name")
            version_esc=$(json_escape "$version")
            install_url_esc=$(json_escape "$install_url")
            uninstall_url_esc=$(json_escape "$uninstall_url")
            manifest_url_esc=$(json_escape "$manifest_url")
            sha256_esc=$(json_escape "$sha256")
            size_esc=$(json_escape "$size")
            platforms_json=$(json_array_from_csv "$platforms")
            dependencies_json=$(json_array_from_csv "$dependencies")

            if [ "$first_pkg" -eq 0 ]; then
                printf ',\n'
            fi

            printf '    {\n'
            printf '      "id": "%s",\n' "$id"
            printf '      "name": "%s",\n' "$name_esc"
            printf '      "version": "%s",\n' "$version_esc"
            printf '      "platforms": %s,\n' "$platforms_json"
            printf '      "dependencies": %s,\n' "$dependencies_json"
            printf '      "install_url": "%s",\n' "$install_url_esc"
            printf '      "uninstall_url": "%s",\n' "$uninstall_url_esc"
            printf '      "manifest_url": "%s",\n' "$manifest_url_esc"
            printf '      "sha256": "%s",\n' "$sha256_esc"
            printf '      "size": "%s"\n' "$size_esc"
            printf '    }'

            first_pkg=0
        done < "$catalog_path"

        printf '\n'
        printf '  ]\n'
        printf '}\n'
    } > "$index_path"
}

prune_platform_content() {
    zenpm_root="$1"
    platform="$2"

    installers_dir="$zenpm_root/installers"
    repo_default_dir="$zenpm_root/repos/default"

    case "$platform" in
        kindle)
            rm -rf "$installers_dir/kobo"
            ;;
        kobo)
            rm -rf "$installers_dir/kindle"
            ;;
        *)
            echo "Unsupported platform for pruning: $platform"
            exit 1
            ;;
    esac

    filter_catalog_for_platform "$repo_default_dir/catalog.tsv" "$platform"
    prune_packages_from_catalog "$repo_default_dir"
    write_index_from_catalog "$repo_default_dir"
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

# Payload staged at zenpm/ (zip root) so it extracts to /mnt/us/zenpm/ — the final install
# location. Shell scripts outside documents/ are never indexed as Kindle books.
# Only one .sh file lives in documents/ (the scriptlet the user taps to install).
mkdir -p "$KINDLE_STAGE/documents" "$KINDLE_STAGE/zenpm/backend"
cp "$BUILD_DIR/zenpm-hf" "$KINDLE_STAGE/zenpm/backend/zenpm-hf"
cp "$BUILD_DIR/zenpm-sf" "$KINDLE_STAGE/zenpm/backend/zenpm-sf"
copy_tree "$ROOT_DIR/frontend" "$KINDLE_STAGE/zenpm"
copy_tree "$ROOT_DIR/repos"    "$KINDLE_STAGE/zenpm"
cp "$ROOT_DIR/installers/kindle/ZenPM.sh" "$KINDLE_STAGE/documents/ZenPM.sh"

# Inject version into asset URLs so WebKit cache is busted on each release.
_waf_html="$KINDLE_STAGE/zenpm/frontend/kindle/index.html"
sed "s/script\.js\"/script.js?v=$VERSION\"/g; s/style\.css\"/style.css?v=$VERSION\"/g" \
    "$_waf_html" > "$_waf_html.tmp" && mv "$_waf_html.tmp" "$_waf_html"

prune_platform_content "$KINDLE_STAGE/zenpm" "kindle"

ensure_exec "$KINDLE_STAGE/zenpm"
ensure_exec "$KINDLE_STAGE/documents"

# Kobo package layout: unzip to Kobo root, then run .adds/zenpm/installers/kobo/install-zenpm.sh
mkdir -p "$KOBO_STAGE/.adds/zenpm/backend"
cp "$BUILD_DIR/zenpm-hf" "$KOBO_STAGE/.adds/zenpm/backend/zenpm-hf"
cp "$BUILD_DIR/zenpm-sf" "$KOBO_STAGE/.adds/zenpm/backend/zenpm-sf"
copy_tree "$ROOT_DIR/repos" "$KOBO_STAGE/.adds/zenpm"
copy_tree "$ROOT_DIR/docs" "$KOBO_STAGE/.adds/zenpm"
copy_tree "$ROOT_DIR/installers" "$KOBO_STAGE/.adds/zenpm"

prune_platform_content "$KOBO_STAGE/.adds/zenpm" "kobo"

ensure_exec "$KOBO_STAGE/.adds/zenpm"

KINDLE_ZIP="$DIST_DIR/zenpm-kindle-$VERSION.zip"
KOBO_ZIP="$DIST_DIR/zenpm-kobo-$VERSION.zip"

(
    cd "$KINDLE_STAGE"
    zip -qr "$KINDLE_ZIP" documents zenpm
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
