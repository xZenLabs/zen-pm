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

local arm64_kobo = Daemon:new()
arm64_kobo.detect_platform = function() return "kobo" end
arm64_kobo.uname_machine = function() return "aarch64" end
arm64_kobo.plugin_version = function() return "1.2.3" end

assert(arm64_kobo:expected_plugin_asset() == "ZenPM-koreader-linux-1.2.3.zip")
assert(arm64_kobo:bundled_backend_candidates()[1] == "/mnt/us/koreader/plugins/zenpm.koplugin/backend/zenpm-linux")

local ereader = Daemon:new()
ereader.detect_platform = function() return "ereader" end
ereader.detect_abi = function() return "hf" end
ereader.plugin_version = function() return "1.2.3" end

assert(ereader:expected_plugin_asset() == "ZenPM-koreader-ereader-1.2.3.zip")
assert(ereader:bundled_backend_candidates()[1] == "/mnt/us/koreader/plugins/zenpm.koplugin/backend/zenpm-hf")

local commands = {}
local original_execute = os.execute
local original_remove = os.remove
os.execute = function(command)
    table.insert(commands, command)
    return 0
end
os.remove = function(path)
    table.insert(commands, "remove " .. path)
    return true
end
daemon.stop_standalone_backend = function() end
assert(daemon:remove_all_settings())
os.execute = original_execute
os.remove = original_remove

assert(table.concat(commands, "\n"):find("rm %-rf '/mnt/us/ZenPM'"))
assert(table.concat(commands, "\n"):find("rm %-rf '/mnt/us/%.ZenPM'"))
assert(table.concat(commands, "\n"):find("remove /mnt/us/documents/ZenPM.sh", 1, true))

print("daemon tests passed")
