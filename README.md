# Zen Package Manager

Package manager for jailbroken Kindle devices, with Kobo support. Browse and install packages from a WAF (WebKit Application Framework) UI backed by a local Go HTTP daemon.

## How it works

- A Go binary (`zenpm`) runs as a local HTTP daemon on `127.0.0.1:8080`.
- The Kindle WAF frontend connects to it via HTTP.
- Package operations (install/uninstall) execute on the device via the binary.
- Kobo uses NickelMenu entries that invoke the binary directly from the shell.

## Repository layout

```
cmd/zenpm/          CLI entry point (serve, repo, package, doctor, logs)
internal/           Go packages (server, state, repo, pkg, platform, launcher, log, tx)
frontend/kindle/    Kindle WAF frontend (HTML/CSS/JS)
frontend/koreader/  KOReader native plugin frontend
installers/kindle/  ZenPM.sh — on-device installer
installers/kobo/    ZenPM.sh / uninstall-zenpm.sh
docs/architecture/  Schema and behavior contracts
docs/api/           OpenAPI reference for the local daemon
```

## Design goals

- Kindle-first, same package model for Kobo.
- Static-first repository hosting (GitHub Pages compatible).
- Safe operations: lock files, journaled transactions.
- Multi-repository support with configurable trust policy.

## Build

Requires Go 1.22+ and FontTools (`pyftsubset`). Set the version in `VERSION` (SemVer):

```sh
./build.sh
```

Outputs:

- `dist/ZenPM-kindle-standalone-<version>.zip`
<!-- - `dist/ZenPM-kobo-hf-<version>.zip` -->
<!-- - `dist/ZenPM-kobo-sf-<version>.zip` -->
- `dist/ZenPM-koreader-ereader-<version>.zip`
- `dist/ZenPM-koreader-ereader-arm64-<version>.zip`
- `dist/ZenPM-koreader-android-<version>.zip`
- `dist/ZenPM-android-<version>.apk`
- `dist/ZenPM-koreader-macos-<version>.zip`
- `dist/ZenPM-koreader-linux-<version>.zip`

Use the `arm64` package on 64-bit Kobo devices. The 32-bit e-reader and Kindle
standalone packages include both the ARM hard-float (`hf`) and soft-float (`sf`)
binaries and select the correct one on the device. To check the architecture
and ABI on the device:

```sh
if [ "$(uname -m)" = aarch64 ] || [ "$(uname -m)" = arm64 ]; then echo arm64; elif [ -f /lib/ld-linux-armhf.so.3 ]; then echo hf; else echo sf; fi
```

### Choose an e-reader package

For Kobo, the architecture check determines whether to use the ARM64 or
combined 32-bit package. The `hf`/`sf` ABI does not require a separate download.

| Common device / firmware | Expected ABI | ZenPM standalone app | ZenPM KOReader plugin |
|---|---|---|---|
| Kindle running firmware 5.16.3 or newer (for example, current Paperwhite, Oasis, and Scribe devices) | `hf` | `ZenPM-kindle-standalone-<version>.zip` | `ZenPM-koreader-ereader-<version>.zip` |
| Kindle running firmware 5.16.2 or older (including legacy Kindle, Touch, and early Paperwhite installs) | `sf` | `ZenPM-kindle-standalone-<version>.zip` | `ZenPM-koreader-ereader-<version>.zip` |
| Kobo Libra Colour | `arm64` | — | `ZenPM-koreader-ereader-arm64-<version>.zip` |
| Older Kobo devices (Touch, Glo, Aura, Clara, Libra, Sage, Elipsa) | usually `hf` | <!-- `ZenPM-kobo-hf-<version>.zip` --> | `ZenPM-koreader-ereader-<version>.zip` |
| Any 32-bit e-reader that reports `sf` from the loader check | `sf` | `ZenPM-kindle-standalone-<version>.zip` on Kindle | `ZenPM-koreader-ereader-<version>.zip` |
| KOReader on Android | Android ABI | — | `ZenPM-koreader-android-<version>.zip` plus `ZenPM-android-<version>.apk` |

Package guide:

