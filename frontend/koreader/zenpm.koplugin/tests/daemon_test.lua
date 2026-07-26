local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

package.preload["socket"] = function() return {} end
package.preload["gettext"] = function() return function(value) return value end end
local constants = {
    PLUGIN_DIR = "/mnt/us/koreader/plugins/zenpm.koplugin",
    PORT = 18765,
    POCKETBOOK_SOCKET = "/tmp/zenpm.sock",
}
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
daemon.kindle_kpm_installed = function() return false end

daemon.kindle_firmware_version = function() return "5.18.3" end
assert(daemon:kindle_homepage_install_supported())
daemon.kindle_firmware_version = function() return "5.18.3.1" end
assert(not daemon:kindle_homepage_install_supported())
daemon.kindle_firmware_version = function() return "5.19.0" end
assert(not daemon:kindle_homepage_install_supported())
daemon.kindle_firmware_version = function() return "5.18.3" end
daemon.kindle_kpm_installed = function() return true end
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
local generic_probe_called = false
socket.tcp = function()
    generic_probe_called = true
end
os.execute = function(command)
    table.insert(loopback_commands, command)
    return 0
end
assert(ereader:wait_for_loopback())
assert(not generic_probe_called)
assert(#loopback_commands == 0)

local pocketbook = Daemon:new()
pocketbook.detect_platform = function() return "ereader" end
pocketbook.is_pocketbook = function() return true end
pocketbook.detect_abi = function() return "hf" end
assert(pocketbook:ereader_backend_suffix() == "sf")
socket.tcp = function()
    error("PocketBook should not probe TCP loopback")
end
os.execute = function(command)
    table.insert(loopback_commands, command)
    return 0
end
assert(pocketbook:wait_for_loopback())
socket.tcp = original_tcp
os.execute = original_execute
assert(#loopback_commands == 0)

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

local tcp_backend = Daemon:new()
tcp_backend.detect_platform = function() return "ereader" end
tcp_backend.wait_for_loopback = function() return true end
tcp_backend.find_backend = function() return source_path end
tcp_backend.log_cli = function() end
local tcp_start_commands = {}
os.execute = function(command)
    table.insert(tcp_start_commands, command)
    return 0
end
assert(tcp_backend:start(true))
os.execute = original_execute
assert(#tcp_start_commands == 1)
assert(tcp_start_commands[1]:find("serve --port 18765", 1, true))

local stopped_commands = {}
socket.sleep = function() end
os.execute = function(command)
    table.insert(stopped_commands, command)
    return 0
end
tcp_backend.standalone_backend = function() return source_path end
tcp_backend.standalone_pid_file = function() return "" end
tcp_backend.bundled_backend_candidates = function() return {} end
tcp_backend:stop_standalone_backend()
os.execute = original_execute
assert(table.concat(stopped_commands, "\n"):find("serve %-%-port 18765"))
assert(table.concat(stopped_commands, "\n"):find("serve %-%-port 8080"))

local pocketbook_backend = Daemon:new()
pocketbook_backend.ensure_runtime_dirs = function() return false, nil end
pocketbook_backend.bundled_backend = function() return source_path end
pocketbook_backend.bundled_backend_version = function() return "1.2.3" end
pocketbook_backend.is_pocketbook = function() return true end
pocketbook_backend.install_cli_wrapper = function()
    error("PocketBook should not install a copied backend wrapper")
end

local saved_execute = os.execute
os.execute = function()
    error("PocketBook should not chmod or copy the bundled backend")
end
local pocketbook_changed, pocketbook_prepare_err = pocketbook_backend:ensure_backend_files()
os.execute = saved_execute
assert(not pocketbook_changed and not pocketbook_prepare_err)
assert(pocketbook_backend.backend_path == source_path)
assert(pocketbook_backend:installed_backend_version() == "1.2.3")

local start_commands = {}
local start_logs = {}
pocketbook_backend.detect_platform = function() return "ereader" end
pocketbook_backend.wait_for_loopback = function() return true end
pocketbook_backend.bundled_backend_dir = function()
    return assert(source_path:match("^(.*)/[^/]+$"))
end
pocketbook_backend.log_cli = function(_, message)
    table.insert(start_logs, message)
end
os.execute = function(command)
    table.insert(start_commands, command)
    return 0
end
assert(pocketbook_backend:start(true))
os.execute = saved_execute
assert(#start_commands == 1)
assert(start_commands[1]:find("exec '" .. source_path .. "' serve --socket '/tmp/zenpm.sock'", 1, true))
assert(start_commands[1]:find("ZENPM_HOME='./settings/ZenPM'", 1, true))
assert(start_logs[1]:find("starting backend " .. source_path, 1, true))
assert(start_logs[1]:find("abi=sf", 1, true))

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

package.loaded["daemon"] = nil
package.preload["android"] = function()
    return {
        getExternalStoragePath = function() return "/storage/emulated/0" end,
        openLink = function() return false end,
    }
end
local AndroidDaemon = require("daemon")
local android_daemon = AndroidDaemon:new()
android_daemon.state_home = function() return "/storage/emulated/0/ZenPM" end
android_daemon.koreader_root = function() return "/storage/emulated/0/koreader" end
local android_commands = {}
os.execute = function(command)
    table.insert(android_commands, command)
    return 0
end
assert(android_daemon:start(true))
os.execute = original_execute
assert(#android_commands == 1)
local android_command = android_commands[1]
assert(android_command:find("/system/bin/am start -W -n org.zenlabs.zenpm/.ZenPMActivity -a android.intent.action.VIEW -d 'zenpm://start?home=%2Fstorage%2Femulated%2F0%2FZenPM&root=%2Fstorage%2Femulated%2F0%2Fkoreader'", 1, true))
assert(android_command:find("--es zenpm_log_home '/storage/emulated/0/ZenPM'", 1, true))

print("daemon tests passed")
