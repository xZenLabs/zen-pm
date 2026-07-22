local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

package.preload["socket"] = function() return {} end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["constants"] = function() return { PLUGIN_DIR = "/mnt/us/koreader/plugins/zenpm.koplugin" } end
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "./settings" end,
        getFullDataDir = function() return "/mnt/us/koreader" end,
    }
end

local Daemon = require("daemon")
local daemon = Daemon:new()
local wrappers = {}

daemon.detect_platform = function() return "kindle" end
daemon.remove_cli_wrapper = function() return true end
daemon.write_cli_wrapper = function(_, path, script)
    wrappers[path] = script
    return true
end

assert(daemon:install_cli_wrapper())
local wrapper = assert(wrappers["/usr/local/bin/zenpm"])
assert(wrapper:find("export ZENPM_HOME='/mnt/us/koreader/settings/ZenPM'", 1, true))
assert(wrapper:find("exec '/mnt/us/koreader/settings/ZenPM/backend/zenpm' \"$@\"", 1, true))

print("daemon tests passed")
