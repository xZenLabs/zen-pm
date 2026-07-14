local socket = require("socket")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local AppView = require("ui/app_view")
local BugReporter = require("bugreporter")
local Client = require("client")
local Constants = require("constants")
local Daemon = require("daemon")
local I18n = require("i18n")
local Images = require("ui/images")
local Modals = require("ui/modals")
local Models = require("models")
local Updater = require("updater")
local Util = require("zenpm_util")

local App = {}

-- Persist UI preferences (filter, advanced mode, beta updates) in our own config file inside
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

function App:new(plugin)
    local o = {
        plugin = plugin,
        client = Client:new(),
        daemon = Daemon:new(),
        view = nil,
        busy = false,
        backend_ready = false,
        backend_starting = false,
        image_files = {},
        state = {
            page = "home",
            active_tab = "home",
            filter_installable = App.load_setting("filter_installable", true),
            advanced = App.load_setting("advanced", false),
            beta_updates = App.load_setting("beta_updates", false),
            filters = { search = "", installed = "", categories = "", category = "" },
            sorts = { search = "stars", installed = "stars", category = "stars", source = "stars" },
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
            current_package = nil,
            current_repo = nil,
            current_category = nil,
            details_from = "search",
            details_tab = "readme",
            loading = nil,
            error = nil,
            log_lines = {},
        },
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

local function package_title(pkg, fallback)
    return Models.package_display_name(pkg, fallback)
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

local function action_label(action)
    if action == "update" then return _("Update") end
    if action == "downgrade" then return _("Downgrade") end
    if action == "reinstall" then return _("Reinstall") end
    return _("Get")
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
    return (action == "reinstall" or action == "update" or action == "downgrade") and "install" or action
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

local function package_targets_kindle(pkg)
    if type(pkg) ~= "table" or type(pkg.platforms) ~= "table" then
        return false
    end
    for _, platform in ipairs(pkg.platforms) do
        if Util.trim(tostring(platform or "")):lower() == "kindle" then
            return true
        end
    end
    return false
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

    for _, candidate in ipairs({ pkg.plugin_module, pkg.id, pkg.name }) do
        if type(candidate) == "string" and candidate ~= "" and by_dir[candidate] then
            return by_dir[candidate]
        end
    end
    return nil
end

local function plugin_has_delete_settings(inst)
    return type(inst) == "table"
        and (type(inst.deletePluginSettings) == "function" or inst.settings_file or inst.settings_key)
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
    for _, candidate in ipairs({ pkg.plugin_module, pkg.id, pkg.name }) do
        if type(candidate) == "string" and candidate ~= "" and by_key[candidate] then
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

local function delete_default_plugin_settings(plugin_name)
    if type(plugin_name) ~= "string" or plugin_name == "" then return end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getSettingsDir then
        local settings_file = DataStorage:getSettingsDir() .. "/" .. plugin_name .. ".lua"
        os.remove(settings_file)
        os.remove(settings_file .. ".old")
    end
    if G_reader_settings and G_reader_settings.delSetting then
        G_reader_settings:delSetting(plugin_name)
    end
end

-- Delete plugin settings from either a live instance or a module loaded from
-- disk, using KOReader's wrapper when available so settings_file/settings_key
-- are handled the same way KOReader handles its own plugin manager.
local function delete_plugin_settings(plugin, plugin_name)
    if type(plugin) ~= "table" then
        delete_default_plugin_settings(plugin_name)
        return
    end
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
    delete_default_plugin_settings(plugin_name)
end

-- Resolve a best-effort settings deleter before the backend uninstall purges
-- the .koplugin directory. The returned closure captures any loaded module from
-- disk, so deletePluginSettings can still run after the directory is removed.
local function resolve_plugin_settings_deleter(pkg)
    local dir_path = find_koplugin_dir(pkg)
    local plugin_name = koplugin_dir_basename(dir_path)
    if type(plugin_name) ~= "string" or plugin_name == "" then
        plugin_name = pkg and (pkg.plugin_module or pkg.id or pkg.name)
    end

    local inst = koreader_plugin_instance(pkg)
    if plugin_has_delete_settings(inst) then
        return function() delete_plugin_settings(inst, plugin_name) end
    end

    local mod = load_plugin_from_disk(dir_path)
    if plugin_has_delete_settings(mod) then
        return function() delete_plugin_settings(mod, plugin_name) end
    end

    if dir_path or package_is_koreader_plugin(pkg) then
        return function() delete_plugin_settings(nil, plugin_name) end
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

function App:show()
    if not self.view then
        self.view = AppView:new{ app = self }
    end
    UIManager:show(self.view)
    if self.backend_ready then
        self:navigate(self.state.active_tab or "home")
    else
        self.t_open = socket.gettime()
        self:set_loading(_("Loading packages, please wait"))
        self:start_backend_then_reload()
    end
end

function App:close()
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

function App:backend_started(data, on_ready)
    self.backend_starting = false
    self.backend_ready = true
    self.version = data and data.version or self.version or "?"
    if self.t_open then
        self:log_timing("backend ready (open -> health ok)", self.t_open)
    end
    self:clear_status()
    if on_ready then
        on_ready()
    else
        self:refresh()
    end
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
        local started, err = self.daemon:start()
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
    local ok, data = self.daemon:ensure(self.client, changed)
    if not ok then
        local message = data or _("ZenPM daemon not reachable. Re-run ZenPM installer if it is not running.")
        self:set_error(message)
        Modals.info(message)
        self.backend_ready = false
        return false
    end
    self.backend_ready = true
    self.version = data and data.version or "?"
    return true
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

function App:package_icon_file(pkg)
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
        local ok, data = self.client:list_packages(nil, check_updates)
        if not ok then
            return false, {}, data
        end
        local packages = type(data) == "table" and data or {}
        self.state.packages = packages
        return true, packages
    end
    local filter = self:package_platforms()
    local capabilities, capability_set = platform_capabilities(filter)
    local ok, data = self.client:list_packages(filter, check_updates)
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
        ok, data = self.client:list_packages(platform, check_updates)
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
    local ok, packages, err = self:load_packages(true)
    if not ok then
        self:set_error(_("Failed to load packages: ") .. tostring(err))
        return
    end
    local installed = Models.installed_packages(packages)
    self.state.packages = packages
    self.state.installed_packages = installed
    self.state.visible_packages = self:sorted_packages("installed", Models.filter_packages(installed, self.state.filters.installed))
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
    self.state.repos = repos
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
    self.state.visible_packages = self:sorted_packages("source", visible)
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
    if Models.has_github_source(pkg) and cache_key ~= "" then
        local cached = self.state.readme_cache[cache_key]
        if cached == nil then
            local readme_ok, data = self.client:get_package_readme(cache_key)
            cached = readme_ok and type(data) == "table" and data.readme or false
            self.state.readme_cache[cache_key] = cached
        end
        if type(cached) == "string" then
            pkg.github_readme = cached
        end
    end
    self.state.current_package = pkg
    self.state.details_tab = Models.is_patch_package(pkg) and #Models.package_assets(pkg) > 0 and details_tab == "patches" and "patches" or "readme"
    self:reset_scroll("package:" .. cache_key .. ":" .. self.state.details_tab)
    self:clear_status()
    self:refresh()
end

function App:set_package_details_tab(tab)
    if tab ~= "patches" then
        tab = "readme"
    end
    if self.state.details_tab == tab then
        return
    end
    self.state.details_tab = tab
    self:reset_scroll()
    self:refresh()
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

function App:set_filter(kind, value)
    self.state.filters[kind] = value or ""
    if kind == "installed" then
        self:reset_scroll("installed")
    elseif kind == "categories" then
        self:reset_scroll("categories")
    elseif kind == "category" and self.state.current_category then
        self:reset_scroll("category:" .. tostring(self.state.current_category.id))
    else
        self:reset_scroll("search")
    end
    if kind == "installed" then
        self:show_installed()
    elseif kind == "categories" then
        self:show_categories()
    elseif kind == "category" and self.state.current_category then
        self:show_category_details(self.state.current_category.id)
    else
        self:show_search()
    end
end

function App:set_sort(kind, value)
    self.state.sorts[kind] = value or "stars"
    self:reset_scroll(self:scroll_key())
    if kind == "installed" then
        self:show_installed()
    elseif kind == "category" and self.state.current_category then
        self:show_category_details(self.state.current_category.id)
    elseif kind == "source" and self.state.current_repo then
        self:show_source_details(self.state.current_repo.name)
    else
        self:show_search()
    end
end

function App:prompt_sort(kind)
    local current = self.state.sorts[kind] or "stars"
    local function label(key, text)
        if current == key then
            return "• " .. text
        end
        return text
    end
    Modals.actions(_("Sort packages"), {
        {
            text = label("stars", _("Stars")),
            callback = function() self:set_sort(kind, "stars") end,
        },
        {
            text = label("name", _("Name")),
            callback = function() self:set_sort(kind, "name") end,
        },
        {
            text = label("repo", _("Source")),
            callback = function() self:set_sort(kind, "repo") end,
        },
    })
end

function App:prompt_filter(kind)
    local title = _("Search packages")
    local hint = _("Search...")
    if kind == "installed" then
        title = _("Filter installed packages")
        hint = _("Filter installed...")
    elseif kind == "categories" then
        title = _("Search categories")
        hint = _("Search categories...")
    elseif kind == "category" then
        title = _("Search category")
        hint = _("Search category...")
    end
    Modals.input(title, self.state.filters[kind] or "", hint, _("Search"), function(text)
        self:set_filter(kind, Util.trim(text))
    end, function()
        self:set_filter(kind, "")
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
            reinstall_downgrade = Models.has_github_source(pkg) and function()
                self:prompt_package_versions(pkg, on_done)
            end or nil,
            reinstall = function()
                self:confirm_package_action(pkg, "reinstall", on_done)
            end,
            uninstall = function()
                self:confirm_package_action(pkg, "uninstall", on_done)
            end,
        })
    elseif self.state.advanced and Models.has_github_source(pkg) then
        self:prompt_package_versions(pkg, on_done)
    else
        self:confirm_package_action(pkg, "install", on_done)
    end