| Device/runtime | Use this package |
|---|---|
| Kindle standalone app (`hf` or `sf`) | `ZenPM-kindle-standalone-<version>.zip` |
| KOReader on a 32-bit Kindle/Kobo (`hf` or `sf`) | `ZenPM-koreader-ereader-<version>.zip` |
| KOReader on Kobo, `uname -m` prints `aarch64` or `arm64` | `ZenPM-koreader-ereader-arm64-<version>.zip` |
| KOReader on Android | `ZenPM-koreader-android-<version>.zip` plus `ZenPM-android-<version>.apk` |
| KOReader on macOS | `ZenPM-koreader-macos-<version>.zip` |
| KOReader on Linux desktop ARM64/AMD64 | `ZenPM-koreader-linux-<version>.zip` |

<!-- | Kobo standalone install, ABI check prints `hf` | `ZenPM-kobo-hf-<version>.zip` | -->
<!-- | Kobo standalone install, ABI check prints `sf` | `ZenPM-kobo-sf-<version>.zip` | -->

## Local development

```sh
# Build the host CLI.
go build -o zenpm ./cmd/zenpm

# Keep development state separate from the device or emulator state.
export ZENPM_HOME="$PWD/.zenpm-dev"
export ZENPM_PLATFORM=host

# Run the local daemon when developing the HTTP frontend.
./zenpm serve --port 8080
```

## CLI package manager

`zenpm` can be used directly from SSH, an on-device terminal, or the terminal
that launches the KOReader emulator. Package actions are top-level commands;
repository actions use `zenpm repo ...`.

```sh
# Diagnostics and logs.
zenpm doctor
zenpm logs --tail 200

# Repository management. Refresh after adding or removing a repository.
zenpm repo list
zenpm repo add my-repo https://example.com/my-repo/
zenpm repo refresh
zenpm repo remove my-repo

# Browse the refreshed catalog. Use koreader to see KOReader-compatible entries.
zenpm list
zenpm list koreader
zenpm info <package-id>

# Change packages. The optional patch-file identifies one patch asset to remove.
zenpm install <package-id>
zenpm uninstall <package-id> [patch-file]
zenpm update                 # update every installed package
zenpm update <package-id>    # update one installed package
```

### Test the CLI with the KOReader emulator

Build and run the host CLI from the terminal, but give it isolated state so it
does not affect any normal ZenPM installation:

```sh
go build -o zenpm ./cmd/zenpm
export ZENPM_HOME="$PWD/.zenpm-emulator"
export ZENPM_PLATFORM=host

./zenpm doctor
./zenpm repo list
./zenpm repo refresh
./zenpm list koreader
./zenpm info <package-id>
ZENPM_DRY_RUN=1 ./zenpm install <script-backed-package-id>
```

To exercise a native KOReader plugin install, point the CLI at the emulator's
KOReader root (the directory containing `plugins/`), then use a disposable
emulator profile:

```sh
export ZENPM_KOREADER_ROOT=/path/to/koreader
./zenpm install <plugin-package-id>
./zenpm uninstall <plugin-package-id>
```

Copy `zenpm.koplugin` to the emulator's `plugins/` directory and restart
KOReader to test the plugin UI itself. `ZENPM_DRY_RUN=1` skips shell install
scripts, but generic KOReader plugin installs are performed in-process and
still write to `ZENPM_KOREADER_ROOT`; use a disposable emulator profile for
those commands.

## API reference

The local daemon API is documented as OpenAPI 3.0 in
[`docs/api/openapi.yaml`](docs/api/openapi.yaml).

## Install on Kindle

Prerequisites: jailbroken Kindle with root, `sqlite3` on device.

1. Build: `./build.sh`
2. Extract `dist/ZenPM-kindle-standalone-<version>.zip` to the Kindle USB root.
   - Places `documents/ZenPM.sh` and the payload under `ZenPM/` at the USB root.
3. Eject and run `documents/ZenPM.sh` from your script launcher (KUAL, etc.).
4. The installer:
   - Detects ABI (ARMhf/ARMsf) and copies the correct binary to `zenpm/backend/zenpm`.
   - Deploys the WAF frontend to `/var/local/mesquite/zenpm`.
   - Registers `com.zenpm.waf` in `/var/local/appreg.db`.
   - Starts the `zenpm serve` daemon on port 8080.
   - Launches the WAF.
5. To re-launch later:

```sh
lipc-set-prop com.lab126.appmgrd start app://com.zenpm.waf
```

