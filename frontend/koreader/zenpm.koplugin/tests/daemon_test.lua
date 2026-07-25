local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

package.preload["socket"] = function() return {} end
package.preload["gettext"] = function() return function(value) return value end end
local constants = { PLUGIN_DIR = "/mnt/us/koreader/plugins/zenpm.koplugin" }
package.preload["constants"] = function() return constants end
local datastorage = {
    getSettingsDir = function() return "./settings" end,
    getFullDataDir = function() return "/mnt/us/koreader" end,
}
package.preload["datastorage"] = function() return datastorage end

local Daemon = require("daemon")
local daemon = Daemon:new()
local wrappers = {}

daemon.detect_platform = function() return "kindle" end
daemon.remove_cli_wrapper = function() return true end
daemon.write_cli_wrapper = function(_, path, script)
    wrappers[path] = script
    return true
end

daemon.kindle_firmware_version = function() return "5.18.3" end
assert(daemon:kindle_homepage_install_supported())
daemon.kindle_firmware_version = function() return "5.18.3.1" end
assert(not daemon:kindle_homepage_install_supported())
daemon.kindle_firmware_version = function() return "5.19.0" end
assert(not daemon:kindle_homepage_install_supported())

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

local socket = require("socket")
local original_tcp = socket.tcp
local original_execute = os.execute
local loopback_commands = {}
local probe_closed = false
socket.tcp = function()
    return {
        bind = function(_, host) return host == "127.0.0.1" end,
        close = function() probe_closed = true end,
    }
end
os.execute = function(command)
    table.insert(loopback_commands, command)
    return 0
end
assert(ereader:wait_for_loopback())
socket.tcp = original_tcp
os.execute = original_execute
assert(probe_closed)
assert(loopback_commands[1] == "ifconfig lo 127.0.0.1 >/dev/null 2>&1")

constants.PLUGIN_DIR = "/mnt/ext1/applications/koreader/plugins-user/zenpm.koplugin"
local user_plugin = Daemon:new()
assert(user_plugin:koreader_plugin_dir() == "/mnt/ext1/applications/koreader/plugins-user")
datastorage.getFullDataDir = function() return "" end
assert(user_plugin:koreader_data_dir() == "/mnt/ext1/applications/koreader")
datastorage.getFullDataDir = function() return "/mnt/us/koreader" end
constants.PLUGIN_DIR = "/mnt/us/koreader/plugins/zenpm.koplugin"

local source_path = os.tmpname()
local source_file = assert(io.open(source_path, "wb"))
source_file:write("backend")
source_file:close()

local no_wrapper = Daemon:new()
no_wrapper.ensure_runtime_dirs = function() return false, nil end
no_wrapper.bundled_backend = function() return source_path end
no_wrapper.standalone_backend_dir = function() return source_path .. ".backend" end
no_wrapper.bundled_backend_version = function() return "1.2.3" end
no_wrapper.desired_marker = function() return "marker\n" end
no_wrapper.bundled_backend_companions = function() return {} end
no_wrapper.install_cli_wrapper = function() return false end
no_wrapper.log_cli = function() end
no_wrapper.stop_standalone_backend = function() end

local changed, prepare_err = no_wrapper:ensure_backend_files()
assert(changed and not prepare_err)
local installed_backend = assert(io.open(no_wrapper:standalone_backend(), "rb"))
installed_backend:close()

changed, prepare_err = no_wrapper:ensure_backend_files()
assert(not changed and not prepare_err)

os.remove(source_path)
os.remove(no_wrapper:standalone_backend())
os.remove(no_wrapper:standalone_backend_dir() .. "/VERSION")
os.remove(no_wrapper:standalone_marker())
os.execute("rmdir " .. no_wrapper:standalone_backend_dir())

local commands = {}
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
