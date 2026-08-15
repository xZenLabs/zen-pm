-- Post-update "What's New" bullet lists, keyed by version string.
-- Add an entry for each release with noteworthy changes.
-- Omit a version to show no changelog on that update.
--
-- Example:
-- ["0.1.0"] = {
--     "New feature added",
--     "Bug fix for ...",
-- },

return {
    ["1.0.0"] = {
        "Initial release"
    },
    ["1.1.0"] = {
        "Add release notes",
        "Add filter for installed packages",
        "Scroll featured image up when scrolling package descriptions",
        "Bug fixes"
    },
    ["1.1.1"] = {
        "Fix potential backend port conflict",
        "Fix README not loading sometimes",
        "Fuzzy match assets that aren't exactly the same from release -> prerelease",
        "Better tab styling"
    },
    ["1.1.2"] = {
        "Fix incorrectly matched preinstalled plugin",
    },
    ["1.2.0"] = {
        "Migrate from HTTP server to UDS for all systems",
        "README performance + layout improvements",
        "Add non-touch support",
        "Add option to ignore updates for package",
        "Add re-open ZenPM on reboot option",
        "Remove confirmation for enable/disable",
        "Fix clear search term",
        "Fix ZenPM package in Queue",
        "Fix false unknown plugin matching",
        "Fix duplicate unknown and known entries for prev installed items",
        "Android performance improvements",
    },
    ["1.3.0"] = {
        "Add Changes tab",
        "Add simple mode",
    },
    ["1.3.1"] = {
        "Boox bug fixes",
        "Minor bug fixes"
    },
    ["1.4.0"] = {
        "ZenOS migration",
        "Update icon",
        "Fix false plugin upgrade failure notices after Android backend interruptions",
    },
    ["1.4.1"] = {
        "Fix an edge case on android where backend can close while a package is updating"
    },
}
