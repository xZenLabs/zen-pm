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
    Launcher.get_app(plugin):show()
    return true
end

function Launcher.open_after_restart(plugin)
    local App = require("app")
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
