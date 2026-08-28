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
local queued_ticks
local modal_title
local modal_rows
local plugin_settings_prompt
local package_modify_callbacks
local ignore_updates_prompt
local model_changes_days
local model_changes_limit
local model_changes_sort
local updater_reinstall_requests = 0
local logged_warnings = {}
local network_connected = true
local network_retry_callback
package.preload["socket"] = function() return {} end
package.preload["ui/event"] = function()
    return { new = function(_, name) return name end }
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
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        nextTick = function(_, callback)
            if queued_ticks then
                table.insert(queued_ticks, callback)
            else
                callback()
            end
        end,
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
package.preload["zenpm_constants"] = function()
    return {
        PLUGIN_DIR = root,
        PACKAGE_ERROR_NOTICE_SECONDS = 1,
        PACKAGE_ACTION_MAX_POLL_RETRIES = 20,
        ANDROID_BACKEND_HEALTH_INTERVAL_SECONDS = 60,
        REPO_KINDLEFORGE_NAME = "KindleForge",
        REPO_KINDLEFORGE_URL = "https://kf.penguins184.xyz",
        KINDLE_SCRIPTLETS_CATEGORY = { id = "kindle-scriptlets" },
    }
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
        notice = function(message) modal_message = message end,
        restart_koreader = function(message, callback)
            restart_message = message
            restart_callback = callback
        end,
        status = function(message) status_message = message end,
        close_status = function() end,
        confirm = function() end,
        actions = function(title, rows)
            modal_title = title
            modal_rows = rows
        end,
        package_modify = function(_, callbacks)
            package_modify_callbacks = callbacks
        end,
        ignore_updates = function(pkg, ignore_all_callback, ignore_version_callback)
            ignore_updates_prompt = {
                pkg = pkg,
                ignore_all_callback = ignore_all_callback,
                ignore_version_callback = ignore_version_callback,
            }
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
        is_font_package = function(pkg) return pkg and pkg.category == "fonts" end,
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
        filter_kindle_scriptlets = function(packages, show)
            if show then return packages end
            local visible = {}
            for _, pkg in ipairs(packages or {}) do
                local kindle = false
                for _, platform in ipairs(pkg.platforms or {}) do
                    kindle = kindle or platform == "kindle" or platform == "kindleforge"
                end
                if pkg.repo ~= "KindleForge" and not kindle then
                    table.insert(visible, pkg)
                end
            end
            return visible
        end,
        changes_packages = function(packages, days, limit, sort_key)
            model_changes_days = days
            model_changes_limit = limit
            model_changes_sort = sort_key
            return { packages[1] }
        end,
    }
