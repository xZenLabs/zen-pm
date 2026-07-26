local socket = require("socket")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local ok_logger, logger = pcall(require, "logger")

local AppView = require("ui/app_view")
local BugReporter = require("bugreporter")
local Constants = require("constants")
-- KOReader may already have a module named "client" loaded. Load our HTTP
-- client explicitly so that cache entry cannot replace it.
local Client = dofile(Constants.PLUGIN_DIR .. "/client.lua")
local Daemon = require("daemon")
local I18n = dofile(Constants.PLUGIN_DIR .. "/i18n.lua")
local Images = require("ui/images")
local Modals = require("ui/modals")
local Models = require("models")
local Theme = require("ui/theme")
local Updater = require("updater")
local Util = require("zenpm_util")

local App = {}

local function content_load_error_code(status_code, detail)
    local error_code = tonumber(status_code)
    for code in tostring(detail or ""):gmatch("HTTP%s+(%d%d%d)") do
        error_code = tonumber(code)
    end
    return error_code
end

local function log_content_load_error(content, package_id, detail, status_code)
    if not (ok_logger and logger and logger.warn) then return end
    local message = "ZenPM could not load " .. content .. " for " .. tostring(package_id)
    if status_code then
        message = message .. " (HTTP " .. tostring(status_code) .. ")"
    end
    logger.warn(message .. ": " .. tostring(detail or "request failed"))
end

-- Persist UI preferences in our own config file inside
-- the ZenPM state dir, kept separate from KOReader's global settings.
local config_settings = nil

local function open_config()
    if config_settings then return config_settings end
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not (ok_ls and LuaSettings) then return nil end
    local ok_home, home = pcall(function() return Daemon:state_home() end)
    if not (ok_home and type(home) == "string" and home ~= "") then return nil end
    local ok_open, settings = pcall(function()
        return LuaSettings:open(home .. "/config.lua")
    end)
    if not ok_open or not settings then return nil end
    config_settings = settings
    return config_settings
end

function App.load_setting(key, default)
    local settings = open_config()
    if not settings then return default end
    local value = settings:readSetting(key)
    if value == nil then return default end
    return value
end

function App.save_setting(key, value)
    local settings = open_config()
    if not settings then return end
    settings:saveSetting(key, value)
    settings:flush()
end

function App:defer_font_uninstall(pkg, asset)
    local pending = App.load_setting("pending_font_uninstalls", {})
    if type(pending) ~= "table" then pending = {} end
    local id = pkg and pkg.id
    for _, item in ipairs(pending) do
        if type(item) == "table" and item.id == id then
            self:restart_koreader()
            return
        end
    end
    table.insert(pending, { id = id, asset = asset })
    App.save_setting("pending_font_uninstalls", pending)
    self:restart_koreader()
end

function App:finish_deferred_font_uninstalls()
    if not self.backend_ready then return end
    local pending = App.load_setting("pending_font_uninstalls", {})
    if type(pending) ~= "table" or #pending == 0 then return end

    local remaining = {}
    for _, item in ipairs(pending) do
        if type(item) ~= "table" or type(item.id) ~= "string" or item.id == "" then
            -- Discard malformed state rather than retrying it forever.
        else
            local ok = self.client:package_action(item.id, "uninstall", item.asset, nil)
            if not ok then table.insert(remaining, item) end
        end
    end
    App.save_setting("pending_font_uninstalls", remaining)
end

function App:new(plugin)
    local saved_sorts = App.load_setting("sorts", {})
    if type(saved_sorts) ~= "table" then saved_sorts = {} end
    local o = {
        plugin = plugin,
        client = Client:new(),
        daemon = Daemon:new(),
        view = nil,
        busy = false,
        backend_ready = false,
        backend_starting = false,
        scan_plugins_on_open = false,
        image_files = {},
        readme_image_queue = {},
        readme_image_pending = {},
        readme_image_loading = false,
        state = {
            page = "home",
            active_tab = "home",
            filter_installable = App.load_setting("filter_installable", true),
            manual_version_picker = App.load_setting("manual_version_picker", App.load_setting("advanced", false)),
            show_all_builds = App.load_setting("show_all_builds", false),
            beta_updates = App.load_setting("beta_updates", false),
            show_readme_images = App.load_setting("show_readme_images", true),
            base_font_size = Theme.normalize_base_font_size(App.load_setting("base_font_size", Theme.get_base_font_size())),
            filters = { search = "", categories = "", category = "", installed = "", source = "" },
            sorts = {
                search = saved_sorts.search or "stars",
                installed = saved_sorts.installed or "name_asc",
                sources = saved_sorts.sources or "name_asc",
                category = saved_sorts.category or "stars",
                source = saved_sorts.source or "stars",
            },
            scroll = {},
            packages = {},
            visible_packages = {},
            featured_packages = {},
            installed_packages = {},
            categories = {},
            visible_categories = {},
            category_packages = {},
            repos = {},
            readme_cache = {},
            release_notes_cache = {},
            current_package = nil,
            current_repo = nil,
            current_category = nil,
            details_from = "search",
            details_tab = "readme",
            details_featured_expanded = false,
            queue = {},
            queue_origin = nil,
            queue_running = false,
            loading = nil,
            error = nil,
            log_lines = {},
        },
    }
    setmetatable(o, self)
    self.__index = self
    Theme.set_base_font_size(o.state.base_font_size)
    return o
end

local function is_sdl_wayland_desktop()
    if os.getenv("WAYLAND_DISPLAY") == nil and os.getenv("SDL_VIDEODRIVER") ~= "wayland" then
        return false
    end
    if type(jit) == "table" and jit.os ~= "Linux" and jit.os ~= "BSD" and jit.os ~= "POSIX" then
        return false
    end

    local ok, Device = pcall(require, "device")
    if not ok or not Device then return false end
    local function device_bool(name)
        if type(Device[name]) ~= "function" then return false end
        local called, value = pcall(Device[name], Device)
        if called then return value == true end
        called, value = pcall(Device[name])
        return called and value == true
    end
    return device_bool("isSDL") or device_bool("isDesktop")
end

function App:run_update_task(task, trap_widget, on_done)
    local function finish(...)
        -- Trapper attaches this callback to let a tap cancel the subprocess.
        -- Once it returns, closing the progress modal must not resume the
        -- already-running coroutine again.
        if trap_widget then trap_widget.dismiss_callback = nil end
        on_done(...)
    end

    local function run_in_process()
        UIManager:nextTick(function()
            local invoked, called, ok, result = pcall(task)
            if invoked then
                finish(true, called, ok, result)
            else
                finish(true, false, called)
            end
        end)
    end

    -- Forking with live EGL state aborts KOReader on SDL/Wayland desktop.
    -- Android's JNI-backed runtime can likewise exit without returning the
    -- updater result to Trapper. Kobo self-updates can fail before entering
    -- the updater when forked, so keep them in the parent process too.
    if self.daemon:is_android()
        or self.daemon:detect_platform() == "kobo"
        or is_sdl_wayland_desktop() then
        run_in_process()
        return
    end

    local ok_trapper, Trapper = pcall(require, "ui/trapper")
    if not ok_trapper
        or type(Trapper) ~= "table"
        or type(Trapper.wrap) ~= "function"
        or type(Trapper.dismissableRunInSubprocess) ~= "function" then
        run_in_process()
        return
    end
    Trapper:wrap(function()
        local completed, called, ok, result = Trapper:dismissableRunInSubprocess(task, trap_widget)
        finish(completed, called, ok, result)
    end)
end

local function package_title(pkg, fallback)
    return Models.package_display_name(pkg, fallback)
end

local function package_id(pkg)
    return Util.trim(tostring(pkg and (pkg.id or pkg.name) or "")):lower()
end

local function action_present(action)
    if action == "update" then
        return _("update")
    end
    if action == "downgrade" then
        return _("downgrade")
    end
    if action == "uninstall" then
        return _("uninstall")
    end
    if action == "reinstall" then
        return _("reinstall")
    end
    return _("install")
end

local function action_progress(action)
    if action == "update" then
        return _("Updating")
    end
    if action == "downgrade" then
        return _("Downgrading")
    end
    if action == "uninstall" then
        return _("Uninstalling")
    end
    if action == "reinstall" then
        return _("Reinstalling")
    end
    return _("Installing")
end

local function backend_action_for(action)
    if action == "reinstall" or action == "downgrade" then
        return "reinstall"
    end
    return action == "update" and "install" or action
end

local function action_done(action)
    if action == "update" then
        return _("updated")
    end
    if action == "install" then
        return _("installed")
    end
    if action == "reinstall" then
        return _("reinstalled")
    end
    if action == "downgrade" then
        return _("downgraded")
    end
    return _("uninstalled")
end

local function queue_key(id, asset)
    return tostring(id or "") .. "\0" .. tostring(asset or "")
end

local function package_is_koreader_plugin(pkg)
    if type(pkg) ~= "table" or type(pkg.platforms) ~= "table" then
        return false
    end
    for _, platform in ipairs(pkg.platforms) do
        if Util.trim(tostring(platform or "")):lower() == "koreader" then
            return true
        end
    end
    return false
end

local function package_is_kindle_only(pkg)
    if type(pkg) ~= "table" or type(pkg.platforms) ~= "table" then
        return false
    end
    local kindle = false
    for _, platform in ipairs(pkg.platforms) do
        platform = Util.trim(tostring(platform or "")):lower()
        if platform == "koreader" then
            return false
        end
        kindle = kindle or platform == "kindle" or platform == "kindleforge"
    end
    return kindle
end

local function queue_notice(pkg)
    local text = _("Added to Queue")
    if package_is_kindle_only(pkg) then
        text = text .. "\n" .. _([[This will install as a "book" on the Kindle homescreen.]])
    end
    return text
end

local function is_zenpm_package(pkg)
    if type(pkg) ~= "table" then return false end
    local module = Util.trim(tostring(pkg.plugin_module or "")):lower()
    local id = Util.trim(tostring(pkg.id or "")):lower()
    return module == "zenpm" or id == "zenpm" or id == "zenpm-koreader"
end

local function action_installs_package(action)
    return action == "install" or action == "reinstall" or action == "update" or action == "downgrade"
end

-- The KOReader plugin name is its .koplugin directory basename.
local function koplugin_dir_basename(path)
    if type(path) ~= "string" then return nil end
    local base = path:gsub("[/\\]+$", ""):match("[^/\\]+$")
    if not base then return nil end
    return (base:gsub("%.koplugin$", ""))
end

local function koplugin_candidates(pkg)
    local candidates = {}
    for _, key in ipairs({ "plugin_module", "id", "name" }) do
        local value = pkg and pkg[key]
        if type(value) == "string" and value ~= "" then
            table.insert(candidates, value)
        end
    end
    return candidates
end

-- Resolve the live KOReader plugin instance for a package by enumerating the
-- loaded plugins and matching on each instance's actual install directory
-- basename. This avoids guessing PluginLoader's internal key: we compare against
-- the directory KOReader really loaded the plugin from (instance.path). The
-- daemon-derived plugin_module is preferred, then the package id/name, since the
-- generic uninstall path leaves plugin_module empty but the id usually matches.
local function koreader_plugin_instance(pkg)
    if type(pkg) ~= "table" then return nil end
    local ok, PluginLoader = pcall(require, "pluginloader")
    if not ok or type(PluginLoader) ~= "table" then return nil end
    local loaded = PluginLoader.loaded_plugins
    if type(loaded) ~= "table" then return nil end

    local by_dir = {}
    for _, inst in pairs(loaded) do
        if type(inst) == "table" then
            local dir = koplugin_dir_basename(inst.path)
            if dir and dir ~= "" then
                by_dir[dir] = inst
            end
            if type(inst.name) == "string" and inst.name ~= "" then
                by_dir[inst.name] = by_dir[inst.name] or inst
            end
        end
    end

    for _, candidate in ipairs(koplugin_candidates(pkg)) do
        if by_dir[candidate] then
            return by_dir[candidate]
        end
    end
    return nil
end

local function plugin_has_delete_settings(inst)
    return type(inst) == "table"
        and type(inst.deletePluginSettings) == "function"
end

local function font_directory_for_package(pkg)
    local id = type(pkg) == "table" and pkg.id or nil
    if type(id) ~= "string" then return nil end
    local directory = id:gsub("^font[_-]+", ""):lower()
    return directory ~= "" and directory or nil
end

local function references_font_directory(value, directory)
    if type(value) ~= "string" or not directory then return false end
    local path = value:gsub("\\", "/"):lower()
    return path:find("fonts/" .. directory .. "/", 1, true) ~= nil
end

local function reset_font_references(value, directory, seen)
    if type(value) == "string" then
        if references_font_directory(value, directory) then
            return "NotoSans-Regular.ttf", true
        end
        return value, false
    end
    if type(value) ~= "table" then return value, false end
    seen = seen or {}
    if seen[value] then return value, false end
    seen[value] = true
    local changed = false
    for key, item in pairs(value) do
        local replacement, item_changed = reset_font_references(item, directory, seen)
        if item_changed then
            value[key] = replacement
            changed = true
        end
    end
    return value, changed