<!--
## Install on Kobo

Prerequisites: Kobo with SSH/telnet access.

1. Build: `./build.sh`
2. Extract `dist/ZenPM-kobo-hf-<version>.zip` or `dist/ZenPM-kobo-sf-<version>.zip` to the Kobo USB root.
3. On device:

```sh
sh /mnt/onboard/.adds/ZenPM/installers/kobo/ZenPM.sh
```

4. If NickelMenu is absent, the installer stages it and prompts for reboot. Re-run after reboot.
5. ZenPM entries appear in the NickelMenu main menu.
-->

## Install KOReader plugin

**Non-rooted Android devices:** install `ZenPM-android-<version>.apk` alongside
`ZenPM-koreader-android-<version>.zip`. The APK is the companion backend; it is required because
Android does not permit the plugin to execute its bundled backend directly.
Install it with Android's package installer (or `adb install -r <apk>`), then
install the plugin normally. See [`android/README.md`](android/README.md) for
local APK builds.

1. Extract the KOReader plugin zip for your platform:
   - `dist/ZenPM-koreader-ereader-arm64-<version>.zip` for ARM64 Kobo e-readers such as the Kobo Libra Colour
   - `dist/ZenPM-koreader-ereader-<version>.zip` for 32-bit Kindle/Kobo e-readers (`hf` or `sf`)
   - `dist/ZenPM-koreader-android-<version>.zip` for Android, alongside `ZenPM-android-<version>.apk`
   - `dist/ZenPM-koreader-macos-<version>.zip` for macOS
   - `dist/ZenPM-koreader-linux-<version>.zip` for Linux desktop
2. Copy `zenpm.koplugin/` into KOReader's `plugins/` directory.
3. Restart KOReader and open **ZenPM** from the KOReader menu.

On KOReader startup, the plugin copies the matching bundled backend into
KOReader's settings `ZenPM/backend/` directory and runs it from there. The
settings copy is refreshed whenever the plugin `_meta.lua` version or bundled
backend `VERSION` changes, so backend binaries survive plugin updates but still
track the installed plugin.

## Updating ZenPM (Kindle)

ZenPM can update itself from the WAF. Tap the system menu (⋮) and select **Update**. The updater:

1. Reads the current version from `/mnt/us/ZenPM/VERSION`
2. Queries the GitHub Releases API for the latest tag
3. If the latest version is ≤ current, shows "up to date" and exits
4. Downloads the latest `ZenPM-kindle-standalone-<version>.zip`
5. Validates the download (size + SHA256 digest from the GitHub API release metadata)
6. Stops the daemon and WAF, replaces the payload
7. Restarts the daemon and relaunches ZenPM

State databases (`/mnt/us/.ZenPM/`) are preserved across updates.

The update can also be triggered manually:

```sh
sh /mnt/us/ZenPM/update.sh
```

Or via the API:

```sh
curl -s -X POST http://127.0.0.1:8080/update
```

## Logs

All runtime output — daemon, package operations, repo refresh — goes to a single log file.

| Platform | Log file |
|---|---|
| Kindle | `/mnt/us/zenpm/zenpm.log` |
| Kobo | `/mnt/onboard/.adds/zenpm/zenpm.log` |
| Host (dev) | `~/.zenpm/zenpm.log` |

## Data persistence

State databases live outside the ZenPM payload directory so they survive app updates and re-installs.

| Platform | State directory |
|---|---|
| Kindle | `/mnt/us/.ZenPM/` |
| Kobo | `/mnt/onboard/.adds/.ZenPM/` |
| Host (dev) | `~/.zenpm/state/` |

Files in the state directory:

| File | Purpose |
|---|---|
| `repos.db` | Configured repositories |
| `installed.db` | Installed package tracking |

When ZenPM is launched by the KOReader plugin, the plugin starts its managed
backend with `ZENPM_STATE_BACKEND=sqlite`. In that mode, repositories,
installed package records, and the merged catalog are stored in
`<ZENPM_HOME>/state/zenpm.sqlite3`; logs, locks, journals, cached scripts, and
raw fetched manifests remain regular files. Standalone Kindle and Kobo installs
continue to use the flat files above.

