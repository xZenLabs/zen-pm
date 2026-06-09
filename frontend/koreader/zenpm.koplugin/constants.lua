local source = debug.getinfo(1, "S").source or ""
local plugin_dir = source:match("^@(.+)/constants%.lua$") or "plugins/zenpm.koplugin"
return {
    PLUGIN_DIR = plugin_dir,
    ASSET_DIR = plugin_dir .. "/assets",

    API_BASE = "http://127.0.0.1:8080",

    REPO_ZENLABS_NAME = "ZenLabs",
    REPO_ZENLABS_URL = "https://xzenlabs.github.io/repo",
    REPO_KINDLEFORGE_NAME = "KindleForge",
    REPO_KINDLEFORGE_URL = "https://kf.penguins184.xyz",

    FEATURED_IDS = { "zen-reader", "kindle-browser", "zen-mtp" },
    POLL_DELAY_SECONDS = 3.5,
    MAX_POLL_RETRIES = 20,
    CONNECT_RETRIES = 8,
    CONNECT_RETRY_DELAY_SECONDS = 3,

    DAEMON_UNAVAILABLE_MESSAGE = "ZenPM daemon not reachable. Re-run ZenPM installer if it is not running.",

    TABS = {
        { id = "home", label = "Featured" },
        { id = "sources", label = "Sources" },
        { id = "installed", label = "Installed" },
        { id = "debug", label = "Debug" },
        { id = "search", label = "Search" },
    },
}
