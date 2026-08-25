# ZenPM KOReader Plugin

This plugin is a native KOReader frontend for the Zen Package Manager daemon.
It mirrors the Kindle WAF frontend flows while running inside KOReader.

## Install

Extract the KOReader plugin zip for your platform, copy `zenpm.koplugin` into
KOReader's `plugins/` directory, and restart KOReader.
Open **ZenPM** from the KOReader menu.

Release zips are platform-specific:

- `ZenPM-koreader-ereader-<version>.zip` for 32-bit Kindle/Kobo e-readers; it includes both ARM hard-float and soft-float backends
- `ZenPM-koreader-linux-<version>.zip` for ARM64 Kobo e-readers, including the Kobo Libra Colour, and Linux desktop
- `ZenPM-koreader-macos-<version>.zip` for macOS

On Kobo, check the CPU architecture first:

```sh
uname -m
```

Use the Linux package when this prints `aarch64` or `arm64`. Otherwise, use the
combined 32-bit e-reader package; ZenPM detects the ABI on the device.

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

- Featured, Changes, Categories, Installed, Discover, Sources, Source Details, Package Details, Debug
- Repository refresh, add, remove
- Install, reinstall, uninstall with polling
- About and update actions
- Device-aware package filter: Kindle, Kobo, or host

The Kindle WAF frontend remains the visual reference. Shared labels, retry
counts, and repository constants are mirrored in `zenpm_constants.lua`.