On Kindle, if both the standalone WAF install and the KOReader plugin are
present, the KOReader SQLite database imports missing values from the standalone
Kindle flat files under `/mnt/us/.ZenPM/` and `/mnt/us/ZenPM/cache/` on startup.
Existing KOReader database rows are kept as authoritative.

On first startup, the daemon scans for known apps already on the device and tracks them automatically:

| App | Detection path |
|---|---|
| KOReader | `/mnt/us/koreader` directory |
| KUAL | `/mnt/us/extensions/kual` directory |
| Zen Reader | `/mnt/us/documents/ZenReader.sh` |
| Zen MTP | `/mnt/us/documents/ZenMTP` directory |
| Kindle Browser | `/mnt/us/documents/Browser.sh` |

Detected apps are added to `installed.db` with version `0.0.0` and repo `"device"`. This ensures they appear as installed in the WAF UI even though they were not installed through ZenPM. Re-running the scan on subsequent starts is a no-op.

## Logs (terminal)

SSH commands:

```sh
# Live tail
tail -f /mnt/us/zenpm/zenpm.log

# Via CLI
/mnt/us/zenpm/backend/zenpm logs --tail 200

# Via WAF
# Click "Show Last Log" — fetches GET http://127.0.0.1:8080/log?tail=200
```

The log includes: startup info (platform, home dir, log path), every HTTP request with status code, repo fetch URLs, catalog refresh results, and package install/uninstall output.

## Key environment variables

| Variable | Default | Description |
|---|---|---|
| `ZENPM_HOME` | platform default | State directory root |
| `ZENPM_PLATFORM` | auto-detected | Force `kindle`, `kobo`, or `host` |
| `ZENPM_STATE_BACKEND` | `flat` | Use `flat` files or `sqlite` state storage |
| `ZENPM_DRY_RUN` | unset | Set to `1` to skip shell package scripts |
| `ZENPM_DEFAULT_REPO_URL` | derived from binary path | Override default repo URL |
| `ZENPM_REPO_PUBKEY` | ZenLabs key | Override Ed25519 public key for sig verification (hex-encoded 32 bytes) |

## Repository format

ZenPM supports two registry formats with auto-detection:

- **ZenPM native** — `manifest.json` at the repo root (preferred for custom repos)
- **KindleForge** — `registry.json` flat array (for compatibility with existing KindleForge registries)

### Hosting a ZenPM repository

Each package lives in a `packages/<id>/scripts/` directory. The repo root exposes a `manifest.json` catalog that contains package metadata.

#### Directory structure

```
my-repo/
  manifest.json
  packages/
    my-package/
      scripts/
        install.sh
        uninstall.sh
```

#### `manifest.json` — package catalog

Top-level JSON object listing every package in the repo. Fetched on every `repo refresh`.

```json
{
  "schema_version": "1",
  "repo": {
    "id": "my-repo",
    "name": "My Package Repository",
    "url": "https://example.com/my-repo/"
  },
  "packages": [
    {
      "id": "my-package",
      "name": "My Package",
      "version": "1.0.0",
      "description": "What this package does.",
      "author": "Your Name",
      "featured": true,
      "featured_order": 10,
      "featured_image": "packages/my-package/featured.png",
      "readme_url": "packages/my-package/README.md",
      "platforms": ["kindle"],
      "dependencies": [],
      "install_url": "packages/my-package/scripts/install.sh",
      "uninstall_url": "packages/my-package/scripts/uninstall.sh",
      "constraints": {
        "abi": ["hf", "sf"]
      },
      "launcher": {
        "kindle": {
          "type": "kual",
          "entry_name": "My Package"
        }
      },
      "size": "0"
    }
  ]
}
```

