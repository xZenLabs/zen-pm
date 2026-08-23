local source = debug.getinfo(1, "S").source or ""
local plugin_dir = source:match("^@(.+)/constants%.lua$") or "plugins/zenpm.koplugin"
local api_port = 18765
local function N_(value) return value end
return {
    PLUGIN_DIR = plugin_dir,
    ASSET_DIR = plugin_dir .. "/assets",

    PORT = api_port,
    API_BASE = "http://127.0.0.1:" .. api_port,
    UNIX_SOCKET = "/tmp/zenpm.sock",

    REPO_ZENLABS_NAME = "ZenLabs",
    REPO_ZENLABS_DISPLAY = N_("ZenLabs Repo"),
    REPO_ZENLABS_URL = "https://repo.zen-labs.org",
    REPO_KINDLEFORGE_NAME = "KindleForge",
    REPO_KINDLEFORGE_URL = "https://kf.penguins184.xyz",

    FEATURED_IDS = { "zen-reader", "kindle-browser", "zen-mtp" },
    PACKAGE_NOTICE_SECONDS = 3,
    PACKAGE_ERROR_NOTICE_SECONDS = 10,
    POLL_DELAY_SECONDS = 3.5,
    MAX_POLL_RETRIES = 20,
    PACKAGE_ACTION_MAX_POLL_RETRIES = 45,
    CONNECT_RETRIES = 40,
    CONNECT_RETRY_DELAY_SECONDS = 0.5,
    CONNECT_INITIAL_DELAY_SECONDS = 0.2,
    ANDROID_BACKEND_HEALTH_INTERVAL_SECONDS = 60,

    DAEMON_UNAVAILABLE_MESSAGE = N_("ZenPM daemon not reachable. Re-run ZenPM installer if it is not running."),

    TABS = {
        { id = "home", label = N_("Featured") },
        { id = "changes", label = N_("Changes") },
        { id = "categories", label = N_("Categories") },
        { id = "installed", label = N_("Installed") },
        -- { id = "debug", label = N_("Debug") },
        { id = "search", label = N_("Discover") },
    },

    CATEGORIES = {
        { id = "fonts", label = N_("Fonts"), icon = "fonts.svg" },
        { id = "games", label = N_("Games"), icon = "games.svg" },
        { id = "media", label = N_("Media"), icon = "media.svg" },
        { id = "koreader-patches", label = N_("Patches"), icon = "patch.svg" },
        { id = "productivity", label = N_("Productivity"), icon = "productivity.svg" },
        { id = "theme", label = N_("Theme"), icon = "theme.svg" },
        { id = "utility", label = N_("Utility"), icon = "utility.svg" },
    },
    KINDLE_SCRIPTLETS_CATEGORY = {
        id = "kindle-scriptlets",
        label = N_("Kindle Scriptlets"),
        icon = "kindleforge.svg",
    },
}