end

local function reset_settings_font_references(settings, directory)
    if type(settings) ~= "table" or type(settings.readSetting) ~= "function"
            or type(settings.saveSetting) ~= "function" then
        return false
    end
    local changed = false
    for _, key in ipairs({
        "cre_font", "fallback_font", "monospace_font", "header_font",
        "cre_font_family_fonts", "font_ui_fallbacks", "footer",
    }) do
        local value = settings:readSetting(key)
        local replacement, value_changed = reset_font_references(value, directory)
        if value_changed then
            settings:saveSetting(key, replacement)
            changed = true
        end
    end
    if changed and type(settings.flush) == "function" then settings:flush() end
    return changed
end

-- A deleted font may still be selected by the active reader or by Zen UI's
-- library-wide font setting. Reset the persisted references first; removal is
-- deferred until the next ZenPM session, after KOReader restarts with defaults.
local function reset_active_font_before_uninstall(pkg)
    local directory = font_directory_for_package(pkg)
    if not directory then return false end
    local changed = false

    if reset_settings_font_references(rawget(_G, "G_reader_settings"), directory) then
        changed = true
    end

    local zen_ui = koreader_plugin_instance({ id = "zen_ui", plugin_module = "zen_ui" })
    if zen_ui and type(zen_ui.config) == "table" then
        local _, config_changed = reset_font_references(zen_ui.config, directory)
        if config_changed then
            if type(zen_ui.config.library_font) == "table" then
                zen_ui.config.library_font.font_face = "default"
            end
            _G.__ZEN_UI_LIBRARY_FONT_CFG = zen_ui.config.library_font
            if type(zen_ui.saveConfig) == "function" then zen_ui:saveConfig() end
            changed = true
        end
    end

    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok_reader and ReaderUI and ReaderUI.instance or nil
    if reader and reset_settings_font_references(reader.doc_settings, directory) then
        changed = true
    end

    return changed
end

-- Locate a package's .koplugin directory on disk, even if the plugin is not
-- loaded (disabled, or only active in the other UI). Uses PluginLoader's own
-- discovery so we honour DEFAULT_PLUGIN_PATH and extra_plugin_paths.
local function find_koplugin_dir(pkg)
    if type(pkg) ~= "table" then return nil end
    local ok, PluginLoader = pcall(require, "pluginloader")
    if not ok or type(PluginLoader) ~= "table" or type(PluginLoader._discover) ~= "function" then
        return nil
    end
    local ok2, discovered = pcall(function() return PluginLoader:_discover() end)
    if not ok2 or type(discovered) ~= "table" then return nil end
    local by_key = {}
    for _, d in ipairs(discovered) do
        if type(d) == "table" then
            if type(d.name) == "string" and d.name ~= "" then
                by_key[d.name] = by_key[d.name] or d.path
            end
            local base = koplugin_dir_basename(d.path)
            if base and base ~= "" then
                by_key[base] = by_key[base] or d.path
            end
        end
    end
    for _, candidate in ipairs(koplugin_candidates(pkg)) do
        if by_key[candidate] then
            return by_key[candidate]
        end
    end
    return nil
end

-- Load a plugin's main.lua without requiring it to be active in this KOReader
-- session. KOReader temporarily prepends the plugin root to package.path when
-- loading plugins; do the same so plugins with require("lib/...") still load.
local function load_plugin_from_disk(dir_path)
    if type(dir_path) ~= "string" or dir_path == "" then return nil end
    local mainfile = dir_path .. "/main.lua"
    local package_path = package.path
    local package_cpath = package.cpath
    package.path = string.format("%s/?.lua;%s", dir_path, package_path)
    package.cpath = string.format("%s/lib/?.so;%s", dir_path, package_cpath)
    local ok, mod = pcall(dofile, mainfile)
    package.path = package_path
    package.cpath = package_cpath
    if not ok or type(mod) ~= "table" then return nil end
    return mod
end

-- Delete settings only through the plugin's explicit cleanup method. This
-- avoids guessing which generic settings files belong to a plugin.
local function delete_plugin_settings(plugin)
    if not plugin_has_delete_settings(plugin) then return end
    local ok_pl, PluginLoader = pcall(require, "pluginloader")
    if ok_pl and type(PluginLoader) == "table"
            and type(PluginLoader.deletePluginSettings) == "function" then
        pcall(function() PluginLoader:deletePluginSettings(plugin) end)
    else
        if type(plugin.deletePluginSettings) == "function" then
            pcall(function() plugin:deletePluginSettings() end)
        end
        if plugin.settings_file then
            os.remove(plugin.settings_file)
            os.remove(plugin.settings_file .. ".old")
        end
        if plugin.settings_key and G_reader_settings and G_reader_settings.delSetting then
            G_reader_settings:delSetting(plugin.settings_key)
        end
    end
end

-- Resolve a settings deleter before the backend uninstall purges the .koplugin
-- directory. The returned closure captures any loaded module from disk, so
-- deletePluginSettings can still run after the directory is removed.
local function resolve_plugin_settings_deleter(pkg)
    local dir_path = find_koplugin_dir(pkg)

    local inst = koreader_plugin_instance(pkg)
    if plugin_has_delete_settings(inst) then
        return function() delete_plugin_settings(inst) end
    end

    local mod = load_plugin_from_disk(dir_path)
    if plugin_has_delete_settings(mod) then
        return function() delete_plugin_settings(mod) end
    end
    return nil
end

-- The key KOReader stores in its plugins_disabled table is the .koplugin dir
-- basename. Prefer the on-disk directory (honours disabled/unloaded plugins),
-- fall back to the daemon-derived module name, then the package id/name.
local function plugin_disabled_key(pkg)
    local key = koplugin_dir_basename(find_koplugin_dir(pkg))
    if type(key) == "string" and key ~= "" then return key end
    key = pkg and (pkg.plugin_module or pkg.id or pkg.name)
    if type(key) == "string" and key ~= "" then return key end
    return nil
end

local function is_plugin_disabled(pkg)
    local key = plugin_disabled_key(pkg)
    if not key or not (G_reader_settings and G_reader_settings.readSetting) then
        return false
    end
    local disabled = G_reader_settings:readSetting("plugins_disabled")
    return type(disabled) == "table" and disabled[key] == true
end

-- Toggle a plugin the same way KOReader's PluginLoader does: flip the key in the
-- plugins_disabled table and flush. Takes effect on restart.
local function set_plugin_disabled(pkg, disabled)
    local key = plugin_disabled_key(pkg)
    if not key then return false, _("Could not resolve plugin name.") end
    if not (G_reader_settings and G_reader_settings.saveSetting) then
        return false, _("KOReader settings are unavailable.")
    end
    local t = G_reader_settings:readSetting("plugins_disabled")
    if type(t) ~= "table" then t = {} end
    if disabled then t[key] = true else t[key] = nil end
    G_reader_settings:saveSetting("plugins_disabled", t)
    G_reader_settings:flush()
    return true
end

local function patches_dir()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        return DataStorage:getDataDir() .. "/patches"
    end
    return nil
end

local function file_exists(path)
    if type(path) ~= "string" or path == "" then return false end
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- A userpatch is disabled the native way by appending .disabled to its filename.
local function is_patch_disabled(pkg)
    local asset = pkg and pkg.patch_asset
    local dir = patches_dir()
    if type(asset) ~= "string" or asset == "" or not dir then return false end
    local base = dir .. "/" .. asset
    return (not file_exists(base)) and file_exists(base .. ".disabled")
end

local function set_patch_disabled(asset, disabled)
    local dir = patches_dir()
    if type(asset) ~= "string" or asset == "" or not dir then
        return false, _("Could not resolve patch file.")
    end
    local base = dir .. "/" .. asset
    local off = base .. ".disabled"
    local from, to = base, off
    if not disabled then from, to = off, base end
    if not file_exists(from) then
        -- Already in target state (or missing); treat as success if target exists.
        if file_exists(to) then return true end
        return false, _("Patch file not found.")
    end
    local ok, err = os.rename(from, to)
    if not ok then return false, tostring(err or _("rename failed")) end
    return true
end

local function remove_patch_file(asset)
    local dir = patches_dir()
    if type(asset) ~= "string" or asset == "" or not dir then
        return false, _("Could not resolve patch file.")
    end
    local base = dir .. "/" .. asset
    if file_exists(base) then
        local ok, err = os.remove(base)
        return ok ~= nil, err
    end
    if file_exists(base .. ".disabled") then
        local ok, err = os.remove(base .. ".disabled")
        return ok ~= nil, err
    end
    return false, _("Patch file not found.")
end

function App:queue_count()
    return #(self.state.queue or {})
end

function App:installed_update_count()
    local count = 0
    for _, pkg in ipairs(self.state.packages or {}) do
        if pkg.installed and pkg.update_available then
            count = count + 1
        end
    end
    return count
end

function App:queue_all_updates()
    if self.state.queue_running then return end
    local queued = {}
    local added = 0
    local kindle_only_added = false
    for _, entry in ipairs(self.state.queue) do
        queued[entry.key] = true
    end
    local packages = self.state.packages or {}
    local function finish()
        if added > 0 then
            local notice = _("Added to Queue")
            if kindle_only_added then
                notice = notice .. "\n" .. _([[This will install as a "book" on the Kindle homescreen.]])
            end
            Modals.info_for(notice, Constants.PACKAGE_NOTICE_SECONDS)
        end
        self:refresh()
    end
    local add_next
    add_next = function(index)
        local pkg = packages[index]
        if not pkg then
            finish()
            return
        end
        if pkg.installed and pkg.update_available then
            local key = queue_key(pkg.id or pkg.name, nil)
            if not queued[key] then
                if is_zenpm_package(pkg) then
                    if self:queue_self_update(pkg, { silent = true }) then
                        added = added + 1
                    end
                    queued[key] = true
                    add_next(index + 1)
                    return
                end
                if Models.is_font_package(pkg) then
                    if self:queue_package_action(pkg, "update", nil, { silent = true }) then
                        added = added + 1
                        kindle_only_added = kindle_only_added or package_is_kindle_only(pkg)
                    end
                    queued[key] = true
                    add_next(index + 1)
                    return
                end
                local asset = nil
                local ok, info = self.client:get_package_assets(pkg.id or pkg.name)
                local candidates = ok and type(info) == "table" and info.needs_choice
                    and type(info.candidates) == "table" and info.candidates or nil
                if candidates and #candidates > 0 and not Models.is_font_package(pkg) then
                    self:choose_package_asset(pkg, "update", candidates, nil, {
                        silent = true,
                        on_queued = function(was_added)
                            if was_added then
                                added = added + 1
                                kindle_only_added = kindle_only_added or package_is_kindle_only(pkg)
                            end
                            queued[key] = true
                            add_next(index + 1)
                        end,
                        on_cancel = finish,
                    })
                    return
                end
                if ok and type(info) == "table" and info.auto and info.auto ~= "" then
                    asset = info.auto
                end
                if self:queue_package_action(pkg, "update", asset, {
                    silent = true,
                    release = pkg.latest_release,
                }) then
                    added = added + 1
                    kindle_only_added = kindle_only_added or package_is_kindle_only(pkg)
                end
                queued[key] = true
            end
        end
        add_next(index + 1)
    end
    add_next(1)
end

function App:queue_entry_for(pkg, action, asset, opts)
    local id = pkg and (pkg.id or pkg.name)
    if not id then return nil end
    opts = opts or {}
    local is_patch = Models.is_patch_package(pkg)
    local is_font = Models.is_font_package(pkg)
    local display_name = is_patch and asset and asset ~= ""
        and (_("patch") .. " " .. tostring(asset))
        or package_title(pkg, id)
    return {
        key = queue_key(id, is_patch and asset or nil),
        id = id,
        pkg = pkg,
        name = display_name,
        action = action,
        asset = asset,
        release = opts.release,
        is_patch = is_patch,
        prompt_restart = (package_is_koreader_plugin(pkg) or is_patch)
            and (action_installs_package(action) or action == "uninstall"),
        settings_deleter = action == "uninstall" and not is_patch and not is_font
            and resolve_plugin_settings_deleter(pkg) or nil,
    }
end

