local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local settings = {}
local modal_message
local modal_seconds
local restart_message
local restart_callback
local restart_actions = {}
local status_message
local modal_title
local modal_rows
local plugin_settings_prompt
local package_modify_callbacks
local updater_reinstall_requests = 0
local logged_warnings = {}
package.preload["socket"] = function() return {} end
package.preload["ui/event"] = function()
    return { new = function(_, name) return name end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        nextTick = function(_, callback) callback() end,
        scheduleIn = function(_, _, callback) callback() end,
        forceRePaint = function() table.insert(restart_actions, "paint") end,
        broadcastEvent = function(_, event) table.insert(restart_actions, event) end,
    }
end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function()
    return {
        warn = function(message) table.insert(logged_warnings, message) end,
    }
end
package.preload["ui/app_view"] = function() return {} end
package.preload["bugreporter"] = function() return {} end
package.preload["constants"] = function()
    return { PLUGIN_DIR = root, PACKAGE_ERROR_NOTICE_SECONDS = 1 }
end
package.preload["daemon"] = function() return { state_home = function() return "/tmp" end } end
package.preload["i18n"] = function() return {} end
package.preload["ui/images"] = function()
    return {
        asset = function(name) return "assets/" .. name end,
        invalidate_cache = function() end,
    }
end
package.preload["ui/modals"] = function()
    return {
        info = function(message) modal_message = message end,
        info_for = function(message, seconds)
            modal_message = message
            modal_seconds = seconds
        end,
        restart_koreader = function(message, callback)
            restart_message = message
            restart_callback = callback
        end,
        status = function(message) status_message = message end,
        close_status = function() end,
        actions = function(title, rows)
            modal_title = title
            modal_rows = rows
        end,
        package_modify = function(_, callbacks)
            package_modify_callbacks = callbacks
        end,
        plugin_settings_cleanup = function(message, callback)
            plugin_settings_prompt = message
            callback(true)
        end,
    }
