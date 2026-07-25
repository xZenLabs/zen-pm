local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local settings = {}
local modal_message
package.preload["socket"] = function() return {} end
package.preload["ui/event"] = function() return {} end
package.preload["ui/uimanager"] = function() return {} end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ui/app_view"] = function() return {} end
package.preload["bugreporter"] = function() return {} end
package.preload["constants"] = function()
    return { PLUGIN_DIR = root, PACKAGE_ERROR_NOTICE_SECONDS = 1 }
end
package.preload["daemon"] = function() return { state_home = function() return "/tmp" end } end
package.preload["i18n"] = function() return {} end
package.preload["ui/images"] = function() return {} end
package.preload["ui/modals"] = function()
    return {
        info = function(message) modal_message = message end,
        info_for = function(message) modal_message = message end,
        status = function() end,
        close_status = function() end,
    }
end
package.preload["models"] = function() return {} end
package.preload["ui/theme"] = function() return {} end
package.preload["updater"] = function() return {} end
package.preload["zenpm_util"] = function() return {} end
package.preload["luasettings"] = function()
    return {
        open = function()
            return {
                readSetting = function(_, key) return settings[key] end,
                saveSetting = function(_, key, value) settings[key] = value end,
                flush = function() end,
            }
        end,
    }
end

local original_dofile = dofile
dofile = function(path)
    if path == root .. "/client.lua" then return {} end
    return original_dofile(path)
end
local App = require("app")
dofile = original_dofile

local checks = 0
local app = {
    state = { beta_updates = false, update_auto_check = true, update_available = true },
    set_update_available = App.set_update_available,
    schedule_automatic_update_check = function() checks = checks + 1 end,
}

App.toggle_beta_updates(app)

assert(app.state.beta_updates)
assert(not app.state.update_available)
assert(settings.beta_updates == true)
assert(settings.last_update_check == 0)
assert(checks == 1)

local about_app = {
    daemon = {
        installed_backend_version = function() return "1.2.3" end,
        detect_platform = function() return "ereader" end,
        ereader_backend_suffix = function() return "sf" end,
    },
    package_platforms = function() return "ereader,koreader" end,
}
App.show_about(about_app)
assert(modal_message:find("Version: 1.2.3", 1, true))
assert(modal_message:find("ABI: sf", 1, true))

modal_message = nil
App.refresh_repos({
    client = {
        refresh_repos = function()
            return false, "ZenPM backend returned HTTP 500: upstream returned HTTP 403", 500
        end,
    },
})
assert(modal_message == "Refresh failed (HTTP 403)")

print("app tests passed")
