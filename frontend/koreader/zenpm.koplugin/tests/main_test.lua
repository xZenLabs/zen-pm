local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local stopped = 0
local uninstalled = 0
local scheduled
local reopened
local actions = {}

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
            }
        end,
    }
end

local original_dofile = dofile
dofile = function(path)
    if path == root .. "/i18n.lua" then return require("i18n") end
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

print("main tests passed")
