local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local settings = {}
local modal_message
local modal_title
local modal_rows
package.preload["socket"] = function() return {} end
package.preload["ui/event"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, callback) callback() end,
    }
end
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
        actions = function(title, rows)
            modal_title = title
            modal_rows = rows
        end,
    }
end
package.preload["models"] = function()
    return {
        has_release_notes = function(pkg, allow_prerelease)
            if allow_prerelease and pkg.prerelease_notes_url then return true end
            return pkg.release_notes_url ~= nil
        end,
        release_notes_url = function(pkg, allow_prerelease)
            if allow_prerelease and pkg.prerelease_notes_url then return pkg.prerelease_notes_url end
            return pkg.release_notes_url
        end,
        is_patch_package = function(pkg) return pkg and pkg.is_patch == true end,
        package_assets = function(pkg) return pkg and pkg.assets or {} end,
        category_for_id = function(id)
            if id == "fonts" then return { id = "fonts", label = "Fonts" } end
            return nil
        end,
        category_cards = function()
            return {
                { id = "fonts", label = "Fonts", count = 2 },
                { id = "games", label = "Games", count = 0 },
            }
        end,
        category_label = function(category) return category.label end,
    }
end
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

local update_result
local trapper_required = false
package.preload["ui/trapper"] = function()
    trapper_required = true
    return {}
end
local trap_widget = { dismiss_callback = function() end }
App.run_update_task({
    daemon = {
        is_android = function() return false end,
        detect_platform = function() return "kobo" end,
    },
}, function()
    return true, true, "1.2.3"
end, trap_widget, function(...)
    update_result = { ... }
end)
assert(update_result[1] == true)
assert(update_result[2] == true)
assert(update_result[3] == true)
assert(update_result[4] == "1.2.3")
assert(trap_widget.dismiss_callback == nil)
assert(not trapper_required)

package.preload["ui/trapper"] = function()
    trapper_required = true
    return {
        wrap = function(_, callback) callback() end,
    }
end
package.loaded["ui/trapper"] = nil
update_result = nil
App.run_update_task({
    daemon = {
        is_android = function() return false end,
        detect_platform = function() return "kindle" end,
    },
}, function()
    return true, true, "1.2.4"
end, nil, function(...)
    update_result = { ... }
end)
assert(update_result[1] == true)
assert(update_result[2] == true)
assert(update_result[3] == true)
assert(update_result[4] == "1.2.4")
assert(trapper_required)

local release_requests = 0
local release_app = {
    state = {
        beta_updates = true,
        current_package = {
            id = "reader",
            prerelease_notes_url = "https://repo.example/reader/PRERELEASE_NOTES.md",
            prerelease_version = "v2.0-beta",
        },
        details_tab = "readme",
        release_notes_cache = {},
    },
    client = {
        get_package_release_notes = function(_, _, prerelease)
            release_requests = release_requests + 1
            assert(prerelease)
            return true, {
                release_notes = "Beta notes",
                version = "v2.0-beta",
                release_notes_base_url = "https://repo.example/reader/",
                release_notes_image_base_url = "https://github.com/owner/reader/raw/HEAD/",
            }
        end,
    },
    load_package_release_notes = App.load_package_release_notes,
    reset_scroll = function() end,
    refresh = function() end,
}
App.set_package_details_tab(release_app, "release_notes")
assert(release_app.state.details_tab == "release_notes")
assert(release_app.state.current_package.release_notes == "Beta notes")
assert(release_app.state.current_package.release_notes_tag == "v2.0-beta")
assert(release_app.state.current_package.release_notes_base_url == "https://repo.example/reader/")
App.set_package_details_tab(release_app, "readme")
App.set_package_details_tab(release_app, "release_notes")
assert(release_requests == 1)

local selected_category
local category_app = {
    state = {
        filters = { installed = "" },
        installed_packages = {},
    },
    set_installed_category_filter = function(_, value)
        selected_category = value
    end,
}
App.prompt_installed_category_filter(category_app)
assert(modal_title == "Filter by category")
assert(#modal_rows == 2)
assert(modal_rows[1].text == "All categories")
assert(modal_rows[2].text == "Fonts (2)")
modal_rows[2].callback()
assert(selected_category == "fonts")

print("app tests passed")