function App:queue_package_action(pkg, action, asset, opts)
    if self.state.queue_running then
        Modals.info(_("Queue is running. Please wait."))
        return false
    end
    opts = opts or {}
    if action == "update" and is_zenpm_package(pkg) then
        return self:queue_self_update(pkg, opts)
    end
    if action_installs_package(action) and not opts.conflict_confirmed then
        local conflicts = self:conflicting_packages(pkg)
        local zen_ui_warning = Models.is_patch_package(pkg) and self:zen_ui_installed()
        if zen_ui_warning or #conflicts > 0 then
            local names = {}
            for _, conflict in ipairs(conflicts) do
                table.insert(names, package_title(conflict, conflict.id or _("Package")))
            end
            local message = zen_ui_warning and _("Zen UI is installed. Most patches should not be used with Zen UI.") or ""
            if #names > 0 then
                local conflict_message = string.format(
                    _("%s conflicts with %s. They should not be used together. Install anyway?"),
                    package_title(pkg, pkg.id or _("Package")),
                    table.concat(names, ", ")
                )
                message = message ~= "" and message .. "\n\n" .. conflict_message or conflict_message
            else
                message = message .. "\n\n" .. _("Install anyway?")
            end
            Modals.confirm(
                message,
                _("Install anyway"),
                function()
                    opts.conflict_confirmed = true
                    self:queue_package_action(pkg, action, asset, opts)
                end,
                true
            )
            return false
        end
    end
    local entry = self:queue_entry_for(pkg, action, asset, opts)
    if not entry then
        Modals.info(_("Package has no id."))
        return false
    end
    for index, queued in ipairs(self.state.queue) do
        if queued.key == entry.key then
            self.state.queue[index] = entry
            if not opts.silent then
                Modals.info_for(queue_notice(pkg), Constants.PACKAGE_NOTICE_SECONDS)
            end
            self:refresh()
            return true
        end
    end
    table.insert(self.state.queue, entry)
    if not opts.silent then
        Modals.info_for(queue_notice(pkg), Constants.PACKAGE_NOTICE_SECONDS)
    end
    self:refresh()
    return true
end

function App:queue_self_update(pkg, opts)
    if self.state.queue_running then
        Modals.info(_("Queue is running. Please wait."))
        return false
    end
    opts = opts or {}
    local id = pkg and (pkg.id or pkg.name)
    if not id then return false end
    local reinstall = opts.reinstall == true
    local entry = {
        key = queue_key(id, nil),
        id = id,
        pkg = pkg,
        name = package_title(pkg, _("ZenPM")),
        action = reinstall and "reinstall" or "update",
        release = opts.release,
        self_update = not reinstall,
        self_reinstall = reinstall,
    }
    for index, queued in ipairs(self.state.queue) do
        if queued.key == entry.key then
            self.state.queue[index] = entry
            self:refresh()
            return true
        end
    end
    table.insert(self.state.queue, entry)
    if not opts.silent then
        Modals.info_for(queue_notice(pkg), Constants.PACKAGE_NOTICE_SECONDS)
    end
    self:refresh()
    return true
end

function App:queue_self_reinstall(pkg, release, opts)
    opts = opts or {}
    opts.reinstall = true
    opts.release = release
    return self:queue_self_update(pkg, opts)
end

local function conflict_set(pkg)
    local set = {}
    for _, id in ipairs(type(pkg and pkg.conflicts) == "table" and pkg.conflicts or {}) do
        id = Util.trim(tostring(id or "")):lower()
        if id ~= "" then
            set[id] = true
        end
    end
    return set
end

