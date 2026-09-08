local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local stopped = 0
local uninstalled = 0
local scheduled
local reopened
local actions = {}
local update_events = {}
local close_ok = true
local network_connected = true
local network_retry_callback

package.preload["i18n"] = function()
    return {
        install = function() end,
        uninstall = function() uninstalled = uninstalled + 1 end,
    }
end
package.preload["dispatcher"] = function()
    return {
        registerAction = function(_, name, action)
            actions[name] = action
        end,
    }
end
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_, callback) scheduled = callback end }
end
package.preload["ui/network/manager"] = function()
    return {
        willRerunWhenConnected = function(_, callback)
            if network_connected then return false end
            network_retry_callback = callback
            return true
        end,
    }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_, prototype) return prototype end }
end
package.preload["ui/widget/iconwidget"] = function() return { init = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["json"] = function() return {} end
package.preload["socket.http"] = function() return {} end
package.preload["ltn12"] = function() return {} end
package.preload["socket"] = function() return { gettime = function() return 0 end } end
package.preload["launcher"] = function()
    return {
        open = function() return true end,
        open_after_restart = function(plugin) reopened = plugin end,
        get_app = function()
            return {
                close_book_before_update = function()
                    table.insert(update_events, "close")
                    return close_ok, "backend unavailable"
                end,
                daemon = { log_cli = function() end },
            }
        end,
    }
end
-- KOReader shares package.loaded across plugins. A generic module cached by
-- another plugin must not replace ZenPM's constants.
package.loaded["constants"] = {}
package.loaded["zenpm_constants"] = nil
local Constants = require("zenpm_constants")
assert(Constants.PLUGIN_DIR == root)
package.preload["daemon"] = function()
    return {
        new = function()
            return {
                stop_standalone_backend = function() stopped = stopped + 1 end,
                log_cli = function() end,
                ensure_backend_files = function() end,
                ensure = function()
                    table.insert(update_events, "ensure")
                    return true
                end,
            }
        end,
    }
end

local original_dofile = dofile
dofile = function(path)
    if path == root .. "/i18n.lua" then return require("i18n") end
    if path == root .. "/client.lua" then
        return { new = function()
            return { update_all_packages = function()
                table.insert(update_events, "update")
                return true
            end }
        end }
    end
    return original_dofile(path)
end
local ZenPM = dofile(root .. "/main.lua")
dofile = original_dofile
ZenPM.ui = { menu = { registerToMainMenu = function() end } }
ZenPM:init()
assert(actions.zenpm.title == "ZenPM: Open")
assert(actions.zenpm_update_all.title == "ZenPM: Update All")
assert(scheduled)
scheduled()
assert(reopened == ZenPM)
ZenPM:onCloseWidget()

assert(stopped == 1)
assert(uninstalled == 1)

network_connected = false
assert(ZenPM:onUpdateAllZenPMPlugins())
assert(#update_events == 0 and type(network_retry_callback) == "function")
network_connected = true
network_retry_callback()
assert(table.concat(update_events, ",") == "close,ensure,update")
update_events = {}
close_ok = false
assert(not ZenPM:onUpdateAllZenPMPlugins())
assert(table.concat(update_events, ",") == "close")

print("main tests passed")
