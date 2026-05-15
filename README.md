# Zen Package Manager

Package manager for jailbroken Kindle devices, with Kobo support. Browse and install packages from a WAF (WebKit Application Framework) UI backed by a local Go HTTP daemon.

## How it works

- A Go binary (`zenpm`) runs as a local HTTP daemon on `127.0.0.1:8080`.
- The Kindle WAF frontend connects to it via XHR — no LIPC, no `utild`.
- Package operations (install/uninstall) execute on the device via the binary.
- Kobo uses NickelMenu entries that invoke the binary directly from the shell.

## Repository layout

```
cmd/zenpm/          CLI entry point (serve, repo, package, doctor, logs)
internal/           Go packages (server, state, repo, pkg, platform, launcher, log, tx)
frontend/kindle/    Kindle WAF frontend (HTML/CSS/JS)
repos/default/      Default static package repository
installers/kindle/  ZenPM.sh — on-device installer
installers/kobo/    ZenPM.sh / uninstall-zenpm.sh
docs/architecture/  Schema and behavior contracts
```

## Design goals

- Kindle-first, same package model for Kobo.
- Static-first repository hosting (GitHub Pages compatible).
- Safe operations: lock files, journaled transactions.
- Multi-repository support with configurable trust policy.

## Build

Requires Go 1.22+. Set the version in `VERSION` (SemVer):

```sh
./build.sh
```

Outputs:

- `dist/zenpm-kindle-<version>.zip`
- `dist/zenpm-kobo-<version>.zip`

Each zip contains ARMhf (`zenpm-hf`) and ARMsf (`zenpm-sf`) binaries. The installer selects the correct one at install time.

## Local development

```sh
# Build for host
go build -o zenpm ./cmd/zenpm

# Run daemon
ZENPM_HOME=/tmp/.zenpm ZENPM_PLATFORM=host ./zenpm serve --port 8080

# CLI commands
./zenpm doctor
./zenpm repo list
./zenpm repo refresh
./zenpm package list kindle
ZENPM_DRY_RUN=1 ./zenpm package install koreader-kindle
```

## Install on Kindle

Prerequisites: jailbroken Kindle with root, `sqlite3` on device.

1. Build: `./build.sh`
2. Extract `dist/zenpm-kindle-<version>.zip` to the Kindle USB root.
   - Places `documents/ZenPM.sh` and the payload under `zenpm/` at the USB root.
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

## Install on Kobo

Prerequisites: Kobo with SSH/telnet access.

1. Build: `./build.sh`
2. Extract `dist/zenpm-kobo-<version>.zip` to the Kobo USB root.
3. On device:

```sh
sh /mnt/onboard/.adds/zenpm/installers/kobo/ZenPM.sh
```

4. If NickelMenu is absent, the installer stages it and prompts for reboot. Re-run after reboot.
5. ZenPM entries appear in the NickelMenu main menu.

## Logs

All runtime output — daemon, package operations, repo refresh — goes to a single log file.

| Platform | Log file |
|---|---|
| Kindle | `/mnt/us/zenpm/zenpm.log` |
| Kobo | `/mnt/onboard/.adds/zenpm/zenpm.log` |
| Host (dev) | `~/.zenpm/zenpm.log` |

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
| `ZENPM_DRY_RUN` | unset | Set to `1` for no-op installs |
| `ZENPM_DEFAULT_REPO_URL` | derived from binary path | Override default repo URL |

## Repository format

Static repository hosting. Each repo needs:

- `index.json` — package metadata (fetched by the Go client)

Hosted repos work on GitHub Pages or any static file server.

## Safety notes

- The HTTP daemon binds to `127.0.0.1` only — not accessible from other devices.
- `ZENPM_DRY_RUN=1` skips all package script execution — safe for testing on host.
- Do not run package installs without dry-run on non-Kindle/Kobo machines.