function App:conflicting_packages(pkg)
    local id = package_id(pkg)
    if id == "" then return {} end

    local present = {}
    for _, candidate in ipairs(self.state.packages or {}) do
        local candidate_id = package_id(candidate)
        if candidate_id ~= "" and candidate_id ~= id
            and (candidate.installed or #(candidate.installed_assets or {}) > 0) then
            present[candidate_id] = candidate
        end
    end
    for _, queued in ipairs(self.state.queue or {}) do
        local candidate_id = package_id(queued.pkg)
        if candidate_id ~= "" and candidate_id ~= id then
            if action_installs_package(queued.action) then
                present[candidate_id] = queued.pkg
            elseif queued.action == "uninstall" then
                present[candidate_id] = nil
            end
        end
    end

    local target_conflicts = conflict_set(pkg)
    local conflicts = {}
    for candidate_id, candidate in pairs(present) do
        if target_conflicts[candidate_id] or conflict_set(candidate)[id] then
            table.insert(conflicts, candidate)
        end
    end
    table.sort(conflicts, function(a, b)
        return package_title(a, a.id or "") < package_title(b, b.id or "")
    end)
    return conflicts
end

function App:zen_ui_installed()
    for _, candidate in ipairs(self.state.packages or {}) do
        if package_id(candidate) == "zen-ui" and candidate.installed then
            return true
        end
    end
    return false
end

function App:clear_queue()
    if self.state.queue_running then return end
    self.state.queue = {}
    if self.state.page == "queue" then
        self:close_queue()
    else
        self:refresh()
    end
end

function App:confirm_clear_queue()
    if self.state.queue_running or self:queue_count() == 0 then return end
    Modals.confirm(
        _("Are you sure you want to clear the queue?"),
        _("Clear"),
        function() self:clear_queue() end
    )
end

function App:show_queue()
    if self.state.page ~= "queue" then
        self.state.queue_origin = {
            page = self.state.page,
            active_tab = self.state.active_tab,
        }
    end
    self.state.page = "queue"
    self:reset_scroll("queue")
    self:refresh()
end

function App:close_queue()
    if self.state.queue_running then return end
    local origin = self.state.queue_origin or {}
    self.state.queue_origin = nil
    self.state.page = origin.page or "home"
    self.state.active_tab = origin.active_tab or self.state.active_tab or "home"
    self:refresh()
end

function App:remove_queue_entry(entry)
    for index, queued in ipairs(self.state.queue) do
        if queued == entry then
            table.remove(self.state.queue, index)
            return #self.state.queue == 0
        end
    end
    return false
end

function App:confirm_remove_queue_entry(entry)
    if self.state.queue_running then return end
    Modals.confirm(
        string.format(_("Remove %s from queue?"), entry.name or _("Package")),
        _("Remove"),
        function()
            if self:remove_queue_entry(entry) and self.state.page == "queue" then
                self:close_queue()
            else
                self:refresh()
            end
        end
    )
end

function App:show_queue_entry_modify(entry)
    if self.state.queue_running or not entry or not entry.pkg then return end
    local pkg = entry.pkg
    local remove_queue = function() self:confirm_remove_queue_entry(entry) end
    if entry.self_update or entry.self_reinstall then
        Modals.actions(Models.package_display_name(pkg, _("ZenPM")), {
            { text = _("Remove from queue"), callback = remove_queue },
        })
        return
    end
    if entry.is_patch then
        Modals.package_modify(pkg, {
            title_icon = self:package_icon_file(pkg),
            remove_queue = remove_queue,
            uninstall = entry.action ~= "uninstall" and function()
                self:queue_package_action(pkg, "uninstall", entry.asset, nil)
            end or nil,
        })
        return
    end
    if not pkg.installed then
        local actions = {
            {
                text = _("Remove from queue"),
                callback = remove_queue,
            },
        }
        if entry.action ~= "install" then
            table.insert(actions, {
                text = _("Install"),
                callback = function()
                    self:confirm_package_action(pkg, "install")
                end,
            })
        end
        Modals.actions(Models.package_display_name(pkg, _("Package")), actions)
        return
    end
    Modals.package_modify(pkg, {
        title_icon = self:package_icon_file(pkg),
        remove_queue = remove_queue,
        update = entry.action ~= "update" and pkg.update_available and function()
            self:confirm_package_action(pkg, "update")
        end or nil,
            downgrade = Models.has_version_history(pkg) and function()
                self:prompt_package_versions(pkg)
            end or nil,
        uninstall = entry.action ~= "uninstall" and function()
            self:confirm_package_action(pkg, "uninstall")
        end or nil,
    })
end

function App:queue_result_text(batch)
    local succeeded = #batch.succeeded
    local failed = #batch.failed
    if failed == 0 then
        return string.format(_("Queue completed: %d succeeded."), succeeded)
    end
    return string.format(_("Queue completed: %d succeeded, %d failed."), succeeded, failed)
end

function App:refresh_queue_package_state()
    local ok, packages = self:load_packages(false, true)
    if not ok then return end
    self.state.packages = packages
    local installed = Models.installed_packages(packages)
    self.state.installed_packages = installed
    local visible = Models.filter_packages_by_category(installed, self.state.filters.installed)
    self.state.visible_packages = self:sorted_packages("installed", visible)
end

function App:finish_queue_batch(batch)
    self:refresh_queue_package_state()

    local function finish_prompts(index)
        local cleanup = batch.settings_cleanup[index]
        if cleanup then
            Modals.plugin_settings_cleanup(cleanup.name .. " " .. _("uninstalled successfully.\n\nRemove plugin settings?"), function(remove_settings)
                if remove_settings then cleanup.callback() end
                finish_prompts(index + 1)
            end)
            return
        end

        local result = self:queue_result_text(batch)
        local queue_completed = #batch.failed == 0
        self.state.queue_running = false
        self:refresh()
        if batch.prompt_restart then
            Modals.restart_koreader(result .. "\n\n" .. _("Restart KOReader to apply the changes."), function()
                self:restart_koreader()
            end, queue_completed and function()
                self:close_queue()
            end or nil)
        else
            if queue_completed then
                self:close_queue()
                self:reload_current_page()
                Modals.notice(result)
            else
                Modals.confirm(result, nil, function() end)
            end
        end
    end
    finish_prompts(1)
end

function App:run_next_queue_operation(batch)
    local entry = batch.operations[batch.index]
    if not entry then
        self:finish_queue_batch(batch)
        return
    end
    local position = batch.index
    if entry.self_update or entry.self_reinstall then
        local function complete(succeeded, detail)
            if succeeded then
                self:remove_queue_entry(entry)
                table.insert(batch.succeeded, entry)
                batch.prompt_restart = detail ~= nil
            else
                table.insert(batch.failed, { entry = entry, detail = detail })
            end
            batch.index = batch.index + 1
            UIManager:nextTick(function()
                self:run_next_queue_operation(batch)
            end)
        end
        if entry.self_reinstall then
            self:run_package_action(entry.pkg, "uninstall", nil, nil, {
                status_prefix = string.format(_("Queue %d/%d: "), position, #batch.operations),
                on_result = function(succeeded, detail)
                    if not succeeded then
                        complete(false, detail)
                        return
                    end
                    self:apply_update(entry.release, function(installed, version)
                        complete(installed, version)
                    end)
                end,
            })
        else
            self:apply_update(complete)
        end
        return
    end
    self:run_package_action(entry.pkg, entry.action, entry.asset, nil, {
        release = entry.release,
        settings_deleter = entry.settings_deleter,
        queue_entry = entry,
        status_prefix = string.format(_("Queue %d/%d: "), position, #batch.operations),
        on_result = function(succeeded, detail, op)
            if succeeded then
                self:remove_queue_entry(entry)
                table.insert(batch.succeeded, entry)
                if entry.action == "uninstall" and type(entry.settings_deleter) == "function" then
                    table.insert(batch.settings_cleanup, { name = entry.name, callback = entry.settings_deleter })
                end
                if entry.prompt_restart then batch.prompt_restart = true end
            else
                table.insert(batch.failed, { entry = entry, detail = detail })
            end
            batch.index = batch.index + 1
            UIManager:nextTick(function()
                self:run_next_queue_operation(batch)
            end)
        end,
    })
end

function App:prepare_queue_assets(operations, index, on_ready)
    local entry = operations[index]
    if not entry then
        on_ready()
        return
    end
    if entry.self_update or entry.self_reinstall or not action_installs_package(entry.action) or (entry.asset and entry.asset ~= "") then
        self:prepare_queue_assets(operations, index + 1, on_ready)
        return
    end

    local ok, info = self.client:get_package_assets(entry.id)
    if not ok then
        self.state.queue_running = false
        self:refresh()
        Modals.info(_("Could not determine which build to install: ") .. tostring(info))
        return
    end
    if type(info) ~= "table" or not info.needs_choice then
        if type(info) == "table" and info.auto and info.auto ~= "" then
            entry.asset = info.auto
        end
        self:prepare_queue_assets(operations, index + 1, on_ready)
        return
    end

    local rows = {}
    for _, asset in ipairs(info.candidates or {}) do
        local name = asset.asset
        if name and name ~= "" then
            local label = name
            if asset.arch and asset.arch ~= "" then
                label = tostring(asset.arch) .. " — " .. name
            end
            table.insert(rows, {
                text = label,
                callback = function()
                    entry.asset = name
                    self:prepare_queue_assets(operations, index + 1, on_ready)
                end,
            })
        end
    end
    if #rows == 0 then
        self:prepare_queue_assets(operations, index + 1, on_ready)
        return
    end
    Modals.actions(_("Choose a build for ") .. package_title(entry.pkg, entry.id), rows, {
        cancel_callback = function()
            self.state.queue_running = false
            self:refresh()
        end,
    })
end

function App:confirm_queue()
    if self.busy or self.state.queue_running or self:queue_count() == 0 then return end
    local operations = {}
    for _, entry in ipairs(self.state.queue) do
        if not entry.self_update and not entry.self_reinstall and entry.action == "uninstall" then table.insert(operations, entry) end
    end
    for _, entry in ipairs(self.state.queue) do
        if not entry.self_update and not entry.self_reinstall and entry.action ~= "uninstall" then table.insert(operations, entry) end
    end
    for _, entry in ipairs(self.state.queue) do
        if entry.self_update or entry.self_reinstall then table.insert(operations, entry) end
    end
    self.state.queue_running = true
    local batch = {
        operations = operations,
        index = 1,
        succeeded = {},
        failed = {},
        settings_cleanup = {},
        prompt_restart = false,
    }
    self:prepare_queue_assets(operations, 1, function()
        self:run_next_queue_operation(batch)
    end)
    self:refresh()
end

function App:prompt_queue_confirmation()
    if self.busy or self.state.queue_running or self:queue_count() == 0 then return end
    Modals.confirm(
        _("Are you sure you want to perform all queued actions?"),
        _("Confirm"),
        function() self:confirm_queue() end
    )
end

function App:show()
    if not self.view then
        self.view = AppView:new{ app = self }
    end
    self:intercept_koreader_exit()
    UIManager:show(self.view)
    self.scan_plugins_on_open = true
    if self.backend_ready then
        self:finish_deferred_font_uninstalls()
        self:navigate(self.state.active_tab or "home")
        self:schedule_plugin_scan_after_open()
    else
        self.t_open = socket.gettime()
        self:set_loading(_("Loading packages, please wait"))
        self:start_backend_then_reload()
    end
end

function App:intercept_koreader_exit()
    if self.exit_hook then return end
    local menu = self.plugin and self.plugin.ui and self.plugin.ui.menu
    if not menu or type(menu.exitOrRestart) ~= "function" then return end

    local original = menu.exitOrRestart
    self.exit_menu = menu
    self.exit_original = original
    self.exit_hook = function(menu_self, ...)
        self:close()
        return original(menu_self, ...)
    end
    menu.exitOrRestart = self.exit_hook
end

function App:restore_koreader_exit()
    if self.exit_menu and self.exit_menu.exitOrRestart == self.exit_hook then
        self.exit_menu.exitOrRestart = self.exit_original
    end
    self.exit_menu = nil
    self.exit_original = nil
    self.exit_hook = nil
end

function App:close()
    self:restore_koreader_exit()
    if self.view then
        local view = self.view
        local dimen = view.dimen
        UIManager:close(view, "flashui", dimen)
        self.view = nil
        UIManager:nextTick(function()
            UIManager:setDirty("all", "flashui", dimen)
        end)
    end
end

function App:quit()
    self:close()
end

function App:restart_koreader()
    Modals.status(_("Restarting..."))
    UIManager:nextTick(function()
        UIManager:broadcastEvent(Event:new("Restart"))
    end)
end

function App:refresh()
    if self.view then
        self.view:refresh(self._full_refresh)
    end
end

function App:set_loading(message)
    self.state.loading = message
    self.state.error = nil
    self:refresh()
end

function App:set_error(message)
    self.state.loading = nil
    self.state.error = message
    self:refresh()
end

function App:clear_status()
    self.state.loading = nil
    self.state.error = nil
end

function App:log_timing(label, since)
    local now = socket.gettime()
    local elapsed = since and (now - since) or 0
    pcall(function()
        self.client:post_log(string.format("[timing] %s: %.0fms", label, elapsed * 1000))
    end)
    return now
end

function App:schedule_plugin_scan_after_open()
    if not self.scan_plugins_on_open then return end
    UIManager:scheduleIn(0.1, function()
        if not self.view or not self.backend_ready then return end
        self:scan_plugins_after_open(1)
    end)
end

function App:scan_plugins_after_open(attempt)
    if not self.scan_plugins_on_open then return end
    if #(self.state.packages or {}) == 0 then
        local catalog_ready, packages = self:load_packages(false, true)
        if not catalog_ready or #packages == 0 then
            if attempt < Constants.MAX_POLL_RETRIES then
                UIManager:scheduleIn(Constants.POLL_DELAY_SECONDS, function()
                    if not self.view then return end
                    self:scan_plugins_after_open(attempt + 1)
                end)
            else
                self.scan_plugins_on_open = false
            end
            return
        end
        self.state.packages = packages
    end
    local ok, data = self.client:scan_installed_plugins()
    if ok then
        self.scan_plugins_on_open = false
        self.state.packages = {}
        self:reload_current_page()
        return
    end
    if tostring(data):find("non-empty catalog", 1, true)
        and attempt < Constants.MAX_POLL_RETRIES then
        UIManager:scheduleIn(Constants.POLL_DELAY_SECONDS, function()
            if not self.view then return end
            self:scan_plugins_after_open(attempt + 1)
        end)
        return
    end
    self.scan_plugins_on_open = false
    Modals.info_for(_("Plugin scan failed: ") .. tostring(data), Constants.PACKAGE_ERROR_NOTICE_SECONDS)
end

function App:backend_started(data, on_ready)
    self.backend_starting = false
    self.backend_ready = true
    self.version = data and data.version or self.version or "?"
    if self.t_open then
        self:log_timing("backend ready (open -> health ok)", self.t_open)
    end
    self:clear_status()
    self:finish_deferred_font_uninstalls()
    if on_ready then
        on_ready()
    else
        self:refresh()
    end
    self:schedule_plugin_scan_after_open()
end

function App:backend_failed(message)
    self.backend_starting = false
    self.backend_ready = false
    self:set_error(message)
    Modals.info(message)
end

function App:poll_backend_ready(attempt, on_ready)
    local delay = attempt <= 1
        and Constants.CONNECT_INITIAL_DELAY_SECONDS
        or Constants.CONNECT_RETRY_DELAY_SECONDS
    UIManager:scheduleIn(delay, function()
        local ok, data = self.client:health()
        if ok and self.daemon:health_matches(data) then
            self:backend_started(data, on_ready)
            return
        end
        if attempt >= Constants.CONNECT_RETRIES then
            self:backend_failed(Constants.DAEMON_UNAVAILABLE_MESSAGE)
            return
        end
        self:poll_backend_ready(attempt + 1, on_ready)
    end)
end

function App:start_backend_then_reload()
    if self.backend_starting then
        return
    end
    self.backend_starting = true
    UIManager:scheduleIn(0.1, function()
        local changed, prepare_err = self.daemon:ensure_backend_files()
        if prepare_err then
            self:backend_failed(prepare_err)
            return
        end

        local healthy, health_data = self.client:health()
        if healthy and not changed and self.daemon:health_matches(health_data) then
            self:backend_started(health_data, function()
                self:reload_current_page()
            end)
            return
        elseif healthy then
            self.daemon:stop_known_backends()
            changed = true
        end

        self:set_loading(_("Loading packages, please wait"))
        local started, err = self.daemon:start(true)
        if not started then
            self:backend_failed(err)
            return
        end
        self:poll_backend_ready(1, function()
            self:reload_current_page()
        end)
    end)
end

function App:ensure_backend()
    if self.backend_starting then
        self:set_loading(_("Loading packages, please wait"))
        return false
    end

    -- Backend already verified healthy this session: skip the per-navigate
    -- ensure_backend_files() (shells out to uname) + synchronous /health.
    -- A daemon restart or /repo/refresh clears backend_ready to force re-check.
    if self.backend_ready then
        return true
    end

    local changed, prepare_err = self.daemon:ensure_backend_files()
    if prepare_err then
        self:set_error(prepare_err)
        Modals.info(prepare_err)
        self.backend_ready = false
        return false
    end

    local healthy, health_data = self.client:health()
    if healthy and not changed and self.daemon:health_matches(health_data) then
        self.backend_ready = true
        self.version = health_data and health_data.version or self.version or "?"
        return true
    elseif healthy then
        self.daemon:stop_known_backends()
        changed = true
    end

    self:set_loading(_("Loading packages, please wait"))
    -- Do not use Daemon:ensure here: it retries with socket.sleep() on the
    -- UI thread. Startup is scheduled by start_backend_then_reload() so touch
    -- input remains responsive while the companion comes up.
    self:start_backend_then_reload()
    return false
end

function App:platform()
    return self.daemon:platform_filter()
end

function App:package_platforms()
    return self.daemon:package_platform_filter()
end

function App:image_file_for(value)
    value = tostring(value or "")
    if value == "" then
        return nil
    end
    if self.image_files[value] and Util.path_exists(self.image_files[value]) then
        return self.image_files[value]
    end
    local file = Images.file_for(self.client, self:platform(), value)
    if file then
        self.image_files[value] = file
    end
    return file
end

function App:cached_image_file(value)
    value = tostring(value or "")
    if value == "" then
        return nil, false
    end
    if self.image_files[value] and Util.path_exists(self.image_files[value]) then
        return self.image_files[value], false
    end
    local file = Images.cached_file(self:platform(), value)
    if file then
        self.image_files[value] = file
        return file, false
    end
    return nil, Images.is_failed(value)
end

function App:load_next_readme_image()
    if not self.state.show_readme_images then
        self.readme_image_queue = {}
        self.readme_image_pending = {}
        self.readme_image_loading = false
        return
    end
    local value = table.remove(self.readme_image_queue, 1)
    if not value then
        self.readme_image_loading = false
        return
    end
    self:image_file_for(value)
    self.readme_image_pending[value] = nil
    self:refresh()
    UIManager:scheduleIn(0.05, function()
        self:load_next_readme_image()
    end)
end

function App:queue_readme_image(value)
    value = tostring(value or "")
    if not self.state.show_readme_images or value == "" or self.readme_image_pending[value] or Images.is_failed(value) then
        return
    end
    if self:cached_image_file(value) then
        return
    end
    self.readme_image_pending[value] = true
    table.insert(self.readme_image_queue, value)
    if self.readme_image_loading then
        return
    end
    self.readme_image_loading = true
    UIManager:nextTick(function()
        self:load_next_readme_image()
    end)
end

function App:package_icon_file(pkg)
    if is_zenpm_package(pkg) then
        local icon = Images.asset("zenpm.svg")
        return icon, true, icon, "zenpm"
    end
    local icon_value = Images.package_icon(pkg)
    local fallback_value = Images.package_fallback(pkg)
    local source = icon_value == fallback_value and "repo-fallback" or "package"
    local file = self:image_file_for(icon_value)
    if file then
        return file, icon_value == fallback_value, icon_value, source
    end
    return self:image_file_for(fallback_value), true, fallback_value, "fallback"
end

function App:package_featured_file(pkg)
    return self:image_file_for(Images.featured_image(pkg)) or self:package_icon_file(pkg)
end

function App:repo_icon_file(repo)
    return self:image_file_for(Images.repo_icon(repo)) or self:image_file_for(Images.asset("sources.svg"))
end

function App:scroll_key()
    if self.state.page == "source_details" and self.state.current_repo then
        return "source:" .. tostring(self.state.current_repo.name)
    end
    if self.state.page == "category_details" and self.state.current_category then
        return "category:" .. tostring(self.state.current_category.id)
    end
    if self.state.page == "package_details" and self.state.current_package then
        return "package:" .. tostring(self.state.current_package.id or self.state.current_package.name) .. ":" .. tostring(self.state.details_tab or "readme")
    end
    return self.state.page
end

function App:reset_scroll(key)
    self.state.scroll[key or self:scroll_key()] = 0
end

function App:navigate(tab_id)
    self._full_refresh = true
    if tab_id == "home" then
        self:show_featured()
    elseif tab_id == "categories" then
        self:show_categories()
    elseif tab_id == "sources" then
        self:show_sources()
    elseif tab_id == "installed" then
        self:show_installed()
    elseif tab_id == "debug" then
        self:show_debug()
    else
        self:show_search()
    end
    self._full_refresh = nil
end

function App:reload_current_page()
    if self.state.page == "package_details" and self.state.current_package then
        self:show_package_details(self.state.current_package.id or self.state.current_package.name, self.state.details_from, true, self.state.details_tab, self.state.current_package.patch_asset)
    elseif self.state.page == "category_details" and self.state.current_category then
        self:show_category_details(self.state.current_category.id)
    elseif self.state.page == "source_details" and self.state.current_repo then
        self:show_source_details(self.state.current_repo.name)
    else
        self:navigate(self.state.active_tab or "home")
    end
end

local function normalized_version(value)
    value = tostring(value or "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("^refs/tags/", "")
    value = value:gsub("^[vV]", "")
    return value
end

local function version_gt(a, b)
    a = normalized_version(a)
    b = normalized_version(b)
    local function parts(value)
        local out = {}
        for n in value:gmatch("%d+") do
            table.insert(out, tonumber(n) or 0)
        end
        return out
    end
    local ap, bp = parts(a), parts(b)
    local max = math.max(#ap, #bp)
    for i = 1, max do
        local av, bv = ap[i] or 0, bp[i] or 0
        if av > bv then return true end
        if av < bv then return false end
    end
    if max > 0 then return false end
    return a > b
end

local function platform_capabilities(value)
    local list, set = {}, {}
    for part in tostring(value or ""):gmatch("[^,]+") do
        local normalized = Util.trim(part):lower()
        if normalized ~= "" and not set[normalized] then
            set[normalized] = true
            table.insert(list, normalized)
        end
    end
    return list, set
end

local function package_matches_platforms(pkg, platforms)
    if type(pkg) ~= "table" or type(pkg.platforms) ~= "table" then
        return false
    end
    local required = 0
    for _, platform in ipairs(pkg.platforms) do
        local normalized = Util.trim(tostring(platform or "")):lower()
        if normalized ~= "" then
            required = required + 1
            if not platforms[normalized] then
                return false
            end
        end
    end
    for _, platform in ipairs(type(pkg.incompatible_platforms) == "table" and pkg.incompatible_platforms or {}) do
        local normalized = Util.trim(tostring(platform or "")):lower()
        if normalized ~= "" and platforms[normalized] then
            return false
        end
    end
    return required > 0
end

local function merge_compatible_packages(out, seen, packages, platforms)
    for _, pkg in ipairs(packages or {}) do
        local id = tostring(pkg.id or pkg.name or "")
        if id ~= "" and not seen[id] and package_matches_platforms(pkg, platforms) then
            seen[id] = true
            table.insert(out, pkg)
        end
    end
end

-- Serve the package catalog from an in-memory session cache. The Go daemon's
-- catalog already carries every field the UI needs, so once loaded we reuse it
-- across tab/filter/sort/detail navigation with no further /packages calls.
-- force=true (install/uninstall/refresh) or check_updates bypass the cache.
function App:load_packages(check_updates, force)
    if not force and not check_updates and self.state.packages and #self.state.packages > 0 then
        return true, self.state.packages
    end
    if not self.state.filter_installable then
        local ok, data = self.client:list_packages(nil, check_updates, self.state.beta_updates)
        if not ok then
            return false, {}, data
        end
        local packages = type(data) == "table" and data or {}
        self.state.packages = packages
        return true, packages
    end
    local filter = self:package_platforms()
    local capabilities, capability_set = platform_capabilities(filter)
    local ok, data = self.client:list_packages(filter, check_updates, self.state.beta_updates)
    if not ok then
        return false, {}, data
    end
    local packages = {}
    local seen = {}
    merge_compatible_packages(packages, seen, type(data) == "table" and data or {}, capability_set)
    if #packages > 0 or #capabilities <= 1 then
        self.state.packages = packages
        return true, packages
    end
    for _, platform in ipairs(capabilities) do
        ok, data = self.client:list_packages(platform, check_updates, self.state.beta_updates)
        if not ok then
            return false, {}, data
        end
        merge_compatible_packages(packages, seen, type(data) == "table" and data or {}, capability_set)
    end
    self.state.packages = packages
    return true, packages
end

function App:load_repos(force)
    if not force and self.state.repos and #self.state.repos > 0 then
        return true, self.state.repos
    end
    local ok, data = self.client:list_repos()
    if not ok then
        return false, {}, data
    end
    local repos = type(data) == "table" and data or {}
    self.state.repos = repos
    return true, repos
end

function App:show_featured()
    self.state.page = "home"
    self.state.active_tab = "home"
    if not self:ensure_backend() then return end
    self:set_loading(_("Loading featured packages..."))
    local t_load = socket.gettime()
    local ok, packages, err = self:load_packages()
    if not ok then
        self:set_error(_("Failed to load packages: ") .. tostring(err))
        return
    end
    self:log_timing("load_packages (catalog read)", t_load)
    self.state.packages = packages
    self.state.featured_packages = Models.select_featured(packages)
    self:clear_status()
    self:refresh()
    if self.t_open then
        self:log_timing("home rendered from cache (open -> paint)", self.t_open)
        self.t_open = nil
    end

    -- First run: catalog cache was empty and the backend is refreshing repos in
    -- the background. Poll until the DB results appear, then re-render.
    if #packages == 0 then
        UIManager:scheduleIn(0.05, function()
            if self.state.page ~= "home" then return end
            self:reload_featured_until_ready(1)
        end)
    end
end

-- Poll the catalog after a first-run background refresh until packages appear.
function App:reload_featured_until_ready(attempt)
    if self.state.page ~= "home" then return end
    local ok, packages = self:load_packages()
    if ok and #packages > 0 then
        self.state.packages = packages
        self.state.featured_packages = Models.select_featured(packages)
        self:refresh()
        if self.t_open then
            self:log_timing("home populated after refresh (open -> packages)", self.t_open)
            self.t_open = nil
        end
        return
    end
    if attempt >= Constants.MAX_POLL_RETRIES then return end
    UIManager:scheduleIn(Constants.POLL_DELAY_SECONDS, function()
        self:reload_featured_until_ready(attempt + 1)
    end)
end

function App:show_search()
    self.state.page = "search"
    self.state.active_tab = "search"
    if not self:ensure_backend() then return end
    self:set_loading(_("Loading packages..."))
    local ok, packages, err = self:load_packages()
    if not ok then
        self:set_error(_("Failed to load packages: ") .. tostring(err))
        return
    end
    self.state.packages = packages
    self.state.visible_packages = self:sorted_packages("search", Models.filter_packages(packages, self.state.filters.search))
    self:clear_status()
    self:refresh()
end

function App:show_categories()
    self.state.page = "categories"
    self.state.active_tab = "categories"
    if not self:ensure_backend() then return end
    self:set_loading(_("Loading categories..."))
    local ok, packages, err = self:load_packages()
    if not ok then
        self:set_error(_("Failed to load packages: ") .. tostring(err))
        return
    end
    local categories = Models.category_cards(packages)
    self.state.packages = packages
    self.state.categories = categories
    self.state.visible_categories = Models.filter_categories(categories, self.state.filters.categories)
    self.state.current_category = nil
    self:clear_status()
    self:refresh()
end

function App:show_category_details(category_id)
    self.state.page = "category_details"
    self.state.active_tab = "categories"
    if not self:ensure_backend() then return end
    self:set_loading(_("Loading category..."))
    local category = Models.category_for_id(category_id)
    if not category then
        self:set_error(_("Category not found."))
        return
    end
    local ok, packages, err = self:load_packages()
    if not ok then
        self:set_error(_("Failed to load packages: ") .. tostring(err))
        return
    end
    local category_packages = Models.packages_in_category(packages, category)
    self.state.packages = packages
    self.state.current_category = category
    self.state.category_packages = category_packages
    self.state.visible_packages = self:sorted_packages("category", Models.filter_packages(category_packages, self.state.filters.category))
    self:clear_status()
    self:refresh()
end

function App:show_installed()
    self.state.page = "installed"
    self.state.active_tab = "installed"
    if not self:ensure_backend() then return end
    self:set_loading(_("Loading installed packages..."))
    local ok, packages, err = self:load_packages()
    if not ok then
        self:set_error(_("Failed to load packages: ") .. tostring(err))
        return
    end
    local installed = Models.installed_packages(packages)
    self.state.packages = packages
    self.state.installed_packages = installed
    local visible = Models.filter_packages_by_category(installed, self.state.filters.installed)
    self.state.visible_packages = self:sorted_packages("installed", visible)
    self:clear_status()
    self:refresh()
end

function App:show_sources()
    self.state.page = "sources"
    self.state.active_tab = "sources"
    if not self:ensure_backend() then return end
    self:set_loading(_("Loading sources..."))
    local ok, repos, err = self:load_repos()
    if not ok then
        self:set_error(_("Failed to load sources: ") .. tostring(err))
        return
    end
    self.state.repos = self:sorted_repos(repos)
    self.state.current_repo = nil
    self:clear_status()
    self:refresh()
end

function App:show_source_details(name)
    self.state.page = "source_details"
    self.state.active_tab = "sources"
    if not self:ensure_backend() then return end
    self:set_loading(_("Loading source..."))
    local ok_repos, repos, repo_err = self:load_repos()
    if not ok_repos then
        self:set_error(_("Failed to load source: ") .. tostring(repo_err))
        return
    end
    local repo = Util.table_find(repos, function(r) return r.name == name end)
    if not repo then
        self:set_error(_("Source not found."))
        return
    end
    local ok_pkgs, packages, pkg_err = self:load_packages()
    if not ok_pkgs then
        self:set_error(_("Failed to load packages: ") .. tostring(pkg_err))
        return
    end
    local visible = {}
    for _, pkg in ipairs(packages) do
        if pkg.repo == repo.name then
            table.insert(visible, pkg)
        end
    end
    self.state.repos = repos
    self.state.packages = packages
    self.state.current_repo = repo
    self.state.visible_packages = self:sorted_packages("source", Models.filter_packages(visible, self.state.filters.source))
    self:clear_status()
    self:refresh()
end

function App:show_package_details(package_id, from_tab, force_reload, details_tab, patch_asset)
    if self.state.page ~= "package_details" then
        self.state.details_origin = {
            page = self.state.page,
            tab = self.state.active_tab,
            repo = self.state.current_repo,
            category = self.state.current_category,
        }
    end
    self.state.page = "package_details"
    self.state.active_tab = from_tab or self.state.active_tab or "search"
    self.state.details_from = from_tab or self.state.active_tab or "search"
    if not self:ensure_backend() then return end
    -- Catalog already carries every field the details view needs (description,
    -- author, images, icons). load_packages serves from the in-memory session
    -- cache, so this is a local lookup with no network round-trip unless a
    -- force_reload (post install/uninstall/refresh) invalidates the cache.
    local ok, packages, err = self:load_packages(false, force_reload)
    if not ok then
        self:set_error(_("Failed to load package: ") .. tostring(err))
        return
    end
    local pkg = Models.find_package(packages, package_id)
    if not pkg then
        self:set_error(_("Package not found."))
        return
    end
    -- For an installed patch item, show the patch itself (not its parent package):
    -- rebuild the single-asset item so the title, card and modify menu act on the patch.
    if type(patch_asset) == "string" and patch_asset ~= "" and Models.is_patch_package(pkg) then
        pkg = Models.installed_patch_item(pkg, patch_asset)
    end
    self.state.packages = packages
    local cache_key = tostring(pkg.id or pkg.name or "")
    if Models.has_readme(pkg) and cache_key ~= "" then
        local cached = self.state.readme_cache[cache_key]
        if cached == nil then
            local readme_ok, data, status_code = self.client:get_package_readme(cache_key)
            if readme_ok and type(data) == "table" and type(data.readme) == "string" then
                cached = {
                    readme = data.readme,
                    base_url = data.readme_base_url,
                    image_base_url = data.readme_image_base_url,
                }
            elseif not readme_ok then
                local error_code = content_load_error_code(status_code, data)
                log_content_load_error("README", cache_key, data, error_code)
                cached = { error_code = error_code }
            else
                cached = {}
            end
            self.state.readme_cache[cache_key] = cached
        end
        if type(cached) == "table" then
            pkg.readme = cached.readme
            pkg.readme_base_url = cached.base_url
            pkg.readme_image_base_url = cached.image_base_url
            pkg.readme_error_code = cached.error_code
        end
    end
    local selected_tab = "readme"
    if details_tab == "release_notes" and Models.has_release_notes(pkg, self.state.beta_updates) then
        selected_tab = "release_notes"
        self:load_package_release_notes(pkg)
    elseif details_tab == "patches" and Models.is_patch_package(pkg) and #Models.package_assets(pkg) > 0 then
        selected_tab = "patches"
    end
    self.state.current_package = pkg
    self.state.details_tab = selected_tab
    self.state.details_featured_expanded = false
    self:reset_scroll("package:" .. cache_key .. ":" .. self.state.details_tab)
    self:clear_status()
    self:refresh()
end

function App:set_package_details_tab(tab)
    local pkg = self.state.current_package or {}
    if tab == "release_notes" and Models.has_release_notes(pkg, self.state.beta_updates) then
        self:load_package_release_notes(pkg)
    elseif tab == "patches" and Models.is_patch_package(pkg) and #Models.package_assets(pkg) > 0 then
        -- Keep the requested patch tab.
    else
        tab = "readme"
    end
    if self.state.details_tab == tab then
        return
    end
    self.state.details_tab = tab
    self:reset_scroll()
    self:refresh()
end

function App:load_package_release_notes(pkg)
    local package_id = tostring(pkg and (pkg.id or pkg.name) or "")
    if package_id == "" then return end
    local notes_url = Models.release_notes_url(pkg, self.state.beta_updates)
    if notes_url == "" then return end
    local prerelease = self.state.beta_updates and notes_url == tostring(pkg.prerelease_notes_url or "")
    self.state.release_notes_cache = self.state.release_notes_cache or {}
    local cache_key = package_id .. ":" .. notes_url
    local cached = self.state.release_notes_cache[cache_key]
    if cached == nil then
        Modals.status(_("Loading release notes..."))
        local ok, data, status_code = self.client:get_package_release_notes(package_id, prerelease)
        Modals.close_status()
        if not ok then
            local error_code = content_load_error_code(status_code, data)
            log_content_load_error("release notes", package_id, data, error_code)
            cached = { error_code = error_code }
        else
            cached = type(data) == "table" and {
                body = tostring(data.release_notes or ""),
                tag = tostring(data.version or ""),
                base_url = tostring(data.release_notes_base_url or ""),
                image_base_url = tostring(data.release_notes_image_base_url or ""),
            } or {}
        end
        self.state.release_notes_cache[cache_key] = cached
    end
    pkg.release_notes = cached.body or ""
    pkg.release_notes_tag = cached.tag or ""
    pkg.release_notes_base_url = cached.base_url or ""
    pkg.release_notes_image_base_url = cached.image_base_url or ""
    pkg.release_notes_error_code = cached.error_code
end

function App:go_back_from_details()
    local origin = self.state.details_origin
    self.state.details_origin = nil
    if origin then
        if origin.page == "source_details" and origin.repo then
            self.state.current_repo = origin.repo
            self:show_source_details(origin.repo.name)
            return
        elseif origin.page == "category_details" and origin.category then
            self.state.current_category = origin.category
            self:show_category_details(origin.category.id)
            return
        end
    end
    self:navigate(self.state.details_from or "search")
end

function App:show_debug()
    self.state.page = "debug"
    self.state.active_tab = "debug"
    if not self:ensure_backend() then return end
    self:set_loading(_("Loading log..."))
    local ok, log_text = self.client:get_log(500)
    if not ok then
        self:set_error(_("Could not read log: ") .. tostring(log_text))
        self.state.log_lines = {}
        return
    end
    log_text = tostring(log_text or ""):gsub("%d%d%d%d%-%d%d%-%d%dT(%d%d:%d%d):%d%dZ", "%1")
    log_text = Util.reverse_lines(log_text)
    if log_text == "" then
        log_text = _("Log is empty.")
    end
    self.state.log_lines = Util.split_lines(log_text)
    self:clear_status()
    self:refresh()
end

function App:sorted_packages(kind, packages)
    return Models.sort_packages(packages, self.state.sorts[kind])
end

function App:sorted_repos(repos)
    return Models.sort_repos(repos, self.state.sorts.sources)
end

function App:set_filter(kind, value)
    self.state.filters[kind] = value or ""
    if kind == "categories" then
        self:reset_scroll("categories")
    elseif kind == "category" and self.state.current_category then
        self:reset_scroll("category:" .. tostring(self.state.current_category.id))
    elseif kind == "source" and self.state.current_repo then
        self:reset_scroll("source:" .. tostring(self.state.current_repo.name))
    else
        self:reset_scroll("search")
    end
    if kind == "categories" then
        self:show_categories()
    elseif kind == "category" and self.state.current_category then
        self:show_category_details(self.state.current_category.id)
    elseif kind == "source" and self.state.current_repo then
        self:show_source_details(self.state.current_repo.name)
    else
        self:show_search()
    end
end

function App:set_sort(kind, value)
    self.state.sorts[kind] = value or "stars"
    App.save_setting("sorts", self.state.sorts)
    self:reset_scroll(self:scroll_key())
    if kind == "installed" then
        self:show_installed()
    elseif kind == "sources" then
        self:show_sources()
    elseif kind == "category" and self.state.current_category then
        self:show_category_details(self.state.current_category.id)
    elseif kind == "source" and self.state.current_repo then
        self:show_source_details(self.state.current_repo.name)
    else
        self:show_search()
    end
end

function App:set_installed_category_filter(category_id)
    local category = Models.category_for_id(category_id)
    self.state.filters.installed = category and category.id or ""
    self:reset_scroll("installed")
    self:show_installed()
end

function App:prompt_installed_category_filter()
    local current = self.state.filters.installed or ""
    local rows = {
        {
            text = _("All categories"),
            checked_func = function() return current == "" end,
            callback = function() self:set_installed_category_filter("") end,
        },
    }
    for _, category in ipairs(Models.category_cards(self.state.installed_packages)) do
        if category.count > 0 then
            local item = category
            table.insert(rows, {
                text = Models.category_label(item) .. " (" .. tostring(item.count) .. ")",
                checked_func = function() return current == item.id end,
                callback = function() self:set_installed_category_filter(item.id) end,
            })
        end
    end
    Modals.actions(_("Filter by category"), rows, { show_cancel = false, align = "left" })
end

function App:prompt_sort(kind)
    local current = self.state.sorts[kind] or "stars"
    local title = kind == "sources" and _("Sort sources") or _("Sort packages")
    local function selected(key)
        return function() return current == key end
    end
    if kind == "installed" or kind == "sources" then
        local rows = {
            {
                icon = "sort_asc",
                text = _("Title (A-Z)"),
                checked_func = selected("name_asc"),
                callback = function() self:set_sort(kind, "name_asc") end,
            },
            {
                icon = "sort_desc",
                text = _("Title (Z-A)"),
                checked_func = selected("name_desc"),
                callback = function() self:set_sort(kind, "name_desc") end,
            },
        }
        if kind == "installed" then
            table.insert(rows, {
                icon = "date",
                text = _("Installed date (newest first)"),
                checked_func = selected("installed_at_desc"),
                callback = function() self:set_sort(kind, "installed_at_desc") end,
            })
            table.insert(rows, {
                icon = "date",
                text = _("Installed date (oldest first)"),
                checked_func = selected("installed_at_asc"),
                callback = function() self:set_sort(kind, "installed_at_asc") end,
            })
        end
        Modals.actions(title, rows, { show_cancel = false, align = "left" })
        return
    end
    local rows = {
        {
            icon = "star",
            text = _("Stars"),
            checked_func = selected("stars"),
            callback = function() self:set_sort(kind, "stars") end,
        },
        {
            icon = "sort_asc",
            text = _("Name"),
            checked_func = selected("name"),
            callback = function() self:set_sort(kind, "name") end,
        },
    }
    if kind == "search" then
        table.insert(rows, 2, {
            icon = "date",
            text = _("Recently updated"),
            checked_func = selected("published_at_desc"),
            callback = function() self:set_sort(kind, "published_at_desc") end,
        })
    end
    Modals.actions(title, rows, { show_cancel = false, align = "left" })
end

function App:prompt_filter(kind)
    local title = _("Search packages")
    local hint = _("Search...")
    if kind == "categories" then
        title = _("Search categories")
        hint = _("Search categories...")
    elseif kind == "category" then
        title = _("Search category")
        hint = _("Search category...")
    elseif kind == "source" then
        title = _("Search source")
        hint = _("Search source...")
    end
    Modals.search(title, self.state.filters[kind] or "", hint, function(text)
        self:set_filter(kind, Util.trim(text))
    end)
end

function App:prompt_add_source()
    Modals.input(_("Add Source"), "", "https://example.com/repo", _("Add"), function(url)
        self:add_source(Util.trim(url))
    end)
end

function App:add_source(url)
    if url == "" then
        Modals.info(_("Please enter a URL."))
        return
    end
    Modals.info(_("Detecting repo..."))
    local name, err = self:detect_repo_name(url)
    if not name then
        Modals.info(err or _("Could not detect repo format."))
        return
    end
    local ok, data = self.client:add_repo(name, url)
    if ok then
        self:show_sources()
    else
        Modals.info(_("Could not add source: ") .. tostring(data))
    end
end

function App:detect_repo_name(url)
    local base = url:gsub("/+$", "") .. "/"
    local ok, data = self.client:request("GET", base .. "manifest.json", nil)
    if ok and type(data) == "table" and type(data.repo) == "table" and data.repo.name then
        return data.repo.name
    end

    ok, data = self.client:request("GET", base .. "registry.json", nil)
    if ok and type(data) == "table" then
        local kf_host = Constants.REPO_KINDLEFORGE_URL:gsub("^https?://", ""):gsub("/+$", "")
        if url:find(kf_host, 1, true) then
            return Constants.REPO_KINDLEFORGE_NAME
        end
        if data[1] and data[1].uri then
            return tostring(data[1].uri):match("^([^/]+)") or data[1].uri
        end
    end

    return nil, _("Could not detect repo format.")
end

function App:confirm_remove_source(name)
    Modals.confirm(_("Remove source ") .. I18n.dynamic_or(name, _("Source")) .. "?", _("Remove"), function()
        local ok, data = self.client:remove_repo(name)
        if ok then
            self:show_sources()
        else
            Modals.info(_("Could not remove source: ") .. tostring(data))
        end
    end)
end

function App:perform_package_action(pkg, on_done)
    if self.busy then
        Modals.info(_("Another operation is in progress. Please wait."))
        return
    end
    if Models.is_unmanaged_patch(pkg) then
        self:show_unmanaged_patch_modify(pkg, on_done)
        return
    end
    if Models.is_installed_patch_item(pkg) then
        self:show_patch_modify(pkg, on_done)
        return
    end
    if Models.is_patch_package(pkg) then
        -- Patch packages manage individual files; the details page lists each
        -- patch with a per-file install/uninstall toggle.
        self:show_package_details(pkg.id or pkg.name, self.state.active_tab, false, "patches")
        return
    end
    if pkg.installed then
        local is_koplugin = package_is_koreader_plugin(pkg)
        Modals.package_modify(pkg, {
            title_icon = self:package_icon_file(pkg),
            info = self.state.page ~= "package_details" and function()
                self:show_package_details(pkg.id or pkg.name, self.state.active_tab)
            end or nil,
            update = pkg.update_available and function()
                self:confirm_package_action(pkg, "update", on_done)
            end or nil,
            disabled = is_koplugin and is_plugin_disabled(pkg) or nil,
            enable_disable = is_koplugin and function()
                self:confirm_toggle_enable(pkg, "plugin", on_done)
            end or nil,
            downgrade = Models.has_version_history(pkg) and not Models.is_font_package(pkg) and function()
                self:prompt_package_versions(pkg, on_done)
            end or nil,
            uninstall = function()
                self:confirm_package_action(pkg, "uninstall", on_done)
            end,
        })
    elseif Models.has_version_history(pkg) and not Models.is_font_package(pkg) then
        self:prompt_default_package_version(pkg, on_done, "install")
    else
        self:confirm_package_action(pkg, "install", on_done)
    end
end

function App:show_unmanaged_patch_modify(pkg, on_done)
    local asset = pkg.patch_asset
    Modals.package_modify(pkg, {
        title_icon = self:package_icon_file(pkg),
        manage_only = true,
        disabled = is_patch_disabled(pkg),
        enable_disable = function()
            self:confirm_toggle_enable(pkg, "patch", on_done)
        end,
        uninstall = function()
            self:confirm_remove_unmanaged_patch(asset, on_done)
        end,
    })
end

function App:show_patch_modify(pkg, on_done)
    local asset = pkg.patch_asset
    Modals.package_modify(pkg, {
        title_icon = self:package_icon_file(pkg),
        info = self.state.page ~= "package_details" and function()
            self:show_package_details(pkg.id or pkg.name, self.state.active_tab)
        end or nil,
        disabled = is_patch_disabled(pkg),
        enable_disable = function()
            self:confirm_toggle_enable(pkg, "patch", on_done)
        end,
        uninstall = function()
            self:confirm_patch_item_action(pkg, "uninstall", asset, on_done)
        end,
    })
end

-- Report whether a package is currently disabled the native KOReader way.
-- Dispatches to the plugin (plugins_disabled) or patch (.disabled file) check.
-- Returns false for anything that can't be toggled.
function App:package_disabled(pkg)
    if Models.is_installed_patch_item(pkg) then
        return is_patch_disabled(pkg)
    end
    if package_is_koreader_plugin(pkg) then
        return is_plugin_disabled(pkg)
    end
    return false
end

-- Toggle enable/disable natively (settings flag for plugins, file rename for
-- patches). No backend call — the change is local — so on success we prompt a
-- restart, which is when KOReader actually applies plugin/patch state.
function App:confirm_toggle_enable(pkg, kind, on_done)
    if self.busy then
        Modals.info(_("Another operation is in progress. Please wait."))
        return
    end
    local disabled = self:package_disabled(pkg)
    local name = Models.package_display_name(pkg, _("Package"))
    local verb = disabled and _("enable") or _("disable")
    local label = disabled and _("Enable") or _("Disable")
    Modals.confirm(
        _("Are you sure you want to ") .. verb .. " " .. name .. "?",
        label,
        function()
            local ok, err
            if kind == "patch" then
                ok, err = set_patch_disabled(pkg.patch_asset, not disabled)
            else
                ok, err = set_plugin_disabled(pkg, not disabled)
            end
            if not ok then
                Modals.info_for(_("Could not ") .. verb .. " " .. name .. ": " .. tostring(err),
                    Constants.PACKAGE_NOTICE_SECONDS)
                return
            end
            local done = disabled and _("enabled") or _("disabled")
            Modals.restart_koreader(
                name .. " " .. done .. _(" successfully.\n\nRestart KOReader to apply the change."),
                function() self:restart_koreader() end)
            if on_done then on_done() end
        end
    )
end

function App:confirm_patch_item_action(pkg, action, asset, on_done)
    local name = tostring(asset or pkg.patch_asset or pkg.name or "")
    if name == "" then
        Modals.info(_("Patch has no file name."))
        return
    end
    self:queue_package_action(pkg, action, name, nil)
end

function App:confirm_remove_unmanaged_patch(asset, on_done)
    Modals.confirm(
        _("Are you sure you want to remove ") .. tostring(asset) .. "?",
        _("Remove"),
        function()
            local ok, err = remove_patch_file(asset)
            if not ok then
                Modals.info_for(_("Could not remove patch: ") .. tostring(err), Constants.PACKAGE_NOTICE_SECONDS)
                return
            end
            if on_done then on_done() end
            self:show_installed()
        end
    )
end

-- Show installable cached releases for a package. Each version maps to an
-- update/reinstall/downgrade action based on its relation to the installed
-- version. Prereleases are hidden unless the user enabled ZenPM beta updates.
-- The list is paged VERSIONS_PER_PAGE at a time in the UI.
local VERSIONS_PER_PAGE = 5

local function version_action(current, tag)
    if current == nil or current == "" then return "install" end
    if version_gt(tag, current) then return "update" end
    if version_gt(current, tag) then return "downgrade" end
    return "reinstall"
end

function App:load_package_releases(pkg)
    Modals.status(_("Loading available versions..."))
    local ok, data = self.client:get_package_releases(pkg.id or pkg.name)
    Modals.close_status()
    if not ok then
        Modals.info(_("Could not load available versions: ") .. tostring(data))
        return
    end
    local allow_prerelease = self.state.beta_updates
    local releases = {}
    for _, release in ipairs(type(data) == "table" and data.releases or {}) do
        if release.tag_name and (allow_prerelease or not release.prerelease) then
            table.insert(releases, release)
        end
    end
    if #releases == 0 then
        Modals.info(_("No installable versions were found."))
        return nil
    end
    return releases
end

function App:prompt_package_versions(pkg, on_done)
    local current = pkg.installed and (pkg.installed_version or pkg.version or "") or ""
    local releases = self:load_package_releases(pkg)
    if not releases then return end
    self:show_versions_page(pkg, releases, current, 1, on_done)
end

function App:prompt_latest_package_build(pkg, on_done, action)
    local releases = self:load_package_releases(pkg)
    if not releases then return end
    self:choose_version_release(pkg, releases[1], action or "install", on_done)
end

function App:prompt_default_package_version(pkg, on_done, action)
    if self.state.manual_version_picker then
        self:prompt_package_versions(pkg, on_done)
        return
    end
    self:prompt_latest_package_build(pkg, on_done, action)
end

function App:show_versions_page(pkg, releases, current, page, on_done)
    local rows = {}
    local start_index = (page - 1) * VERSIONS_PER_PAGE + 1
    local last_index = math.min(start_index + VERSIONS_PER_PAGE - 1, #releases)
    for i = start_index, last_index do
        local release = releases[i]
        local action = version_action(current, release.tag_name)
        local label = tostring(release.tag_name)
        if not pkg.installed and i == 1 then
            label = label .. " (" .. _("Latest") .. ")"
        elseif action == "reinstall" then
            label = label .. " (" .. _("installed") .. ")"
        end
        if release.prerelease then
            label = label .. " (" .. _("prerelease") .. ")"
        end
        rows[#rows + 1] = {
            text = label,
            callback = function()
                self:choose_version_release(pkg, release, action, on_done)
            end,
        }
    end
    if last_index < #releases then
        rows[#rows + 1] = {
            text = _("Show more") .. " (" .. tostring(#releases - last_index) .. ")",
            callback = function()
                self:show_versions_page(pkg, releases, current, page + 1, on_done)
            end,
        }
    end
    Modals.actions(package_title(pkg, pkg.id or pkg.name) .. ": " .. _("Versions"), rows, { align = "left" })
end

function App:choose_version_release(pkg, release, action, on_done)
    local assets = type(release.assets) == "table" and release.assets or {}
    local rows = {}
    for _, asset in ipairs(assets) do
        if asset.name and asset.name ~= "" then
            table.insert(rows, {
                text = asset.name,
                asset = asset.name,
                callback = function()
                    self:confirm_package_version(pkg, release.tag_name, action, asset.name, on_done)
                end,
            })
        end
    end
    if #rows == 0 then
        Modals.info(_("This release has no ZIP assets."))
        return
    end
    if #rows == 1 then
        self:confirm_package_version(pkg, release.tag_name, action, rows[1].asset, on_done)
        return
    end
    if not self.state.show_all_builds then
        self:confirm_package_version(pkg, release.tag_name, action, nil, on_done)
        return
    end
    Modals.actions(_("Choose a build for ") .. tostring(release.tag_name), rows)
end

function App:confirm_package_version(pkg, release_tag, action, asset, on_done)
    if pkg.installed and is_zenpm_package(pkg) then
        self:queue_self_reinstall(pkg, release_tag)
        return
    end
    self:queue_package_action(pkg, action, asset, { release = release_tag })
end

function App:confirm_package_action(pkg, action, on_done)
    local opts = action == "update" and pkg.latest_release and not Models.is_font_package(pkg)
        and { release = pkg.latest_release } or nil
    self:start_package_action(pkg, action, on_done, opts)
end

function App:start_package_action(pkg, action, on_done, opts)
    local id = pkg.id or pkg.name
    if not id then
        Modals.info(_("Package has no id."))
        return
    end
    if action == "update" and is_zenpm_package(pkg) then
        self:queue_self_update(pkg)
        return
    end
    if action_installs_package(action) and opts and opts.release then
        self:queue_package_action(pkg, action, nil, opts)
        return
    end
    if action_installs_package(action) then
        -- Fonts use the catalog's explicit ZIP URL. Cached release assets do
        -- not describe installable font builds, so never invoke either chooser.
        if Models.is_font_package(pkg) then
            self:queue_package_action(pkg, action, nil, opts)
            return
        end
        local ok, info = self.client:get_package_assets(id)
        local has_candidates = type(info) == "table" and info.needs_choice
            and type(info.candidates) == "table" and #info.candidates > 0
        if not ok then
            if Models.has_version_history(pkg) then
                self:prompt_default_package_version(pkg, on_done, action)
                return
            end
            Modals.info(_("Could not determine which build to install: ") .. tostring(info))
            return
        end
        if Models.has_version_history(pkg)
            and (type(info) ~= "table" or ((not info.auto or info.auto == "") and not has_candidates)) then
            self:prompt_default_package_version(pkg, on_done, action)
            return
        end
        if has_candidates then
            self:choose_package_asset(pkg, action, info.candidates, on_done, opts)
            return
        end
    end
    self:queue_package_action(pkg, action, nil, opts)
end

function App:choose_package_asset(pkg, action, candidates, on_done, opts)
    local rows = {}
    for _, asset in ipairs(candidates) do
        local name = asset.asset
        if name and name ~= "" then
            local label = name
            if asset.arch and asset.arch ~= "" then
                label = tostring(asset.arch) .. " — " .. name
            end
            table.insert(rows, {
                text = label,
                callback = function()
                    local queued = self:queue_package_action(pkg, action, name, opts)
                    if opts and opts.on_queued then opts.on_queued(queued) end
                end,
            })
        end
    end
    if #rows == 0 then
        local queued = self:queue_package_action(pkg, action, nil, opts)
        if opts and opts.on_queued then opts.on_queued(queued) end
        return
    end
    local title = Models.is_patch_package(pkg)
        and (_("Choose a patch for ") .. package_title(pkg, pkg.id or pkg.name))
        or (_("Choose a build for ") .. package_title(pkg, pkg.id or pkg.name))
    Modals.actions(title, rows, { cancel_callback = opts and opts.on_cancel })
end

function App:confirm_package_asset_action(pkg, asset, on_done)
    if self.busy then
        Modals.info(_("Another operation is in progress. Please wait."))
        return
    end
    if not asset or not asset.asset or asset.asset == "" then
        Modals.info(_("Patch has no file name."))
        return
    end
    local patch_name = tostring(asset.asset)
    if Models.patch_file_installed(pkg, patch_name) then
        self:queue_package_action(pkg, "uninstall", patch_name, nil)
        return
    end
    self:queue_package_action(pkg, "install", patch_name, nil)
end

function App:run_package_action(pkg, action, asset, on_done, opts)
    local backend_action = backend_action_for(action)
    local id = pkg.id or pkg.name
    local failure_baseline = self:package_action_failure_stats({
        id = id,
        action = action,
    })
    local is_patch = Models.is_patch_package(pkg)
    local font_reset = action == "uninstall" and Models.is_font_package(pkg)
        and reset_active_font_before_uninstall(pkg)
    if font_reset then
        self:defer_font_uninstall(pkg, asset)
        return
    end
    local display_name = is_patch and asset and asset ~= ""
        and (_("patch") .. " " .. tostring(asset))
        or package_title(pkg, id)
    self.busy = true
    Modals.status((opts and opts.status_prefix or "") .. action_progress(action) .. " "
        .. display_name .. "\n\n" .. action_progress(action) .. _("... Please wait."))
    local ok, err = self.client:package_action(id, backend_action, asset, opts and opts.release or nil)
    if not ok then
        self.busy = false
        local message = _("Failed to start package action: ") .. tostring(err)
        if opts and opts.on_result then
            opts.on_result(false, message)
        else
            Modals.info_for(message, Constants.PACKAGE_ERROR_NOTICE_SECONDS)
        end
        return
    end
    self:poll_package_action({
        id = id,
        name = display_name,
        action = action,
        asset = asset,
        is_patch = is_patch,
        patch_was_installed = is_patch and Models.patch_file_installed(pkg, asset) or false,
        was_installed = pkg.installed and true or false,
        target_version = opts and opts.release or pkg.latest_version,
        prompt_restart = font_reset or (package_is_koreader_plugin(pkg) or is_patch)
            and (action_installs_package(action) or action == "uninstall"),
        settings_deleter = opts and opts.settings_deleter or nil,
        failure_baseline = failure_baseline,
        on_done = on_done,
        on_result = opts and opts.on_result or nil,
    }, 1)
end

function App:package_action_failure_stats(op)
    local ok, log_text = self.client:get_log(200)
    if not ok or type(log_text) ~= "string" then
        return 0, nil
    end
    local needle = "Package " .. tostring(op.id) .. " " .. backend_action_for(op.action) .. " failed: "
    local count = 0
    local detail = nil
    for _, line in ipairs(Util.split_lines(log_text)) do
        local pos = line:find(needle, 1, true)
        if pos then
            count = count + 1
            detail = line:sub(pos + #needle)
        end
    end
    detail = detail and Util.trim(detail) ~= "" and Util.trim(detail) or nil
    return count, detail
end

function App:package_action_failure_detail(op)
    local count, detail = self:package_action_failure_stats(op)
    if count > (op.failure_baseline or 0) then
        return detail or _("Check the debug log for details.")
    end
    return nil
end

function App:package_action_succeeded(op, pkg)
    if op.is_patch and op.asset and op.asset ~= "" then
        local now_installed = Models.patch_file_installed(pkg, op.asset)
        if op.action == "uninstall" then
            return op.patch_was_installed and not now_installed
        end
        return now_installed
    end
    if op.action == "uninstall" then
        return op.was_installed and (not pkg or not pkg.installed)
    end
    if op.action == "update" then
        if not pkg or not pkg.installed then
            return false
        end
        if op.target_version and op.target_version ~= "" then
            return not version_gt(op.target_version, pkg.installed_version or pkg.version)
        end
        return true
    end
    if op.action == "downgrade" then
        return pkg and pkg.installed
            and normalized_version(pkg.installed_version or "") == normalized_version(op.target_version or "")
    end
    if op.action == "reinstall" then
        return pkg and pkg.installed
    end
    return pkg and pkg.installed
end

function App:patch_action_succeeded_from_db(op)
    if not (op.is_patch and op.asset and op.asset ~= "") then
        return false
    end
    local ok, data = self.client:list_packages(nil, false)
    if not ok or type(data) ~= "table" then
        return false
    end
    local pkg = Models.find_package(data, op.id)
    local now_installed = Models.patch_file_installed(pkg, op.asset)
    if op.action == "uninstall" then
        return op.patch_was_installed and not now_installed
    end
    return now_installed
end

function App:poll_package_action(op, attempt)
    UIManager:scheduleIn(Constants.POLL_DELAY_SECONDS, function()
        local detail = self:package_action_failure_detail(op)
        if detail then
            self.busy = false
            if op.on_result then
                op.on_result(false, detail, op)
            else
                Modals.info_for(action_present(op.action) .. " " .. _("of") .. " " .. op.name .. " failed.\n\n" .. detail, Constants.PACKAGE_ERROR_NOTICE_SECONDS)
            end
            return
        end

        -- Force a fresh catalog read each tick: the session cache would mask the
        -- install/uninstall status change we're polling for. On success this also
        -- leaves state.packages holding the updated status for the list/detail view.
        local ok, packages = self:load_packages(false, true)
        if not ok then
            if attempt >= Constants.MAX_POLL_RETRIES then
                self.busy = false
                local message = _("Package operation status could not be checked. See Debug log.")
                if op.on_result then
                    op.on_result(false, message, op)
                else
                    Modals.info_for(message, Constants.PACKAGE_ERROR_NOTICE_SECONDS)
                end
                return
            end
            self:poll_package_action(op, attempt + 1)
            return
        end

        local pkg = Models.find_package(packages, op.id)
        local succeeded = self:package_action_succeeded(op, pkg)
        if not succeeded then
            succeeded = self:patch_action_succeeded_from_db(op)
        end

        if succeeded then
            self.busy = false
            local done = action_done(op.action)
            if op.on_result then
                op.on_result(true, nil, op)
                return
            end
            local finish = function()
                if op.prompt_restart then
                    local tail = _(" successfully.\n\nRestart KOReader to load the plugin.")
                    if op.is_patch or op.action == "uninstall" then
                        tail = _(" successfully.\n\nRestart KOReader to apply the change.")
                    end
                    Modals.restart_koreader(op.name .. " " .. done .. tail, function()
                        self:restart_koreader()
                    end)
                else
                    Modals.info_for(op.name .. " " .. done .. _(" successfully."), Constants.PACKAGE_NOTICE_SECONDS)
                end
                if op.on_done then op.on_done() end
            end
            if op.action == "uninstall" and type(op.settings_deleter) == "function" then
                Modals.plugin_settings_cleanup(op.name .. " " .. done .. _(" successfully.\n\nRemove plugin settings?"), function(remove_settings)
                    if remove_settings then
                        op.settings_deleter()
                    end
                    finish()
                end)
                return
            end
            finish()
        elseif attempt >= Constants.MAX_POLL_RETRIES then
            self.busy = false
            detail = self:package_action_failure_detail(op)
            local message = action_present(op.action) .. " " .. _("of") .. " " .. op.name .. " did not complete."
            if detail then
                message = message .. "\n\n" .. detail
            else
                message = action_present(op.action) .. " " .. _("of") .. " " .. op.name .. _(" did not complete.\n\nCheck the debug log for details.")
            end
            if op.on_result then
                op.on_result(false, message, op)
            else
                Modals.info_for(message, Constants.PACKAGE_ERROR_NOTICE_SECONDS)
            end
        else
            self:poll_package_action(op, attempt + 1)
        end
    end)
end

function App:refresh_repos()
    Modals.status(_("Refreshing repositories..."))
    local ok, err, status_code = self.client:refresh_repos()
    Modals.close_status()
    if not ok then
        -- A refresh failure from the local backend can contain the upstream
        -- HTTP status too; prefer it over the local HTTP 500 response.
        for code in tostring(err or ""):gmatch("HTTP%s+(%d%d%d)") do
            status_code = code
        end
        local message = _("Refresh failed")
        if status_code then
            message = message .. " (HTTP " .. tostring(status_code) .. ")"
        end
        Modals.info_for(message, Constants.PACKAGE_ERROR_NOTICE_SECONDS)
        return
    end

    self.image_files = {}
    Images.invalidate_cache()
    local found, packages = self:load_packages(false, true)
    self:load_repos(true)
    self:reload_current_page()
    if found then
        Modals.info_for(string.format(_("Updated: %d packages"), #packages), Constants.PACKAGE_NOTICE_SECONDS)
    else
        Modals.info_for(_("Packages updated"), Constants.PACKAGE_NOTICE_SECONDS)
    end
end

function App:scan_installed_plugins()
    Modals.status(_("Scanning installed plugins..."))
    local ok, data = self.client:scan_installed_plugins()
    Modals.close_status()
    if not ok then
        Modals.info(_("Plugin scan failed: ") .. tostring(data))
        return
    end

    self.state.packages = {}
    self:load_packages(false, true)
    if self.state.page == "settings" then
        self.settings_requires_reload = true
        self:refresh()
    else
        self:reload_current_page()
    end
    Modals.info_for(string.format(_("Found %d installed plugins"), tonumber(data.scanned) or tonumber(data.matched) or 0), Constants.PACKAGE_NOTICE_SECONDS)
end

function App:install_to_kindle_homepage()
    if self.busy then return end
    Modals.confirm(
        _("Download and copy the latest standalone ZenPM release to the Kindle homepage? This adds a ZenPM scriptlet (book) to the Kindle Home/Library"),
        _("Install"),
        function() self:apply_kindle_homepage_install() end,
        true
    )
end

function App:apply_kindle_homepage_install()
    if self.busy then return end
    self.busy = true
    local status = Modals.status(_("Copying ZenPM to Kindle homepage..."))
    UIManager:forceRePaint()
    self:run_update_task(function()
        return pcall(Updater.install_kindle_standalone, Updater, self.daemon, self.state.beta_updates, true)
    end, status, function(completed, called, ok, result)
        self.busy = false
        Modals.close_status()
        if not completed then
            Modals.info(_("Kindle homepage installation was cancelled."))
            return
        end
        if not called then
            Modals.info(_("Kindle homepage installation failed: ") .. tostring(ok))
            return
        end
        if not ok then
            Modals.info(_("Kindle homepage installation failed: ") .. tostring(result))
            return
        end
        Modals.info(_("ZenPM v") .. tostring(result) .. _(" was copied to the Kindle homepage."))
    end)
end

function App:toggle_filter_installable()
    self.state.filter_installable = not self.state.filter_installable
    App.save_setting("filter_installable", self.state.filter_installable)
    self.state.packages = {}
    if self.state.page == "settings" then
        self.settings_requires_reload = true
        self:refresh()
        return
    end
    self:reload_current_page()
end

function App:toggle_manual_version_picker()
    self.state.manual_version_picker = not self.state.manual_version_picker
    App.save_setting("manual_version_picker", self.state.manual_version_picker)
end

function App:toggle_show_all_builds()
    self.state.show_all_builds = not self.state.show_all_builds
    App.save_setting("show_all_builds", self.state.show_all_builds)
end

function App:toggle_beta_updates()
    self.state.beta_updates = not self.state.beta_updates
    App.save_setting("beta_updates", self.state.beta_updates)
end

function App:toggle_readme_images()
    self.state.show_readme_images = not self.state.show_readme_images
    App.save_setting("show_readme_images", self.state.show_readme_images)
    if not self.state.show_readme_images then
        self.readme_image_queue = {}
        self.readme_image_pending = {}
    end
    self:refresh()
end

function App:prompt_base_font_size()
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = _("ZenPM font size"),
        value = self.state.base_font_size,
        value_min = Theme.MIN_BASE_FONT_SIZE,
        value_max = Theme.MAX_BASE_FONT_SIZE,
        value_step = 1,
        value_hold_step = 2,
        callback = function(spin)
            self.state.base_font_size = Theme.set_base_font_size(spin.value)
            App.save_setting("base_font_size", self.state.base_font_size)
            self:refresh()
        end,
    })
end

function App:show_actions(anchor)
    Modals.actions(_("ZenPM"), {
        {
            text = _("About"),
            icon = "details",
            callback = function() self:show_about() end,
        },
        {
            text = _("Update"),
            icon = "upgrade",
            callback = function() self:start_update() end,
        },
        {
            text = _("Refresh"),
            icon = "refresh",
            callback = function() self:refresh_repos() end,
        },
        {
            text = _("Report a Bug"),
            icon = "settings_bug",
            callback = function() BugReporter:show(self) end,
        },
        {
            text = _("Settings"),
            icon = "settings",
            callback = function() self:show_settings() end,
        },
        {
            text = _("Quit"),
            icon = "uninstall",
            callback = function() self:quit() end,
        },
    }, {
        align = "left",
        anchor = anchor,
        anchor_right = true,
        compact = true,
        compact_min_width = 220,
        show_cancel = false,
        title_icon = Images.asset("zenpm.svg"),
    })
end

function App:show_settings()
    self.settings_origin = {
        page = self.state.page,
        active_tab = self.state.active_tab,
    }
    self.settings_requires_reload = false
    self.state.page = "settings"
    self:reset_scroll("settings")
    self:clear_status()
    self:refresh()
end

function App:close_settings()
    local origin = self.settings_origin or {}
    local reload = self.settings_requires_reload
    self.settings_origin = nil
    self.settings_requires_reload = nil
    self.state.page = origin.page or "home"
    self.state.active_tab = origin.active_tab or self.state.page
    if reload then
        self:reload_current_page()
        return
    end
    self:refresh()
end

function App:show_about()
    local version = self.daemon:installed_backend_version()
    if version == "" then
        version = self.version or "?"
    end
    version = tostring(version):gsub("^v", "")
    local platform = tostring(self:package_platforms())
    local device_platform = self.daemon:detect_platform()
    local abi = nil
    if device_platform == "kindle" or device_platform == "kobo" or device_platform == "ereader" then
        abi = _("\nABI: ") .. tostring(self.daemon:ereader_backend_suffix())
    end
    Modals.info(_("ZenPM") .. "\n\n" .. _("Version: ") .. version .. "\n" .. _("Platform: ") .. platform .. (abi or "") .. "\n" .. _("Author: Anthony Gress (ZenLabs)") .. "\n2026")
end

function App:start_update()
    if self.busy then return end
    self.busy = true
    local status = Modals.status(_("Checking for update..."))
    UIManager:forceRePaint()
    self:run_update_task(function()
        return pcall(Updater.check, Updater, self.daemon, self.state.beta_updates, true)
    end, status, function(completed, called, ok, result)
        self.busy = false
        Modals.close_status()
        if not completed then
            Modals.info(_("Update check was cancelled."))
            return
        end
        if not called then
            Modals.info(_("Update failed: ") .. tostring(ok))
            return
        end
        if not ok then
            Modals.info(_("Update failed: ") .. tostring(result))
            return
        end
        if result == "up_to_date" then
            Modals.info(_("ZenPM is up to date."))
            return
        end

        Modals.confirm(
            _("ZenPM update v") .. tostring(result) .. _(" is available. Update now?"),
            _("Update"),
            function() self:apply_update() end,
            true
        )
    end)
end

function App:apply_update(release_tag, on_result)
    if type(release_tag) == "function" then
        on_result = release_tag
        release_tag = nil
    end
    local companion_update_started = false
    if self.daemon:is_android() then
        local started, err = self.daemon:request_android_update()
        if not started then
            local message = _("Companion update failed to start: ") .. tostring(err)
            if on_result then
                on_result(false, message)
            else
                Modals.info(message)
            end
            return
        end
        companion_update_started = true
    end
    self.busy = true
    local status = Modals.status(release_tag and _("Reinstalling ZenPM...") or _("Updating ZenPM..."))
    UIManager:forceRePaint()
    self:run_update_task(function()
        if release_tag then
            return pcall(Updater.reinstall, Updater, self.daemon, release_tag, self.state.beta_updates, true)
        end
        return pcall(Updater.update, Updater, self.daemon, self.state.beta_updates, true)
    end, status, function(completed, called, ok, result)
        self.busy = false
        Modals.close_status()
        if not completed then
            local message = _("Update was cancelled.")
            if on_result then on_result(false, message) else Modals.info(message) end
            return
        end
        if not called then
            local message = _("Update failed: ") .. tostring(ok)
            if on_result then on_result(false, message) else Modals.info(message) end
            return
        end
        if not ok then
            local message = _("Update failed: ") .. tostring(result)
            if on_result then on_result(false, message) else Modals.info(message) end
            return
        end
        if result == "up_to_date" then
            if on_result then
                on_result(true)
                return
            end
            if companion_update_started then
                Modals.info(_("ZenPM Companion is checking for an update."))
            else
                Modals.info(_("ZenPM is up to date."))
            end
            return
        end

        -- The next startup copies the new bundled backend; stop the old one
        -- now so it cannot be reused after KOReader restarts.
        if self.client and self.client.scan_installed_plugins then
            -- Record the replacement while this backend is still running so
            -- the Installed page immediately reflects the new ZenPM version.
            self.client:scan_installed_plugins()
        end
        self.daemon:stop_standalone_backend()
        self.backend_ready = false
        -- Start the new bundled backend now. KOReader still needs a restart to
        -- load the replaced plugin code, but About can immediately report the
        -- version that was just installed.
        self:start_backend_then_reload()
        if on_result then
            on_result(true, result)
            return
        end
        Modals.restart_koreader(
            _("ZenPM updated to v") .. tostring(result) .. _(".\n\nRestart KOReader to use the new version."),
            function() self:restart_koreader() end)
    end)
end

function App:image_summary(pkg)
    if not pkg then return _("None") end
    if type(pkg.images) == "table" and #pkg.images > 0 then
        return table.concat(pkg.images, ", ")
    end
    if pkg.image_url and pkg.image_url ~= "" then
        return pkg.image_url
    end
    return _("None")
end

return App