end
package.preload["ui/theme"] = function() return {} end
local updater_stub = {
    update = function()
        return true, "1.2.4-beta3"
    end,
    install_kindle_standalone = function(_, _, allow_prerelease, force_refresh)
        assert(not allow_prerelease)
        assert(force_refresh)
        return true, "1.3.0"
    end,
    reinstall = function(_, _, tag, allow_prerelease, force_refresh)
        updater_reinstall_requests = updater_reinstall_requests + 1
        assert(tag == "v1.2.3")
        assert(not allow_prerelease)
        assert(force_refresh)
        return true, "1.2.3"
    end,
}
-- Another plugin may have already claimed this generic module name.
package.loaded["updater"] = {}
package.preload["zenpm_util"] = function()
    return {
        trim = function(value)
            return tostring(value or ""):match("^%s*(.-)%s*$")
        end,
        table_find = function(list, predicate)
            for index, item in ipairs(list or {}) do
                if predicate(item, index) then return item, index end
            end
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
local updater_dofile_loads = 0
dofile = function(path)
    if path == root .. "/client.lua" then return {} end
    if path == root .. "/updater.lua" then
        updater_dofile_loads = updater_dofile_loads + 1
        return updater_stub
    end
    return original_dofile(path)
end
local App = require("app")
dofile = original_dofile
assert(updater_dofile_loads == 1)

local app = {
    state = { beta_updates = false },
}

App.toggle_beta_updates(app)

assert(app.state.beta_updates)
assert(settings.beta_updates == true)

local filtered_app = {
    state = {
        packages = {},
        filter_installable = false,
        beta_updates = false,
        show_kindle_scriptlets = false,
    },
    client = {
        list_packages = function()
            return true, {
                { id = "reader", repo = "ZenLabs" },
                { id = "scriptlet", repo = "KindleForge" },
                { id = "zenlabs-scriptlet", repo = "ZenLabs", platforms = { "kindle" } },
                { id = "zenlabs-koreader-kindle", repo = "ZenLabs", platforms = { "kindle", "koreader" } },
            }
        end,
    },
}
local packages_ok, visible_packages = App.load_packages(filtered_app)
assert(packages_ok and #visible_packages == 1 and visible_packages[1].id == "reader")
filtered_app.state.show_kindle_scriptlets = true
packages_ok, visible_packages = App.load_packages(filtered_app, false, true)
assert(packages_ok and #visible_packages == 4)

local platform_app = {
    state = { show_kindle_scriptlets = false },
    daemon = {
        detect_platform = function() return "kindle" end,
        package_platform_filter = function() return "kindle,koreader" end,
    },
}
assert(App.package_platforms(platform_app) == "koreader")
platform_app.state.show_kindle_scriptlets = true
assert(App.package_platforms(platform_app) == "kindle,koreader")

local kindle_repo_actions = {}
local kindle_settings_refreshes = 0
local kindle_app = {
    busy = false,
    state = {
        page = "settings",
        show_kindle_scriptlets = false,
        packages = { { id = "reader" } },
        repos = { { name = "ZenLabs" } },
        filters = { installed = "" },
        readme_cache = { reader = {} },
    },
    image_files = { reader = "cover.png" },
    daemon = {
        detect_platform = function() return "kindle" end,
        kindle_kpm_installed = function() return false end,
    },
    client = {
        list_repos = function() return true, { { name = "ZenLabs" } } end,
        add_repo = function(_, name, url)
            table.insert(kindle_repo_actions, { action = "add", name = name, url = url })
            return true
        end,
        refresh_repos = function()
            table.insert(kindle_repo_actions, { action = "refresh" })
            return true
        end,
    },
    kindle_scriptlets_available = App.kindle_scriptlets_available,
    refresh = function() kindle_settings_refreshes = kindle_settings_refreshes + 1 end,
}
assert(App.kindle_scriptlets_available(kindle_app))
kindle_app.daemon.kindle_kpm_installed = function() return true end
assert(App.kindle_scriptlets_available(kindle_app))
App.toggle_kindle_scriptlets(kindle_app)
assert(kindle_app.state.show_kindle_scriptlets)
assert(settings.show_kindle_scriptlets == true)
assert(kindle_repo_actions[1].action == "add")
assert(kindle_repo_actions[1].name == "KindleForge")
assert(kindle_repo_actions[1].url == "https://kf.penguins184.xyz")
assert(kindle_repo_actions[2].action == "refresh")
assert(#kindle_app.state.packages == 0 and #kindle_app.state.repos == 0)
assert(next(kindle_app.state.readme_cache) == nil and next(kindle_app.image_files) == nil)
assert(kindle_app.settings_requires_reload and kindle_settings_refreshes == 1)

kindle_app.client.list_repos = function()
    return true, { { name = "KindleForge", url = "https://kf.penguins184.xyz" } }
end
kindle_app.client.remove_repo = function(_, name)
    table.insert(kindle_repo_actions, { action = "remove", name = name })
    return true
end
App.toggle_kindle_scriptlets(kindle_app)
assert(not kindle_app.state.show_kindle_scriptlets)
assert(settings.show_kindle_scriptlets == false)
assert(kindle_repo_actions[3].action == "remove" and kindle_repo_actions[3].name == "KindleForge")
assert(kindle_repo_actions[4].action == "refresh")

app.state.advanced = false
App.toggle_advanced(app)
assert(app.state.advanced)
assert(settings.advanced_queue == true)

local cli_installs = 0
local cli_app = {
    daemon = {
        install_cli_wrapper = function()
            cli_installs = cli_installs + 1
            return true
        end,
    },
}
App.install_cli(cli_app)
assert(cli_installs == 1)
assert(modal_message == "ZenPM command-line interface installed.")

cli_app.daemon.install_cli_wrapper = function() return false end
App.install_cli(cli_app)
assert(modal_message == "Could not install the ZenPM command-line wrapper.")

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

local source_fallback_action
App.prompt_latest_package_build({
    state = { beta_updates = false },
    load_package_releases = App.load_package_releases,
    client = {
        get_package_releases = function()
            return true, { releases = {} }
        end,
    },
    queue_package_action = function(_, _, action, asset)
        source_fallback_action = { action = action, asset = asset }
    end,
}, {
    id = "source-only",
    source_type = "source",
    versions_url = "https://repo.example/source-only/versions.json",
}, nil, "install")
assert(source_fallback_action.action == "install")
assert(source_fallback_action.asset == nil)

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
    refresh_catalog_on_open = App.refresh_catalog_on_open,
}
App.refresh_catalog_on_open(opened_app)
assert(open_refreshes == 1)
assert(next(opened_app.state.readme_cache) == nil)
assert(open_catalog_reloads == 1)

network_connected = false
opened_app.state.readme_cache.reader = { readme = "Cached README" }
App.refresh_catalog_on_open(opened_app)
assert(open_refreshes == 1)
assert(not opened_app.catalog_refreshing)
assert(type(network_retry_callback) == "function")
assert(opened_app.state.readme_cache.reader.readme == "Cached README")

network_connected = true
local retry_catalog_refresh = network_retry_callback
network_retry_callback = nil
retry_catalog_refresh()
assert(open_refreshes == 2)
assert(next(opened_app.state.readme_cache) == nil)
assert(open_catalog_reloads == 2)

local interrupted_catalog_callback
local interrupted_catalog_loads = 0
local interrupted_catalog_reloads = 0
local interrupted_catalog_app = {
    backend_ready = true,
    view = {},
    state = {
        readme_cache = { reader = { readme = "Cached README" } },
    },
    client = {
        refresh_repos = function() return true end,
    },
    run_update_task = function(_, task, _, callback)
        local called, ok = task()
        interrupted_catalog_callback = function()
            callback(true, called, ok)
        end
    end,
    load_packages = function() interrupted_catalog_loads = interrupted_catalog_loads + 1 end,
    load_repos = function() end,
    reload_current_page = function() interrupted_catalog_reloads = interrupted_catalog_reloads + 1 end,
}
App.refresh_catalog_on_open(interrupted_catalog_app)
assert(interrupted_catalog_app.catalog_refreshing)
interrupted_catalog_app.backend_ready = false
interrupted_catalog_callback()
assert(not interrupted_catalog_app.catalog_refreshing)
assert(interrupted_catalog_loads == 0)
assert(interrupted_catalog_reloads == 0)
assert(interrupted_catalog_app.state.readme_cache.reader.readme == "Cached README")

local reload_tab
local reload_full_refresh
App.reload_current_page({
    state = { page = "home", active_tab = "home" },
    navigate = function(_, tab, full_refresh)
        reload_tab = tab
        reload_full_refresh = full_refresh
    end,
})
assert(reload_tab == "home")
assert(reload_full_refresh == false)

local back_routes = {
    category_details = "show_categories",
    source_details = "show_sources",
    package_details = "go_back_from_details",
    queue = "close_queue",
    settings = "close_settings",
}
for page, method in pairs(back_routes) do
    local calls = 0
    local back_app = { state = { page = page } }
    back_app[method] = function() calls = calls + 1 end
    App.go_back(back_app)
    assert(calls == 1)
end

local quit_calls = 0
App.go_back({
    state = { page = "home" },
    quit = function() quit_calls = quit_calls + 1 end,
})
assert(quit_calls == 1)

local navigation_refreshes = {}
local navigation_app = {
    view = {
        refresh = function(_, full_refresh)
            table.insert(navigation_refreshes, full_refresh)
        end,
    },
    show_featured = function(self) App.refresh(self) end,
}
App.navigate(navigation_app, "home")
App.navigate(navigation_app, "home", false)
assert(navigation_refreshes[1] == true)
assert(navigation_refreshes[2] == false)

local changes_refreshes = 0
local changes_app = {
    state = {
        sorts = { changes = "published_at_desc" },
    },
    ensure_backend = function() return true end,
    set_loading = function() end,
    load_packages = function()
        return true, {
            { id = "reader", installed = true },
            { id = "browser" },
        }
    end,
    clear_status = function() end,
    refresh = function() changes_refreshes = changes_refreshes + 1 end,
}
App.show_changes(changes_app)
assert(changes_app.state.page == "changes" and changes_app.state.active_tab == "changes")
assert(model_changes_days == 14)
assert(model_changes_limit == 40)
assert(model_changes_sort == "published_at_desc")
assert(#changes_app.state.changes_packages == 1)
assert(#changes_app.state.visible_packages == 1)
assert(changes_refreshes == 1)

local changes_sort_shown = 0
local changes_sort_app = {
    state = { sorts = { changes = "published_at_desc" } },
    scroll_key = function() return "changes" end,
    reset_scroll = function() end,
    show_changes = function() changes_sort_shown = changes_sort_shown + 1 end,
}
App.set_sort(changes_sort_app, "changes", "published_at_asc")
assert(changes_sort_app.state.sorts.changes == "published_at_asc")
assert(changes_sort_shown == 1)

local selected_changes_sort
App.prompt_sort({
    state = { sorts = { changes = "published_at_desc" } },
    set_sort = function(_, _, value) selected_changes_sort = value end,
}, "changes")
assert(#modal_rows == 2)
assert(modal_rows[1].text == "Ascending" and modal_rows[2].text == "Descending")
assert(modal_rows[2].checked_func())
modal_rows[1].callback()
assert(selected_changes_sort == "published_at_asc")

local shown_catalog_refreshes = 0
local show_sequence = {}
App.show({
    view = {},
    backend_ready = true,
    state = { active_tab = "home" },
    intercept_koreader_exit = function() end,
    finish_deferred_font_uninstalls = function() end,
    navigate = function() table.insert(show_sequence, "navigate") end,
    schedule_plugin_scan_after_open = function() end,
    refresh_catalog_on_open = function()
        shown_catalog_refreshes = shown_catalog_refreshes + 1
        table.insert(show_sequence, "refresh")
    end,
})
assert(shown_catalog_refreshes == 1)
assert(show_sequence[1] == "refresh")
assert(show_sequence[2] == "navigate")

local started_catalog_refreshes = 0
local backend_start_sequence = {}
App.backend_started({
    state = {},
    finish_deferred_font_uninstalls = function() end,
    clear_status = function() end,
    refresh = function() end,
    schedule_plugin_scan_after_open = function() end,
    refresh_catalog_on_open = function()
        started_catalog_refreshes = started_catalog_refreshes + 1
        table.insert(backend_start_sequence, "refresh")
    end,
}, {}, function() table.insert(backend_start_sequence, "ready") end)
assert(started_catalog_refreshes == 1)
assert(backend_start_sequence[1] == "refresh")
assert(backend_start_sequence[2] == "ready")

local UIManager = require("ui/uimanager")
local original_schedule_in = UIManager.scheduleIn
local backend_health_callback
UIManager.scheduleIn = function(_, delay, callback)
    assert(delay == 60)
    backend_health_callback = callback
end
local backend_health_checks = 0
local backend_health_restarts = 0
local backend_health_loading
local backend_health_app = {
    view = {},
    state = {},
    daemon = {
        is_android = function() return true end,
        health_matches = function(_, data) return data and data.version == "1.2.3" end,
    },
    client = {
        health = function()
            backend_health_checks = backend_health_checks + 1
            if backend_health_checks == 1 then return true, { version = "1.2.3" } end
            return false
        end,
    },
    finish_deferred_font_uninstalls = function() end,
    clear_status = function() end,
    refresh = function() end,
    schedule_plugin_scan_after_open = function() end,
    refresh_catalog_on_open = function() end,
    set_loading = function(_, message) backend_health_loading = message end,
    start_backend_then_reload = function() backend_health_restarts = backend_health_restarts + 1 end,
}
App.backend_started(backend_health_app, { version = "1.2.3" })
assert(type(backend_health_callback) == "function")
local first_backend_health_callback = backend_health_callback
backend_health_callback = nil
first_backend_health_callback()
assert(backend_health_checks == 1)
assert(backend_health_app.backend_ready)
assert(type(backend_health_callback) == "function")
local second_backend_health_callback = backend_health_callback
backend_health_callback = nil
second_backend_health_callback()
assert(backend_health_checks == 2)
assert(not backend_health_app.backend_ready)
assert(backend_health_restarts == 1)
assert(backend_health_loading == "Loading packages, please wait")
backend_health_app.backend_ready = true
backend_health_app.view = {}
backend_health_app.restore_koreader_exit = function() end
backend_health_app.daemon.stop_standalone_backend = function() end
App.schedule_android_backend_health_check(backend_health_app)
local stale_backend_health_callback = backend_health_callback
backend_health_app.view = nil
App.close(backend_health_app)
stale_backend_health_callback()
assert(backend_health_checks == 2)
assert(backend_health_restarts == 1)
UIManager.scheduleIn = original_schedule_in

local sources_menu_calls = 0
App.show_actions({
    show_sources = function() sources_menu_calls = sources_menu_calls + 1 end,
})
assert(modal_title == "ZenPM")
assert(modal_rows[4].text == "Sources")
assert(modal_rows[5].text == "Report a Bug")
modal_rows[4].callback()
assert(sources_menu_calls == 1)

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

local forced_subprocess_runs = 0
package.preload["ui/trapper"] = function()
    return {
        wrap = function(_, callback) callback() end,
        dismissableRunInSubprocess = function(_, task)
            forced_subprocess_runs = forced_subprocess_runs + 1
            return true, task()
        end,
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
    return true, true, "1.3.0"
end, trap_widget, function(...)
    update_result = { ... }
end, true)
assert(update_result[1] == true)
assert(update_result[2] == true)
assert(update_result[3] == true)
assert(update_result[4] == "1.3.0")
assert(trap_widget.dismiss_callback == nil)
assert(forced_subprocess_runs == 0)

local homepage_forced_in_process = false
modal_message = nil
App.apply_kindle_homepage_install({
    busy = false,
    state = { beta_updates = false },
    daemon = {},
    run_update_task = function(_, task, _, callback, force_in_process)
        homepage_forced_in_process = force_in_process
        local called, ok, result = task()
        callback(true, called, ok, result)
    end,
})
assert(homepage_forced_in_process)
assert(modal_message == "ZenPM v1.3.0 was copied to the Kindle homepage.")

local self_update_queued = 0
local self_action_app = {
    queue_self_update = function() self_update_queued = self_update_queued + 1 end,
}
App.start_package_action(self_action_app, { id = "zenpm-koreader", plugin_module = "zenpm" }, "update")
assert(self_update_queued == 1)

local scriptlet_action
local scriptlet_asset_requests = 0
local scriptlet_app = {
    client = {
        get_package_assets = function()
            scriptlet_asset_requests = scriptlet_asset_requests + 1
            return true, {}
        end,
    },
    queue_package_action = function(_, _, action, asset, opts)
        scriptlet_action = { action = action, asset = asset, opts = opts }
    end,
}
local scriptlet = {
    id = "kindle-browser",
    platforms = { "kindle" },
    versions_url = "https://repo.example/packages/kindle/browser/versions.json",
}
App.start_package_action(scriptlet_app, scriptlet, "install")
assert(scriptlet_asset_requests == 0)
assert(scriptlet_action.action == "install")
assert(scriptlet_action.asset == nil)

local scriptlet_entry = App.queue_entry_for({}, scriptlet, "update", nil, { release = "1.0.1" })
assert(scriptlet_entry.release == nil)

App.queue_package_action({
    state = { queue_running = false },
    queue_self_update = function() self_update_queued = self_update_queued + 1 return true end,
}, { id = "zenpm-koreader", plugin_module = "zenpm" }, "update")
assert(self_update_queued == 2)

local simple_queue_opened = 0
modal_message = nil
local simple_queue_app = {
    state = { queue_running = false, queue = {}, packages = {} },
    conflicting_packages = function() return {} end,
    zen_ui_installed = function() return false end,
    queue_entry_for = App.queue_entry_for,
    show_queue = function() simple_queue_opened = simple_queue_opened + 1 end,
    refresh = function() error("simple actions should open the queue") end,
}
assert(App.queue_package_action(simple_queue_app, {
    id = "reader",
    installed = true,
}, "update", nil, {}))
assert(#simple_queue_app.state.queue == 1)
assert(simple_queue_opened == 1)
assert(modal_message == nil)

local expected_queue_opens = simple_queue_opened
for _, action in ipairs({ "install", "reinstall", "downgrade", "uninstall" }) do
    simple_queue_app.state.queue = {}
    assert(App.queue_package_action(simple_queue_app, {
        id = "book-browser",
    }, action, nil, {}))
    expected_queue_opens = expected_queue_opens + 1
    assert(#simple_queue_app.state.queue == 1)
    assert(simple_queue_app.state.queue[1].action == action)
    assert(simple_queue_opened == expected_queue_opens)
    assert(modal_message == nil)
end

simple_queue_app.state.queue = {}
simple_queue_app.queue_self_update = App.queue_self_update
assert(App.queue_self_reinstall(simple_queue_app, {
    id = "zenpm-koreader",
}, "1.2.3", {}))
assert(#simple_queue_app.state.queue == 1)
assert(simple_queue_app.state.queue[1].action == "reinstall")
assert(simple_queue_opened == expected_queue_opens + 1)
assert(modal_message == nil)

local advanced_queue_refreshed = 0
simple_queue_app.state.advanced = true
simple_queue_app.state.queue = {}
simple_queue_app.show_queue = function() error("advanced updates should keep the existing flow") end
simple_queue_app.refresh = function() advanced_queue_refreshed = advanced_queue_refreshed + 1 end
assert(App.queue_package_action(simple_queue_app, {
    id = "reader",
    installed = true,
}, "update", nil, {}))
assert(advanced_queue_refreshed == 1)
assert(modal_message == "Added to Queue")

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

local persisted_update_failure
local failed_update_result
App.apply_update({
    state = { beta_updates = false },
    daemon = {
        is_android = function() return false end,
    },
    client = {
        post_log = function(_, message)
            persisted_update_failure = message
            return true
        end,
    },
    run_update_task = function(_, _, _, callback)
        callback(true, true, false, "attempt to call a nil value")
    end,
}, function(...)
    failed_update_result = { ... }
end)
assert(failed_update_result[1] == false)
assert(failed_update_result[2] == "Update failed: attempt to call a nil value")
assert(persisted_update_failure == "ZenPM update failed: attempt to call a nil value")
assert(logged_warnings[#logged_warnings] == persisted_update_failure)

local selected_zenpm_release
App.confirm_package_version({
    queue_self_reinstall = function(_, _, release)
        selected_zenpm_release = release
    end,
}, { id = "zenpm-koreader", installed = true }, "v1.2.3", "reinstall")
assert(selected_zenpm_release == "v1.2.3")

local scriptlet_install_action
App.perform_package_action({
    state = {},
    confirm_package_action = function(_, _, action) scriptlet_install_action = action end,
    prompt_default_package_version = function() error("scriptlets must not open the version picker") end,
}, scriptlet)
assert(scriptlet_install_action == "install")

local regular_zenpm_action
local ignored_updates_toggled = 0
App.perform_package_action({
    state = { page = "installed", active_tab = "installed", advanced = true },
    package_icon_file = function() return nil end,
    prompt_package_updates = function() ignored_updates_toggled = ignored_updates_toggled + 1 end,
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

local simple_update_action
App.perform_package_action({
    state = { page = "installed", active_tab = "installed", advanced = false },
    confirm_package_action = function(_, _, action) simple_update_action = action end,
}, {
    id = "reader",
    installed = true,
    update_available = true,
})
assert(simple_update_action == "update")

local queued_updates_toggled = 0
local removed_queued_updates = {}
local queue_modify_app = {
    state = { queue_running = false },
    package_icon_file = function() return nil end,
    prompt_package_updates = function(_, _, ignored_callback)
        queued_updates_toggled = queued_updates_toggled + 1
        ignored_callback()
        return true
    end,
    remove_queue_entry = function(_, entry)
        table.insert(removed_queued_updates, entry)
        return false
    end,
    refresh = function() end,
}
local queued_update_entry = {
    action = "update",
    pkg = { id = "Reader", installed = true, update_available = true },
}
App.show_queue_entry_modify(queue_modify_app, queued_update_entry)
assert(package_modify_callbacks.remove_queue)
assert(package_modify_callbacks.toggle_updates)
assert(not package_modify_callbacks.updates_ignored)
package_modify_callbacks.toggle_updates()
assert(queued_updates_toggled == 1)
assert(removed_queued_updates[1] == queued_update_entry)

package_modify_callbacks = nil
local queued_self_update_entry = {
    action = "update",
    self_update = true,
    pkg = { id = "zenpm", name = "ZenPM", installed = true },
}
App.show_queue_entry_modify(queue_modify_app, queued_self_update_entry)
assert(package_modify_callbacks.remove_queue)
assert(package_modify_callbacks.toggle_updates)
assert(not package_modify_callbacks.updates_ignored)
package_modify_callbacks.toggle_updates()
assert(queued_updates_toggled == 2)
assert(removed_queued_updates[2] == queued_self_update_entry)

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

local prompted_updates = {}
local prompt_pkg = { id = "Reader", installed = true, update_available = true, latest_version = "1.1.0" }
local prompt_app = {
    set_package_updates_ignored = function(_, pkg, ignored, ignored_version)
        table.insert(prompted_updates, { pkg = pkg, ignored = ignored, ignored_version = ignored_version })
        return true
    end,
}
local prompt_callbacks = 0
App.prompt_package_updates(prompt_app, prompt_pkg, function() prompt_callbacks = prompt_callbacks + 1 end)
assert(ignore_updates_prompt.pkg == prompt_pkg)
ignore_updates_prompt.ignore_version_callback()
assert(prompted_updates[1].ignored == false and prompted_updates[1].ignored_version == "1.1.0")
assert(prompt_callbacks == 1)
App.prompt_package_updates(prompt_app, prompt_pkg, function() prompt_callbacks = prompt_callbacks + 1 end)
ignore_updates_prompt.ignore_all_callback()
assert(prompted_updates[2].ignored == true and prompted_updates[2].ignored_version == nil)
assert(prompt_callbacks == 2)

local bulk_queued = {}
local bulk_queue_opened = 0
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
    show_queue = function() bulk_queue_opened = bulk_queue_opened + 1 end,
    refresh = function() end,
}
assert(App.installed_update_count(bulk_app) == 1)
modal_message = nil
App.queue_all_updates(bulk_app)
assert(#bulk_queued == 1)
assert(bulk_queued[1] == "active:update")
assert(bulk_queue_opened == 1)
assert(modal_message == nil)

bulk_app.state.advanced = true
bulk_queue_opened = 0
bulk_queued = {}
App.queue_all_updates(bulk_app)
assert(#bulk_queued == 1)
assert(bulk_queue_opened == 0)
assert(modal_message == "Added to Queue")

local reader_settings = {}
local pluginloader = require("pluginloader")
pluginloader._discover = function()
    return { { name = "zen_ui", path = "/tmp/zen_ui.koplugin" } }
end
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
    id = "zen-ui",
    name = "ZenOS",
    plugin_module = "zenos",
    plugin_module_aliases = { " zen_ui.koplugin ", "zen_ui" },
}, "plugin", function()
    toggle_done = true
end)
assert(reader_settings.plugins_disabled.zen_ui == true)
assert(reader_settings.plugins_disabled.zenos == nil)
assert(restart_message == "Restart KOReader to apply the changes.")
assert(modal_message == nil)
assert(modal_seconds == nil)
assert(toggle_done)
assert(type(restart_callback) == "function")
restart_actions = {}
status_message = nil
queued_ticks = {}
restart_callback()
assert(status_message == "Restarting...")
assert(restart_actions[1] == "paint")
assert(restart_actions[2] == nil)
assert(#queued_ticks == 1)
table.remove(queued_ticks, 1)()
assert(restart_actions[2] == nil)
assert(#queued_ticks == 1)
table.remove(queued_ticks, 1)()
assert(restart_actions[2] == "Restart")
assert(settings.reopen_after_restart == false)
queued_ticks = nil
restart_actions = {}
App.restart_koreader({}, true)
assert(settings.reopen_after_restart == true)
assert(App.consume_reopen_after_restart())
assert(settings.reopen_after_restart == false)
assert(not App.consume_reopen_after_restart())
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

local plugin_poll_op
App.run_package_action({
    package_action_failure_stats = function() return 0 end,
    client = {
        package_action = function(_, id, action)
            assert(id == "zen-ui" and action == "install")
            return true
        end,
    },
    poll_package_action = function(_, op, attempt)
        plugin_poll_op = op
        assert(attempt == 1)
    end,
}, {
    id = "zen-ui",
    name = "ZenOS",
    installed = true,
    latest_version = "3.0.0-beta26",
    platforms = { "koreader" },
}, "update")
assert(plugin_poll_op.is_plugin)

local recovery_scan_calls = 0
local recovery_load_calls = 0
local recovery_result
local recovery_app = {
    busy = true,
    client = {
        scan_installed_plugins = function()
            recovery_scan_calls = recovery_scan_calls + 1
            return true
        end,
    },
    package_action_failure_detail = function() return nil end,
    load_packages = function()
        recovery_load_calls = recovery_load_calls + 1
        return true, {{
            id = "zen-ui",
            installed = true,
            installed_version = recovery_load_calls == 1 and "3.0.0-beta20" or "3.0.0-beta26",
        }}
    end,
    package_action_succeeded = App.package_action_succeeded,
    patch_action_succeeded_from_db = function() return false end,
    recover_interrupted_plugin_action = App.recover_interrupted_plugin_action,
}
App.poll_package_action(recovery_app, {
    id = "zen-ui",
    name = "ZenOS",
    action = "update",
    is_plugin = true,
    target_version = "3.0.0-beta26",
    on_result = function(ok, detail) recovery_result = { ok, detail } end,
}, 20)
assert(recovery_scan_calls == 1)
assert(recovery_load_calls == 2)
assert(recovery_result[1] == true and recovery_result[2] == nil)
assert(not recovery_app.busy)

local zenfm_companion_updates = 0
table.insert(pluginloader.loaded_plugins, {
    path = "/tmp/zenfm.koplugin",
    daemon = {
        open_android = function(_, action)
            assert(action == "update")
            zenfm_companion_updates = zenfm_companion_updates + 1
            return true
        end,
    },
})
local zenfm_update_result
App.poll_package_action({
    busy = true,
    daemon = { is_android = function() return true end },
    package_action_failure_detail = function() return nil end,
    load_packages = function()
        return true, {{ id = "zenfm", installed = true, installed_version = "1.2.3" }}
    end,
    package_action_succeeded = function() return true end,
    patch_action_succeeded_from_db = function() return false end,
}, {
    id = "zenfm",
    name = "ZenFM",
    action = "update",
    on_result = function(ok, detail) zenfm_update_result = { ok, detail } end,
}, 1)
assert(zenfm_companion_updates == 1)
assert(zenfm_update_result[1] == true and zenfm_update_result[2] == nil)

local failed_scan_calls = 0
local failed_result
App.poll_package_action({
    busy = true,
    client = {
        scan_installed_plugins = function()
            failed_scan_calls = failed_scan_calls + 1
            return true
        end,
    },
    package_action_failure_detail = function() return "backend failure" end,
}, {
    id = "zen-ui",
    name = "ZenOS",
    action = "update",
    is_plugin = true,
    target_version = "3.0.0-beta26",
    on_result = function(ok, detail) failed_result = { ok, detail } end,
}, 20)
assert(failed_scan_calls == 0)
assert(failed_result[1] == false and failed_result[2] == "backend failure")

local non_plugin_scan_calls = 0
local non_plugin_result
App.poll_package_action({
    busy = true,
    client = {
        scan_installed_plugins = function()
            non_plugin_scan_calls = non_plugin_scan_calls + 1
            return true
        end,
    },
    package_action_failure_detail = function() return nil end,
    load_packages = function() return true, {} end,
    package_action_succeeded = function() return false end,
    patch_action_succeeded_from_db = function() return false end,
    recover_interrupted_plugin_action = App.recover_interrupted_plugin_action,
}, {
    id = "example",
    name = "Example",
    action = "update",
    is_plugin = false,
    target_version = "2.0.0",
    on_result = function(ok, detail) non_plugin_result = { ok, detail } end,
}, 20)
assert(non_plugin_scan_calls == 0)
assert(non_plugin_result[1] == false)

local legacy_cleanup_calls = 0
local legacy_loaded = {
    path = "/tmp/zen_ui.koplugin",
    deletePluginSettings = function() legacy_cleanup_calls = legacy_cleanup_calls + 1 end,
}
table.insert(pluginloader.loaded_plugins, legacy_loaded)
local legacy_entry = App.queue_entry_for({ state = {} }, {
    id = "zen-ui",
    name = "ZenOS",
    installed = true,
    platforms = { "koreader" },
    plugin_module = "zenos",
    plugin_module_aliases = { "zen_ui" },
}, "uninstall")
assert(type(legacy_entry.settings_deleter) == "function")
legacy_entry.settings_deleter()
assert(legacy_cleanup_calls == 1)

local zenos_save_calls = 0
local zenos = {
    path = "/tmp/zenos.koplugin",
    config = { library_font = { font_face = "/tmp/fonts/example/Custom.ttf" } },
    saveConfig = function() zenos_save_calls = zenos_save_calls + 1 end,
}
local legacy_zen = {
    path = "/tmp/zen_ui.koplugin",
    config = { library_font = { font_face = "/tmp/fonts/example/Legacy.ttf" } },
}
table.insert(pluginloader.loaded_plugins, zenos)
table.insert(pluginloader.loaded_plugins, legacy_zen)
local deferred_font
App.run_package_action({
    package_action_failure_stats = function() return {} end,
    defer_font_uninstall = function(_, pkg) deferred_font = pkg end,
}, {
    id = "font-example",
    name = "Example Font",
    category = "fonts",
}, "uninstall")
assert(deferred_font and deferred_font.id == "font-example")
assert(zenos.config.library_font.font_face == "default")
assert(zenos_save_calls == 1)
assert(legacy_zen.config.library_font.font_face == "/tmp/fonts/example/Legacy.ttf")

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
