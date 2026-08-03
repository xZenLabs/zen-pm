local Launcher = {
    app = nil,
}

-- KOReader keeps one global Lua module cache for all plugins. Register our
-- app under a ZenPM-specific name so another plugin's app.lua cannot replace it.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_dir = assert(source:match("^(.*)/[^/]+$"))
if not package.preload["zenpm_app"] then
    package.preload["zenpm_app"] = function()
        return dofile(plugin_dir .. "/app.lua")
    end
end

local function app_module()
    return require("zenpm_app")
end

function Launcher.get_app(plugin)
    if not Launcher.app then
        local App = app_module()
        Launcher.app = App:new(plugin)
        Launcher.app.quit = function(app)
            app:close()
            Launcher.app = nil
        end
    elseif plugin then
        Launcher.app.plugin = plugin
    end
    return Launcher.app
end

function Launcher.open(plugin)
    Launcher.get_app(plugin):show()
    return true
end

function Launcher.open_after_restart(plugin)
    local App = app_module()
    if not App.consume_reopen_after_restart() then return false end
    return Launcher.open(plugin)
end

function Launcher.quit()
    if Launcher.app then
        Launcher.app:close()
        Launcher.app = nil
    end
    return true
end

return Launcher
