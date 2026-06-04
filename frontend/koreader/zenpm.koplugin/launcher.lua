local Launcher = {
    app = nil,
}

function Launcher.get_app(plugin)
    if not Launcher.app then
        local App = require("app")
        Launcher.app = App:new(plugin)
    elseif plugin then
        Launcher.app.plugin = plugin
    end
    return Launcher.app
end

function Launcher.open(plugin)
    Launcher.get_app(plugin):show()
    return true
end

return Launcher
