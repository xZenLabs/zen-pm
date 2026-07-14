# ZenPM KOReader Plugin

This plugin is a native KOReader frontend for the Zen Package Manager daemon.
It mirrors the Kindle WAF frontend flows while running inside KOReader.

## Install

Extract the KOReader plugin zip for your platform, copy `zenpm.koplugin` into
KOReader's `plugins/` directory, and restart KOReader.
Open **ZenPM** from the KOReader menu.

Release zips are platform-specific:

- `ZenPM-koreader-ereader-hf-<version>.zip` for Kindle/Kobo e-readers with the ARM hard-float loader
- `ZenPM-koreader-ereader-sf-<version>.zip` for older Kindle/Kobo e-readers without the ARM hard-float loader
- `ZenPM-koreader-macos-<version>.zip` for macOS
- `ZenPM-koreader-linux-<version>.zip` for Linux desktop

To check an e-reader's ABI, run this on the device:

```sh
if [ -f /lib/ld-linux-armhf.so.3 ]; then echo hf; else echo sf; fi
```

On KOReader startup, the plugin prepares a backend path for the device and runs
the backend from there.

The settings copy is refreshed whenever either of these changes:

- `_meta.lua` plugin `version`
- bundled `backend/VERSION`

The managed backend binary lives in the settings `ZenPM/backend/` directory so
it survives plugin updates.

SQLite is the backend's only state store. The plugin always exports
`ZENPM_HOME` under KOReader's settings `ZenPM/` directory, keeping its backend,
database, logs, journals, locks, downloaded scripts, and raw repo manifests
separate from a native ZenPM install.

## Parity Targets

- Featured, Search, Installed, Sources, Source Details, Package Details, Debug
- Repository refresh, add, remove
- Install, reinstall, uninstall with polling
- About and update actions
- Device-aware package filter: Kindle, Kobo, or host

The Kindle WAF frontend remains the visual reference. Shared labels, retry
counts, repository constants, and tab order are mirrored in `constants.lua`.