| Field | Required | Notes |
|---|---|---|
| `schema_version` | yes | Must be `"1"` |
| `repo.id` | yes | Unique repo identifier |
| `repo.name` | yes | Human-readable repo name |
| `repo.url` | yes | Base URL of the repo (used to resolve relative paths) |
| `packages[].id` | yes | Unique package identifier |
| `packages[].name` | yes | Display name |
| `packages[].version` | yes | SemVer string (e.g. `"1.2.3"`) |
| `packages[].description` | no | Short description shown on the package card |
| `packages[].author` | no | Author/ maintainer name |
| `packages[].featured` | no | Mark this package for the Featured page |
| `packages[].featured_order` | no | Numeric ascending order on the Featured page; unordered packages follow ordered ones |
| `packages[].featured_image` | no | Large Featured-page banner image; relative paths resolve against `repo.url` |
| `packages[].readme_url` | no | Package README Markdown; relative paths resolve against `repo.url`. ZenPM fetches README content only from this repository-hosted URL. |
| `packages[].platforms` | yes | Array of platform capabilities such as `"kindle"`, `"kobo"`, `"android"`, and `"koreader"` |
| `packages[].incompatible_platforms` | no | Array of platform capabilities that explicitly exclude the package, such as `["android", "host"]` |
| `packages[].dependencies` | no | Array of package `id` strings required before install |
| `packages[].conflicts` | no | Array of package `id` strings that should not be used together; ZenPM warns but permits installation |
| `packages[].install_url` | yes | Path to install script (relative to repo URL) |
| `packages[].uninstall_url` | no | Path to uninstall script |
| `packages[].constraints.abi` | no | Restrict to ARMhf (`hf`) or ARMsf (`sf`) — planned, not yet enforced |
| `packages[].launcher` | no | Auto-create a launcher entry after install — planned, not yet implemented |
| `packages[].size` | no | Size in bytes (future use) |

**Launcher config (planned):**

```json
"launcher": {
  "kindle": { "type": "kual", "entry_name": "My App" },
  "kobo":   { "type": "nickelmenu", "entry_name": "My App", "location": "main" }
}
```

Currently launcher entries must be created manually in install scripts. Automatic launcher registration is planned for a future release.

#### `install.sh` / `uninstall.sh` — shell scripts

Scripts run on-device via `/bin/sh`. They receive no arguments. Exit 0 for success, non-zero for failure.

Example install script:

```sh
#!/bin/sh
set -e
cp -r /mnt/us/my-package-data /mnt/us/extensions/my-package/
exit 0
```

#### Hosting options

A ZenPM repo is just static files — host it on any static file server:

- **GitHub Pages** — push to a `gh-pages` branch or configure Pages on `main`. URL pattern: `https://<user>.github.io/<repo>/`
- **Raw GitHub** — use `https://raw.githubusercontent.com/<user>/<repo>/main/`
- **Any static host** — Netlify, Cloudflare Pages, or a simple nginx/Apache directory

#### Adding a repo to ZenPM

Once hosted, users can add the repo to their device. Repo maintainers can provide one of these methods in their README or install instructions.

**Option 1 — ZenPM CLI (SSH or on-device terminal)**

```sh
zenpm repo add my-repo https://example.com/my-repo/
zenpm repo refresh
```

Priority and trust level are determined automatically by the backend — callers cannot set them.

**Option 2 — HTTP API (from any HTTP client on the device)**

The ZenPM daemon listens on `127.0.0.1:8080`. Any process on the device can add a repo by POSTing to `/repos`:

```sh
curl -s -X POST http://127.0.0.1:8080/repos \
  -H 'Content-Type: application/json' \
  -d '{"name":"my-repo","url":"https://example.com/my-repo/"}'
```

Priority and trust are backend-determined — only `name` and `url` are accepted.

Then trigger a refresh:

```sh
curl -s -X POST http://127.0.0.1:8080/repo/refresh
```

**Option 3 — From a repo's own install script**

A repo's `install.sh` can register itself with ZenPM during installation, so the user gets automatic updates:

```sh
#!/bin/sh
set -e

# Install the package
cp -r /mnt/us/my-package /mnt/us/extensions/my-package/

# Register this repo with ZenPM for future updates
curl -s -X POST http://127.0.0.1:8080/repos \
  -H 'Content-Type: application/json' \
  -d '{"name":"my-repo","url":"https://example.com/my-repo/"}'
curl -s -X POST http://127.0.0.1:8080/repo/refresh

exit 0
```

Since ZenPM binds to loopback only, these requests can only originate from the device itself — remote servers cannot trigger repo additions.

**Option 4 — WAF Sources page**

Users can also add repos interactively from the ZenPM Sources tab in the Kindle WAF UI by entering the name and URL.

**API reference — `POST /repos`**

| Field | Required | Notes |
|---|---|---|
| `name` | yes | Unique repo identifier |
| `url` | yes | Base URL of the repo (trailing slash recommended) |

