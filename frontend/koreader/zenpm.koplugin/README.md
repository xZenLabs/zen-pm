# ZenPM KOReader Plugin

This plugin is a native KOReader frontend for the Zen Package Manager daemon.
It mirrors the Kindle WAF frontend flows while running inside KOReader.

## Install

Copy `zenpm.koplugin` into KOReader's `plugins/` directory and restart KOReader.
Open **ZenPM** from the KOReader menu.

The plugin zip includes ARMhf, ARMsf, Linux ARM64, Linux AMD64, macOS ARM64,
and macOS AMD64 ZenPM backend binaries under `zenpm.koplugin/backend/`. On KOReader startup, the
plugin copies the matching backend into KOReader's settings
`ZenPM/backend/zenpm` path and runs it from there.

The settings copy is refreshed whenever either of these changes:

- `_meta.lua` plugin `version`
- bundled `backend/VERSION`

State, cache, logs, and the managed backend live in the settings `ZenPM/`
directory so they survive plugin updates.

## Parity Targets

- Featured, Search, Installed, Sources, Source Details, Package Details, Debug
- Repository refresh, add, remove
- Install, reinstall, uninstall with polling
- About and update actions
- Device-aware package filter: Kindle, Kobo, or host

The Kindle WAF frontend remains the visual reference. Shared labels, retry
counts, repository constants, and tab order are mirrored in `constants.lua`.