end
package.preload["models"] = function()
    return {
        has_release_notes = function(pkg, allow_prerelease)
            if allow_prerelease and pkg.prerelease_notes_url then return true end
            return pkg.release_notes_url ~= nil
        end,
        has_readme = function(pkg) return pkg and pkg.readme_url ~= nil end,
        release_notes_url = function(pkg, allow_prerelease)
            if allow_prerelease and pkg.prerelease_notes_url then return pkg.prerelease_notes_url end
            return pkg.release_notes_url
        end,
        is_patch_package = function(pkg) return pkg and pkg.is_patch == true end,
        is_installed_patch_item = function() return false end,
        is_unmanaged_patch = function() return false end,
        is_font_package = function() return false end,
        has_version_history = function(pkg) return pkg and pkg.versions_url ~= nil end,
        find_package = function(packages, id)
            for _, pkg in ipairs(packages or {}) do
                if pkg.id == id then return pkg end
            end
        end,
        package_display_name = function(pkg, fallback)
            return pkg and (pkg.name or pkg.id) or fallback
        end,
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
package.preload["updater"] = function()
    return {
        update = function()
            return true, "1.2.4-beta3"
        end,
        reinstall = function(_, _, tag, allow_prerelease, force_refresh)
            updater_reinstall_requests = updater_reinstall_requests + 1
            assert(tag == "v1.2.3")
            assert(not allow_prerelease)
            assert(force_refresh)
            return true, "1.2.3"
        end,
    }
end
package.preload["zenpm_util"] = function()
    return {
        trim = function(value)
            return tostring(value or ""):match("^%s*(.-)%s*$")
        end,
    }
end
local local_plugin_cleanup_calls = 0
package.preload["pluginloader"] = function()
    return {
        loaded_plugins = {
            {
                path = "/tmp/local-plugin.koplugin",
                deletePluginSettings = function()
                    local_plugin_cleanup_calls = local_plugin_cleanup_calls + 1
                end,
            },
        },
    }
end
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

local app = {
    state = { beta_updates = false },
}

App.toggle_beta_updates(app)

assert(app.state.beta_updates)
assert(settings.beta_updates == true)

local zenpm_package = { id = "zenpm-koreader" }
assert(App.package_icon_file({}, zenpm_package) == "assets/zenpm.svg")

local release_requests = 0
local zenpm_versions = App.load_package_releases({
    state = { beta_updates = false },
    client = {
        get_package_releases = function(_, id)
            release_requests = release_requests + 1
            assert(id == "zenpm-koreader")
            return true, {
                releases = {
                    { tag_name = "v1.2.3" },
                },
            }
        end,
    },
}, zenpm_package)
assert(release_requests == 1)

local failed_release_app = {
    state = {
        beta_updates = false,
        release_notes_cache = {},
    },
    client = {
        get_package_release_notes = function()
            return false, "ZenPM backend returned HTTP 502: README request returned HTTP 404", 502
        end,
    },
}
local failed_release = {
    id = "reader",
    release_notes_url = "https://repo.example/reader/RELEASE_NOTES.md",
}
App.load_package_release_notes(failed_release_app, failed_release)
assert(failed_release.release_notes == "")
assert(failed_release.release_notes_error_code == 404)
assert(logged_warnings[#logged_warnings]:find("could not load release notes", 1, true))

local failed_readme_app = {
    state = {
        page = "search",
        active_tab = "search",
        beta_updates = false,
        readme_cache = {},
    },
    ensure_backend = function() return true end,
    load_packages = function()
        return true, {
            { id = "reader", readme_url = "https://repo.example/reader/README.md" },
        }
    end,
    client = {
        get_package_readme = function()
            return false, "connection timed out"
        end,
    },
    reset_scroll = function() end,
    clear_status = function() end,
    refresh = function() end,
}
App.show_package_details(failed_readme_app, "reader")
assert(failed_readme_app.state.current_package.readme_error_code == nil)
assert(failed_readme_app.state.readme_cache.reader == nil)
assert(logged_warnings[#logged_warnings]:find("could not load README", 1, true))
assert(zenpm_versions[1].tag_name == "v1.2.3")

local about_app = {
    daemon = {
        plugin_version = function() error("About must not use the plugin version") end,
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
local failed_refresh_app = {
    state = {
        readme_cache = { reader = { readme = "Cached README" } },
    },
    client = {
        refresh_repos = function()
            return false, "ZenPM backend returned HTTP 500: upstream returned HTTP 403", 500
        end,
    },
}
App.refresh_repos(failed_refresh_app)
assert(modal_message == "Refresh failed (HTTP 403)")
assert(failed_refresh_app.state.readme_cache.reader.readme == "Cached README")

local refreshed_app = {
    state = {
        readme_cache = { reader = { readme = "Cached README" } },
    },
    client = {
        refresh_repos = function() return true end,
    },
    load_packages = function() return true, {} end,
    load_repos = function() end,
    reload_current_page = function() end,
}
App.refresh_repos(refreshed_app)
assert(next(refreshed_app.state.readme_cache) == nil)

local open_refreshes = 0
local open_catalog_reloads = 0
local opened_app = {
    backend_ready = true,
    view = {},
    state = {
        readme_cache = { reader = { readme = "Cached README" } },
    },
    client = {
        refresh_repos = function()
            open_refreshes = open_refreshes + 1
            return true
        end,
    },
    run_update_task = function(_, task, _, callback)
        local called, ok = task()
        callback(true, called, ok)
    end,
    load_packages = function() end,
    load_repos = function() end,
    reload_current_page = function() open_catalog_reloads = open_catalog_reloads + 1 end,
}
App.refresh_catalog_on_open(opened_app)
assert(open_refreshes == 1)
assert(next(opened_app.state.readme_cache) == nil)
assert(open_catalog_reloads == 1)

local shown_catalog_refreshes = 0
App.show({
    view = {},
    backend_ready = true,
    state = { active_tab = "home" },
    intercept_koreader_exit = function() end,
    finish_deferred_font_uninstalls = function() end,
    navigate = function() end,
    schedule_plugin_scan_after_open = function() end,
    refresh_catalog_on_open = function() shown_catalog_refreshes = shown_catalog_refreshes + 1 end,
})
assert(shown_catalog_refreshes == 1)

local started_catalog_refreshes = 0
App.backend_started({
    state = {},
    finish_deferred_font_uninstalls = function() end,
    clear_status = function() end,
    refresh = function() end,
    schedule_plugin_scan_after_open = function() end,
    refresh_catalog_on_open = function() started_catalog_refreshes = started_catalog_refreshes + 1 end,
}, {})
assert(started_catalog_refreshes == 1)

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

local self_update_queued = 0
local self_action_app = {
    queue_self_update = function() self_update_queued = self_update_queued + 1 end,
}
App.start_package_action(self_action_app, { id = "zenpm-koreader", plugin_module = "zenpm" }, "update")
assert(self_update_queued == 1)

App.queue_package_action({
    state = { queue_running = false },
    queue_self_update = function() self_update_queued = self_update_queued + 1 return true end,
}, { id = "zenpm-koreader", plugin_module = "zenpm" }, "update")
assert(self_update_queued == 2)

local companion_update_requests = 0
local reinstalled_scan_calls = 0
local reinstalled_backend_restarts = 0
local reinstalled_result
App.apply_update({
    state = { beta_updates = false },
    daemon = {
        is_android = function() return true end,
        request_android_update = function()
            companion_update_requests = companion_update_requests + 1
            return true
        end,
        stop_standalone_backend = function() end,
    },
    client = {
        scan_installed_plugins = function()
            reinstalled_scan_calls = reinstalled_scan_calls + 1
            return true
        end,
    },
    start_backend_then_reload = function()
        reinstalled_backend_restarts = reinstalled_backend_restarts + 1
    end,
    run_update_task = function(_, task, _, callback)
        local called, ok, result = task()
        callback(true, called, ok, result)
    end,
}, "v1.2.3", function(...)
    reinstalled_result = { ... }
end)
assert(companion_update_requests == 1)
assert(updater_reinstall_requests == 1)
assert(reinstalled_scan_calls == 1)
assert(reinstalled_backend_restarts == 1)
assert(reinstalled_result[1] == true and reinstalled_result[2] == "1.2.3")

local updated_scan_calls = 0
local updated_backend_restarts = 0
local updated_result
App.apply_update({
    state = { beta_updates = false },
    daemon = {
        is_android = function() return false end,
        stop_standalone_backend = function() end,
    },
    client = {
        scan_installed_plugins = function()
            updated_scan_calls = updated_scan_calls + 1
            return true
        end,
    },
    start_backend_then_reload = function()
        updated_backend_restarts = updated_backend_restarts + 1
    end,
    run_update_task = function(_, task, _, callback)
        local called, ok, result = task()
        callback(true, called, ok, result)
    end,
}, function(...)
    updated_result = { ... }
end)
assert(updated_scan_calls == 1)
assert(updated_backend_restarts == 1)
assert(updated_result[1] == true and updated_result[2] == "1.2.4-beta3")

local selected_zenpm_release
App.confirm_package_version({
    queue_self_reinstall = function(_, _, release)
        selected_zenpm_release = release
    end,
}, { id = "zenpm-koreader", installed = true }, "v1.2.3", "reinstall")
assert(selected_zenpm_release == "v1.2.3")

local regular_zenpm_action
local ignored_updates_toggled = 0
App.perform_package_action({
    state = { page = "installed", active_tab = "installed" },
    package_icon_file = function() return nil end,
    toggle_package_updates = function() ignored_updates_toggled = ignored_updates_toggled + 1 end,
    confirm_package_action = function(_, _, action) regular_zenpm_action = action end,
}, {
    id = "zenpm-koreader",
    name = "ZenPM",
    plugin_module = "zenpm",
    installed = true,
    update_available = true,
    platforms = { "koreader" },
    versions_url = "https://example.test/versions.json",
})
assert(package_modify_callbacks.info)
assert(package_modify_callbacks.update)
assert(package_modify_callbacks.toggle_updates)
assert(not package_modify_callbacks.updates_ignored)
assert(package_modify_callbacks.enable_disable)
assert(package_modify_callbacks.downgrade)
assert(package_modify_callbacks.uninstall)
package_modify_callbacks.update()
assert(regular_zenpm_action == "update")
package_modify_callbacks.toggle_updates()
assert(ignored_updates_toggled == 1)

local ignored_refreshes = 0
local ignored_pkg = { id = "Reader", installed = true, update_available = true }
local ignored_requests = {}
local ignored_app = {
    state = {
        packages = { ignored_pkg },
    },
    client = {
        set_package_updates_ignored = function(_, id, ignored)
            table.insert(ignored_requests, { id = id, ignored = ignored })
            return true
        end,
    },
    refresh = function() ignored_refreshes = ignored_refreshes + 1 end,
}
App.toggle_package_updates(ignored_app, ignored_pkg)
assert(ignored_pkg.update_ignored == true)
assert(ignored_requests[1].id == "Reader" and ignored_requests[1].ignored == true)
assert(App.installed_update_count(ignored_app) == 0)
App.toggle_package_updates(ignored_app, ignored_pkg)
assert(ignored_pkg.update_ignored == false)
assert(ignored_requests[2].id == "Reader" and ignored_requests[2].ignored == false)
assert(App.installed_update_count(ignored_app) == 1)
assert(ignored_refreshes == 2)

local bulk_queued = {}
local bulk_app = {
    state = {
        queue_running = false,
        queue = {},
        packages = {
            { id = "ignored", installed = true, update_available = true, update_ignored = true },
            { id = "active", installed = true, update_available = true },
        },
    },
    client = {
        get_package_assets = function() return true, {} end,
    },
    queue_package_action = function(_, pkg, action)
        table.insert(bulk_queued, pkg.id .. ":" .. action)
        return true
    end,
    refresh = function() end,
}
assert(App.installed_update_count(bulk_app) == 1)
App.queue_all_updates(bulk_app)
assert(#bulk_queued == 1)
assert(bulk_queued[1] == "active:update")

local reader_settings = {}
_G.G_reader_settings = {
    readSetting = function(_, key) return reader_settings[key] end,
    saveSetting = function(_, key, value) reader_settings[key] = value end,
    flush = function() end,
}
local toggle_done = false
modal_message = nil
modal_seconds = nil
restart_message = nil
restart_callback = nil
App.toggle_enable({
    package_disabled = function() return false end,
    restart_koreader = App.restart_koreader,
}, {
    id = "example",
    name = "Example plugin",
    plugin_module = "example",
}, "plugin", function()
    toggle_done = true
end)
assert(reader_settings.plugins_disabled.example == true)
assert(restart_message == "Restart KOReader to apply the changes.")
assert(modal_message == nil)
assert(modal_seconds == nil)
assert(toggle_done)
assert(type(restart_callback) == "function")
restart_actions = {}
status_message = nil
restart_callback()
assert(status_message == "Restarting...")
assert(restart_actions[1] == "paint")
assert(restart_actions[2] == "Restart")
_G.G_reader_settings = nil

local queued_operations
local queue_app = {
    state = {
        queue = {
            { name = "Install", action = "install" },
            { name = "ZenPM", action = "update", self_update = true },
            { name = "Uninstall", action = "uninstall" },
        },
    },
    queue_count = function(self) return #self.state.queue end,
    prepare_queue_assets = function(_, operations)
        queued_operations = operations
    end,
    refresh = function() end,
}
App.confirm_queue(queue_app)
assert(queue_app.state.queue_running)
assert(queued_operations[1].name == "Uninstall")
assert(queued_operations[2].name == "Install")
assert(queued_operations[3].name == "ZenPM")

assert(App.queue_result_text({}, {
    succeeded = {},
    failed = {
        { entry = { name = "Reader" }, detail = "download failed" },
    },
}) == "Queue completed: 0 succeeded, 1 failed.\n\nReader: download failed")

local queued_self_entry = { name = "ZenPM", self_update = true }
local queued_self_batch = {
    operations = { queued_self_entry },
    index = 1,
    succeeded = {},
    failed = {},
}
local queued_self_completed = false
local queued_self_app = {
    apply_update = function(_, callback) callback(true, "1.2.3") end,
    remove_queue_entry = function(_, entry) assert(entry == queued_self_entry) end,
    run_next_queue_operation = function(_, batch)
        queued_self_completed = batch.index == 2
    end,
}
App.run_next_queue_operation(queued_self_app, queued_self_batch)
assert(#queued_self_batch.succeeded == 1)
assert(queued_self_batch.prompt_restart)
assert(queued_self_completed)

local queued_reinstall_entry = {
    name = "ZenPM",
    pkg = { id = "zenpm-koreader" },
    self_reinstall = true,
    release = "v1.2.3",
}
local queued_reinstall_batch = {
    operations = { queued_reinstall_entry },
    index = 1,
    succeeded = {},
    failed = {},
}
local uninstall_started = false
local reinstalled_release
local queued_reinstall_complete = false
App.run_next_queue_operation({
    run_package_action = function(_, _, action, _, _, opts)
        assert(action == "uninstall")
        uninstall_started = true
        opts.on_result(true)
    end,
    apply_update = function(_, release, callback)
        assert(uninstall_started)
        reinstalled_release = release
        callback(true, "1.2.3")
    end,
    remove_queue_entry = function(_, entry) assert(entry == queued_reinstall_entry) end,
    run_next_queue_operation = function(_, batch)
        queued_reinstall_complete = batch.index == 2
    end,
}, queued_reinstall_batch)
assert(reinstalled_release == "v1.2.3")
assert(#queued_reinstall_batch.succeeded == 1)
assert(queued_reinstall_batch.prompt_restart)
assert(queued_reinstall_complete)

local local_plugin_entry = App.queue_entry_for({
    state = {},
}, {
    id = "local-plugin",
    name = "local-plugin",
    installed = true,
    platforms = { "koreader" },
}, "uninstall")
assert(type(local_plugin_entry.settings_deleter) == "function")

App.poll_package_action({
    busy = true,
    package_action_failure_detail = function() return nil end,
    load_packages = function() return true, {} end,
    package_action_succeeded = function() return true end,
    patch_action_succeeded_from_db = function() return false end,
}, {
    id = "local-plugin",
    name = "local-plugin",
    action = "uninstall",
    was_installed = true,
    prompt_restart = false,
    settings_deleter = local_plugin_entry.settings_deleter,
}, 1)
assert(plugin_settings_prompt:find("Remove plugin settings?", 1, true))
assert(local_plugin_cleanup_calls == 1)

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

local android_stops = 0
local closing_app = {
    backend_ready = true,
    daemon = {
        is_android = function() return true end,
        stop_standalone_backend = function() android_stops = android_stops + 1 end,
    },
    restore_koreader_exit = function() end,
}
App.close(closing_app)
assert(android_stops == 1)
assert(not closing_app.backend_ready)

print("app tests passed")
