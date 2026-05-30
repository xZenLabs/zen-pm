# Kindle WAF Frontend Shell

This folder contains the first Zen PM Kindle frontend shell.

## Files

- index.html - home page with featured packages placeholder.
- packages.html - package browser shell (install/uninstall).
- sources.html - repository source management.
- log.html - debug log viewer.
- style.css - shared styling including bottom navbar.
- script.js - package loading and action wiring (used by packages.html).
- sources.js - repository CRUD logic.
- log.js - log viewer logic.
- utils.js - shared utilities and navbar rendering.
- navbar.js - (deprecated; merged into utils.js).
- config.xml - WAF metadata and Kindle API permissions.

## Runtime assumptions

- A command bridge service is available at com.kindlemodding.utild using runCMD.
- Zen PM backend command exists at /mnt/us/zenpm/backend/zenpm.sh.
- Output files are written to /mnt/us/.zenpm/waf/.

You can change the backend command path in the UI and save it.

## Action flow

1. Refresh command runs repo refresh and package list kindle.
2. Frontend reads output TSV from /mnt/us/.zenpm/waf/packages.tsv.
3. Install and uninstall buttons trigger package commands.
4. Frontend reads command logs from /mnt/us/.zenpm/waf/action.log.
