local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Launcher = require("launcher")
local Constants = require("constants")
local I18n = dofile(Constants.PLUGIN_DIR .. "/i18n.lua")
I18n.install()
local Daemon = require("daemon")
local Client = dofile(Constants.PLUGIN_DIR .. "/client.lua")

local function plugin_root()
    local source = debug.getinfo(1, "S").source or ""
    local path = source:sub(1, 1) == "@" and source:sub(2):match("^(.*)/main%.lua$") or nil
    if path and path:sub(1, 1) ~= "/" then
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        local cwd = ok and lfs and lfs.currentdir()
        if cwd then path = cwd .. "/" .. path end
    end
    return path
end

local function register_nerd_font()
    local root = plugin_root()
    if not root then return end
    local Font = require("ui/font")
    local FontList = require("fontlist")
    local font_name = "ZenPMSymbolsNerdFont-Regular.ttf"
    local font_path = root .. "/fonts/" .. font_name

    FontList:getFontList()
    for _, path in ipairs(FontList.fontlist) do
        if path == font_path then
            font_path = nil
            break
        end
    end
    if font_path then
        table.insert(FontList.fontlist, font_path)
    end
    for _, fallback in ipairs(Font.fallbacks) do
        if fallback == font_name then return end
    end
    table.insert(Font.fallbacks, font_name)
end

local function use_zen_confirmation_icon()
    local IconWidget = require("ui/widget/iconwidget")
    if IconWidget.__zenpm_confirmation_icon_patched then return end
    IconWidget.__zenpm_confirmation_icon_patched = true

    local init = IconWidget.init
    function IconWidget:init()
        init(self)
        if self.icon == "notice-question" then
            self.file = Constants.ASSET_DIR .. "/zen.svg"
        end
    end
end

local ZenPM = WidgetContainer:extend{
    name = "zenpm",
    is_doc_only = false,
}

function ZenPM:onDispatcherRegisterActions()
    Dispatcher:registerAction("zenpm", {
        category = "none",
        event = "OpenZenPM",
        title = _("Open ZenPM"),
        general = true,
    })
    Dispatcher:registerAction("zenpm_update_all", {
        category = "none",
        event = "UpdateAllZenPMPlugins",
        title = _("Update All"),
        general = true,
    })
end

function ZenPM:init()
    I18n.install()
    pcall(register_nerd_font)
    use_zen_confirmation_icon()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    local daemon = Daemon:new()
    daemon:log_cli("plugin loaded; ensuring CLI wrapper")
    local ok, result, err = pcall(daemon.ensure_backend_files, daemon)
    if not ok then
        daemon:log_cli("CLI setup crashed: " .. tostring(result))
    elseif err then
        daemon:log_cli("CLI setup failed: " .. tostring(err))
    end
end

function ZenPM:onOpenZenPM()
    return Launcher.open(self)
end

function ZenPM:onUpdateAllZenPMPlugins()
    local daemon = Daemon:new()
    local client = Client:new()
    local ready, err = daemon:ensure(client)
    if not ready then
        daemon:log_cli("dispatcher update all failed to start backend: " .. tostring(err))
        return false
    end
    local started, result = client:update_all_packages()
    if not started then
        daemon:log_cli("dispatcher update all failed: " .. tostring(result))
    end
    return started
end

function ZenPM:onZenPM()
    return Launcher.open(self)
end

function ZenPM:onZenpm()
    return Launcher.open(self)
end

function ZenPM:addToMainMenu(menu_items)
    menu_items.zenpm = {
        text = _("ZenPM"),
        callback = function()
            Launcher.open(self)
        end,
    }
end

function ZenPM.open(plugin)
    return Launcher.open(plugin)
end

function ZenPM:onCloseWidget()
    -- USB mass storage unmounts Kobo's onboard filesystem immediately after
    -- KOReader closes. Stop the backend first so it cannot keep that storage
    -- busy and block the handoff.
    Daemon:new():stop_standalone_backend()
    I18n.uninstall()
end

-- KOReader calls this only after the user selects “Remove settings” while
-- disabling or uninstalling the plugin.
function ZenPM:deletePluginSettings()
    local ok, removed = pcall(function()
        return Daemon:new():remove_all_settings()
    end)
    return ok and removed
end

return ZenPM
