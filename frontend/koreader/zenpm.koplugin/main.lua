local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Launcher = require("launcher")

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
    Dispatcher:registerAction("zenpm_open", action)
    Dispatcher:registerAction("open_zenpm", action)
end

function ZenPM:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
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

return ZenPM