end

function App:show_patch_modify(pkg, on_done)
    local asset = pkg.patch_asset
    Modals.package_modify(pkg, {
        info = self.state.page ~= "package_details" and function()
            self:show_package_details(pkg.id or pkg.name, self.state.active_tab)
        end or nil,
        disabled = is_patch_disabled(pkg),
        enable_disable = function()
            self:confirm_toggle_enable(pkg, "patch", on_done)
        end,
        reinstall = function()
            self:confirm_patch_item_action(pkg, "reinstall", asset, on_done)
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
                function() UIManager:restartKOReader() end)
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
    local question = _("Are you sure you want to reinstall ") .. name .. "?"
    local label = _("Reinstall")
    if action == "uninstall" then
        question = _("Are you sure you want to uninstall ") .. name .. "?"
        label = _("Uninstall")
    end
    Modals.confirm(question, label, function()
        self:run_package_action(pkg, action, name, on_done, nil)
    end)
end

-- Show installable GitHub releases for a package. Each version maps to an
-- update/reinstall/downgrade action based on its relation to the installed
-- version. Prereleases are hidden unless the user enabled ZenPM beta updates.
-- All releases are fetched in one request (keeps GitHub API calls low under the
-- anonymous rate limit); the list is paged VERSIONS_PER_PAGE at a time in the UI.
local VERSIONS_PER_PAGE = 5

local function version_action(current, tag)
    if current == nil or current == "" then return "install" end
    if version_gt(tag, current) then return "update" end
    if version_gt(current, tag) then return "downgrade" end
    return "reinstall"
end

function App:prompt_package_versions(pkg, on_done)
    local current = pkg.installed and (pkg.installed_version or pkg.version or "") or ""
    Modals.status(_("Loading GitHub releases..."))
    local ok, data = self.client:get_package_releases(pkg.id or pkg.name)
    Modals.close_status()
    if not ok then
        Modals.info(_("Could not load GitHub releases: ") .. tostring(data))
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
        Modals.info(_("No GitHub releases with ZIP assets were found."))
        return
    end
    self:show_versions_page(pkg, releases, current, 1, on_done)
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
    Modals.actions(_("Select version for ") .. package_title(pkg, pkg.id or pkg.name), rows)
end

function App:choose_version_release(pkg, release, action, on_done)
    local assets = type(release.assets) == "table" and release.assets or {}
    if #assets == 1 then
        self:confirm_package_version(pkg, release.tag_name, action, assets[1].name, on_done)
        return
    end
    local rows = {}
    for _, asset in ipairs(assets) do
        if asset.name and asset.name ~= "" then
            table.insert(rows, {
                text = asset.name,
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
    Modals.actions(_("Choose a build for ") .. tostring(release.tag_name), rows)
end

function App:confirm_package_version(pkg, release_tag, action, asset, on_done)
    local name = package_title(pkg, pkg.id or pkg.name)
    local verb = action_present(action)
    local notice = package_targets_kindle(pkg)
        and ("\n\n" .. _("This package installs to the Kindle UI, not KOReader.")) or ""
    Modals.confirm(
        _("Are you sure you want to ") .. verb .. " " .. name .. " " .. _("to") .. " " .. tostring(release_tag) .. "?" .. notice,
        action_label(action),
        function()
            self:run_package_action(pkg, action, asset, on_done, { release = release_tag })
        end
    )
end

function App:confirm_package_action(pkg, action, on_done)
    local name = package_title(pkg, "?")
    local question = _("Are you sure you want to download ") .. name .. "?"
    local label = _("Get")
    if action == "reinstall" then
        question = _("Are you sure you want to reinstall ") .. name .. "?"
        label = _("Reinstall")
    elseif action == "update" then
        local latest = pkg.latest_version and pkg.latest_version ~= "" and (" " .. _("to") .. " " .. pkg.latest_version) or ""
        question = _("Are you sure you want to update ") .. name .. latest .. "?"
        label = _("Update")
    elseif action == "uninstall" then
        question = _("Are you sure you want to uninstall ") .. name .. "?"
        label = _("Uninstall")
    end
    if action_installs_package(action) and package_targets_kindle(pkg) then
        question = question .. "\n\n" .. _("This package installs to the Kindle UI, not KOReader.")
    end
    local opts = nil
    if action == "uninstall" then
        opts = { settings_deleter = resolve_plugin_settings_deleter(pkg) }
    end
    Modals.confirm(question, label, function()
        self:start_package_action(pkg, action, on_done, opts)
    end)
end

function App:start_package_action(pkg, action, on_done, opts)
    local id = pkg.id or pkg.name
    if not id then
        Modals.info(_("Package has no id."))
        return
    end
    if action_installs_package(action) then
        local ok, info = self.client:get_package_assets(id)
        if ok and type(info) == "table" and info.needs_choice and type(info.candidates) == "table" then
            self:choose_package_asset(pkg, action, info.candidates, on_done, opts)
            return
        end
    end
    self:run_package_action(pkg, action, nil, on_done, opts)
end

function App:choose_package_asset(pkg, action, candidates, on_done, opts)
    local rows = {}
    for _, asset in ipairs(candidates) do
        local name = asset.asset
        if name and name ~= "" then
            table.insert(rows, {
                text = name,
                callback = function()
                    self:run_package_action(pkg, action, name, on_done, opts)
                end,
            })
        end
    end
    if #rows == 0 then
        self:run_package_action(pkg, action, nil, on_done, opts)
        return
    end
    local title = Models.is_patch_package(pkg)
        and (_("Choose a patch for ") .. package_title(pkg, pkg.id or pkg.name))
        or (_("Choose a build for ") .. package_title(pkg, pkg.id or pkg.name))
    Modals.actions(title, rows)
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
    local name = package_title(pkg, pkg.id or pkg.name)
    local patch_name = tostring(asset.asset)
    if Models.patch_file_installed(pkg, patch_name) then
        Modals.confirm(
            _("Are you sure you want to uninstall ") .. patch_name .. "?",
            _("Uninstall"),
            function()
                self:run_package_action(pkg, "uninstall", patch_name, on_done, nil)
            end
        )
        return
    end
    Modals.confirm(
        _("Are you sure you want to install ") .. patch_name .. " " .. _("from") .. " " .. name .. "?",
        _("Install"),
        function()
            self:run_package_action(pkg, "install", patch_name, on_done, nil)
        end
    )
end

function App:run_package_action(pkg, action, asset, on_done, opts)
    local backend_action = backend_action_for(action)
    local id = pkg.id or pkg.name
    local failure_baseline = self:package_action_failure_stats({
        id = id,
        action = action,
    })
    local is_patch = Models.is_patch_package(pkg)
    local display_name = is_patch and asset and asset ~= ""
        and (_("patch") .. " " .. tostring(asset))
        or package_title(pkg, id)
    self.busy = true
    Modals.status(action_progress(action) .. " "
        .. display_name .. "\n\n" .. _("Downloading... Please wait."))
    local ok, err = self.client:package_action(id, backend_action, asset, opts and opts.release or nil)
    if not ok then
        self.busy = false
        Modals.close_status()
        Modals.info_for(_("Failed to start package action: ") .. tostring(err), Constants.PACKAGE_NOTICE_SECONDS)
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
        prompt_restart = (package_is_koreader_plugin(pkg) or is_patch)
            and (action_installs_package(action) or action == "uninstall"),
        settings_deleter = opts and opts.settings_deleter or nil,
        failure_baseline = failure_baseline,
        on_done = on_done,
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
            Modals.close_status()
            Modals.info_for(action_present(op.action) .. " " .. _("of") .. " " .. op.name .. " failed.\n\n" .. detail, Constants.PACKAGE_NOTICE_SECONDS)
            return
        end

        -- Force a fresh catalog read each tick: the session cache would mask the
        -- install/uninstall status change we're polling for. On success this also
        -- leaves state.packages holding the updated status for the list/detail view.
        local ok, packages = self:load_packages(false, true)
        if not ok then
            if attempt >= Constants.MAX_POLL_RETRIES then
                self.busy = false
                Modals.close_status()
                Modals.info_for(_("Package operation status could not be checked. See Debug log."), Constants.PACKAGE_NOTICE_SECONDS)
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
            Modals.close_status()
            local finish = function()
                if op.prompt_restart then
                    local tail = _(" successfully.\n\nRestart KOReader to load the plugin.")
                    if op.is_patch or op.action == "uninstall" then
                        tail = _(" successfully.\n\nRestart KOReader to apply the change.")
                    end
                    Modals.restart_koreader(op.name .. " " .. done .. tail, function()
                        UIManager:restartKOReader()
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
            Modals.close_status()
            Modals.info_for(message, Constants.PACKAGE_NOTICE_SECONDS)
        else
            self:poll_package_action(op, attempt + 1)
        end
    end)
end

function App:refresh_repos()
    Modals.status(_("Refreshing repositories..."))
    local ok, data = self.client:refresh_repos()
    Modals.close_status()
    if ok then
        local found, packages = self:load_packages(false, true)
        self:load_repos(true)
        self:reload_current_page()
        if found then
            Modals.info_for(string.format(_("Updated: %d packages"), #packages), Constants.PACKAGE_NOTICE_SECONDS)
        else
            Modals.info_for(_("Packages updated"), Constants.PACKAGE_NOTICE_SECONDS)
        end
    else
        Modals.info(_("Refresh failed: ") .. tostring(data))
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
    self:reload_current_page()
    Modals.info_for(string.format(_("Found %d installed plugins"), tonumber(data.matched) or 0), Constants.PACKAGE_NOTICE_SECONDS)
end

function App:toggle_filter_installable()
    self.state.filter_installable = not self.state.filter_installable
    App.save_setting("filter_installable", self.state.filter_installable)
    self.state.packages = {}
    self:reload_current_page()
end

function App:toggle_advanced()
    self.state.advanced = not self.state.advanced
    App.save_setting("advanced", self.state.advanced)
end

function App:toggle_beta_updates()
    self.state.beta_updates = not self.state.beta_updates
    App.save_setting("beta_updates", self.state.beta_updates)
end

function App:show_actions(anchor)
    Modals.actions(_("ZenPM"), {
        {
            text = _("About"),
            callback = function() self:show_about() end,
        },
        {
            text = _("Report a Bug"),
            callback = function() BugReporter:show(self) end,
        },
        {
            text = _("Refresh"),
            callback = function()
                self:refresh_repos()
            end,
        },
        {
            text = _("Scan installed plugins"),
            callback = function()
                self:scan_installed_plugins()
            end,
        },
        {
            text = _("Update"),
            callback = function() self:start_update() end,
        },
        {
            text = _("Filter installable"),
            checked_func = function()
                return self.state.filter_installable
            end,
            callback = function()
                self:toggle_filter_installable()
            end,
        },
        {
            text = _("Advanced"),
            checked_func = function()
                return self.state.advanced
            end,
            callback = function()
                self:toggle_advanced()
            end,
        },
        {
            text = _("Beta updates"),
            checked_func = function()
                return self.state.beta_updates
            end,
            callback = function()
                self:toggle_beta_updates()
            end,
        },
        {
            text = _("Quit"),
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

function App:show_about()
    local version = tostring(self.version or "?"):gsub("^v", "")
    local platform = tostring(self:package_platforms())
    Modals.info(_("ZenPM") .. "\n\n" .. _("Version: ") .. version .. "\n" .. _("Platform: ") .. platform .. "\n" .. _("Author: Anthony Gress (ZenLabs)") .. "\n2026")
end

function App:start_update()
    Modals.confirm(_("Check for and start a ZenPM update?"), _("Update"), function()
        self.busy = true
        Modals.status(_("Checking for ZenPM updates..."))
        UIManager:forceRePaint()
        local completed, ok, result = pcall(Updater.update, Updater, self.daemon, self.state.beta_updates)
        self.busy = false
        Modals.close_status()
        if not completed then
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

        -- The next startup copies the new bundled backend; stop the old one
        -- now so it cannot be reused after KOReader restarts.
        self.daemon:stop_standalone_backend()
        self.backend_ready = false
        Modals.restart_koreader(
            _("ZenPM updated to v") .. tostring(result) .. _(".\n\nRestart KOReader to use the new version."),
            function() UIManager:restartKOReader() end)
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