Priority is always `100` for user-added repos (default repos use `10` for higher precedence). Trust level is auto-detected:

- `signed` — repo has a valid `manifest.json.sig` Ed25519 signature
- `warn-unsigned` — no valid signature found, or repo uses plain HTTP
- `trusted` — built-in default repos (KindleForge, ZenLabs)

Callers cannot override priority or trust via the API.

Response on success (HTTP 201):

```json
{"ok": true}
```

Response on conflict (HTTP 409) — name already exists or collides with a default repo:

```json
{"error": "repo \"kindle-forge\" already exists"}
```

#### Adding a repo via the Kindle browser

The Kindle experimental browser may not open custom URL schemes. The recommended approach for repo maintainers is a **JavaScript button** that POSTs directly to the ZenPM daemon running on the device. CORS is already enabled on the daemon.

**Copy-paste this into your repo's webpage (GitHub Pages, etc.):**

```html
<button id="zenpm-add-btn" style="padding:12px 24px;font-size:1rem;cursor:pointer;">
  Add to ZenPM
</button>

<script>
document.getElementById('zenpm-add-btn').onclick = function() {
  var btn = this;
  btn.disabled = true;
  btn.textContent = 'Adding...';

  fetch('http://127.0.0.1:8080/repos', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      name: 'my-repo',
      url: 'https://example.com/my-repo/'
    })
  }).then(function(r) {
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return fetch('http://127.0.0.1:8080/repo/refresh', { method: 'POST' });
  }).then(function(r) {
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return fetch('http://127.0.0.1:8080/foreground', { method: 'POST' });
  }).then(function() {
    btn.textContent = 'Added! Open ZenPM.';
  }).catch(function(err) {
    btn.disabled = false;
    btn.textContent = 'Add to ZenPM';
    alert('Could not reach ZenPM daemon. Is it running?\n\n' + err.message);
  });
};
</script>
```

**How it works:**

1. Kindle browser loads your repo's GitHub Pages page
2. User taps "Add to ZenPM" — JavaScript POSTs to `127.0.0.1:8080/repos` (CORS allowed)
3. On success: refreshes catalog then foregrounds the ZenPM app via `/foreground`
4. Priority and trust are backend-determined — the caller only provides `name` and `url`
5. If daemon isn't running, shows a clear error message

This works because the Kindle browser can make HTTP requests to localhost — no URL scheme needed.

#### Auto-detection notes

ZenPM fetches `manifest.json` first. If that returns 404 or isn't a valid ZenPM catalog object, it falls back to trying `registry.json` as a KindleForge-format flat array. This means a single repo URL can serve both formats — or you can host exclusively one format and ZenPM will detect it automatically.

#### Repo signing with `manifest.json.sig`

Repos can include an Ed25519 detached signature to earn the `signed` trust level. Place a `manifest.json.sig` file alongside `manifest.json` at the repo root:

```
my-repo/
  manifest.json
  manifest.json.sig    ← hex-encoded Ed25519 signature of SHA-256(manifest.json)
```

The `.sig` file contains the raw 64-byte Ed25519 signature of `manifest.json`'s raw bytes (or hex-encoded — both are accepted). ZenPM uses the ZenLabs public key by default; override via `ZENPM_REPO_PUBKEY` (hex-encoded 32-byte key).

```sh
# Sign manifest.json with your Ed25519 private key (raw binary output):
openssl pkeyutl -sign -inkey private.pem -rawin -in manifest.json -out manifest.json.sig
```

**Trust levels:**

| Trust | Meaning |
|---|---|
| `trusted` | Built-in default repo (KindleForge, ZenLabs) |
| `signed` | Valid `manifest.json.sig` found and verified |
| `warn-unsigned` | No valid signature, or plain HTTP repo |

#### HTTPS requirement

Repos served over plain HTTP will be set to `warn-unsigned` regardless of signature status — signatures are meaningless over unencrypted transport. The API response includes a `warning` field for HTTP repos. Localhost and `file://` URLs are exempt from this check.

## Safety notes

- The HTTP daemon binds to `127.0.0.1` only — not accessible from other devices.
- `ZENPM_DRY_RUN=1` skips shell package script execution. Generic KOReader plugin installs run in-process, so use a disposable KOReader root when testing them.
- Do not run package installs without dry-run on non-Kindle/Kobo machines.
