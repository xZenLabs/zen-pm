local Device = require("device")
local Daemon = require("daemon")

local Launcher = {
    app = nil,
}

function Launcher.get_app(plugin)
    if not Launcher.app then
        local App = require("app")
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
    if Device:isPocketBook() then
        local NetworkMgr = require("ui/network/manager")
        if not Daemon:new():loopback_ready() and not NetworkMgr:isConnected() then
            NetworkMgr:runWhenConnected(function()
                Launcher.open(plugin)
            end)
            return true
        end
    end
    Launcher.get_app(plugin):show()
    return true
end

function Launcher.quit()
    if Launcher.app then
        Launcher.app:close()
        Launcher.app = nil
    end
    return true
end

return Launcher
