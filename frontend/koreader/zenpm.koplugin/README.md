# ZenPM KOReader Plugin

This plugin is a native KOReader frontend for the Zen Package Manager daemon.
It mirrors the Kindle WAF frontend flows while running inside KOReader.

## Install

Copy `zenpm.koplugin` into KOReader's `plugins/` directory and restart KOReader.
Open **ZenPM** from the KOReader menu.

The backend is still deployed separately. On launch, the plugin checks
`http://127.0.0.1:8080/health`; if the daemon is not reachable, it tries to
start the deployed backend from:

- Kindle: `/mnt/us/ZenPM/backend/zenpm`
- Kobo: `/mnt/onboard/.adds/ZenPM/backend/zenpm`

## Parity Targets

- Featured, Search, Installed, Sources, Source Details, Package Details, Debug
- Repository refresh, add, remove
- Install, reinstall, uninstall with polling
- About and update actions
- Device-aware package filter: Kindle, Kobo, or host

The Kindle WAF frontend remains the visual reference. Shared labels, retry
counts, repository constants, and tab order are mirrored in `constants.lua`.
