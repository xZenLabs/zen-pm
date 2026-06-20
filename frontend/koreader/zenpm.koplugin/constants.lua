local source = debug.getinfo(1, "S").source or ""
local plugin_dir = source:match("^@(.+)/constants%.lua$") or "plugins/zenpm.koplugin"
return {
    PLUGIN_DIR = plugin_dir,
    ASSET_DIR = plugin_dir .. "/assets",

    API_BASE = "http://127.0.0.1:8080",

    REPO_ZENLABS_NAME = "ZenLabs",
    REPO_ZENLABS_URL = "https://repo.zen-labs.org",
    REPO_KINDLEFORGE_NAME = "KindleForge",
    REPO_KINDLEFORGE_URL = "https://kf.penguins184.xyz",

    FEATURED_IDS = { "zen-reader", "kindle-browser", "zen-mtp" },
    PACKAGE_NOTICE_SECONDS = 3,
    POLL_DELAY_SECONDS = 3.5,
    MAX_POLL_RETRIES = 20,
    CONNECT_RETRIES = 40,
    CONNECT_RETRY_DELAY_SECONDS = 0.5,
    CONNECT_INITIAL_DELAY_SECONDS = 0.2,

    DAEMON_UNAVAILABLE_MESSAGE = "ZenPM daemon not reachable. Re-run ZenPM installer if it is not running.",

    TABS = {
        { id = "home", label = "Featured" },
        { id = "categories", label = "Categories" },
        { id = "sources", label = "Sources" },
        { id = "installed", label = "Installed" },
        { id = "debug", label = "Debug" },
        { id = "search", label = "Search" },
    },

    CATEGORIES = {
        { id = "media", label = "Media", icon = "media.svg" },
        { id = "utility", label = "Utility", icon = "utility.svg" },
        { id = "productivity", label = "Productivity", icon = "productivity.svg" },
        { id = "games", label = "Games", icon = "games.svg.svg" },
        { id = "theme", label = "Theme", icon = "theme.svg" },
    },
}
