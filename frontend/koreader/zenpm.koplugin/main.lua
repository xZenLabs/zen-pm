local I18n = require("i18n")
I18n.install()

local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Launcher = require("launcher")

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

local ZenPM = WidgetContainer:extend{
    name = "zenpm",
    is_doc_only = false,
}

function ZenPM:onDispatcherRegisterActions()
    local action = {
        category = "none",
        event = "OpenZenPM",
        title = _("Open ZenPM"),
        general = true,
    }
    Dispatcher:registerAction("zenpm", action)
end

function ZenPM:init()
    I18n.install()
    pcall(register_nerd_font)
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    pcall(function()
        require("daemon"):new():ensure_backend_files()
    end)
end

function ZenPM:onOpenZenPM()
    return Launcher.open(self)
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
    I18n.uninstall()
end

return ZenPM
