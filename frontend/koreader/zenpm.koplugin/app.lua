local socket = require("socket")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local AppView = require("ui/app_view")
local BugReporter = require("bugreporter")
local Constants = require("constants")
-- KOReader may already have a module named "client" loaded. Load our HTTP
-- client explicitly so that cache entry cannot replace it.
local Client = dofile(Constants.PLUGIN_DIR .. "/client.lua")
local Daemon = require("daemon")
local I18n = require("i18n")
local Images = require("ui/images")
local Modals = require("ui/modals")
local Models = require("models")
local Theme = require("ui/theme")
local Updater = require("updater")
local Util = require("zenpm_util")

local App = {}

-- Persist UI preferences (filter, advanced mode, update checks) in our own config file inside
-- the ZenPM state dir, kept separate from KOReader's global settings.
local config_settings = nil
local UPDATE_CHECK_INTERVAL = 24 * 60 * 60

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
        scan_plugins_on_open = false,
        image_files = {},
        state = {
            page = "home",
            active_tab = "home",
            filter_installable = App.load_setting("filter_installable", true),
            advanced = App.load_setting("advanced", false),
            beta_updates = App.load_setting("beta_updates", false),
            update_auto_check = App.load_setting("update_auto_check", true),
            update_available = App.load_setting("update_available", false),
            base_font_size = Theme.normalize_base_font_size(App.load_setting("base_font_size", Theme.get_base_font_size())),
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

function App:run_update_task(task, trap_widget, on_done)
    local ok_trapper, Trapper = pcall(require, "ui/trapper")
    if not ok_trapper or not Trapper then
        UIManager:nextTick(function()
            local invoked, called, ok, result = pcall(task)
            if invoked then
                on_done(true, called, ok, result)
            else
                on_done(true, false, called)
            end
        end)
        return
    end
    Trapper:wrap(function()
        local completed, called, ok, result = Trapper:dismissableRunInSubprocess(task, trap_widget)
        on_done(completed, called, ok, result)
    end)
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
    for _, entry in ipairs(self.state.queue) do
        queued[entry.key] = true
    end
    for _, pkg in ipairs(self.state.packages or {}) do
        if pkg.installed and pkg.update_available then
            local key = queue_key(pkg.id or pkg.name, nil)
            if not queued[key] then
                if self:queue_package_action(pkg, "update", nil, { silent = true }) then
                    added = added + 1
                end
                queued[key] = true
            end
        end
    end
    if added > 0 then
        Modals.info_for(_("Added to Queue"), Constants.PACKAGE_NOTICE_SECONDS)
    end
    self:refresh()
end

function App:queue_entry_for(pkg, action, asset, opts)
    local id = pkg and (pkg.id or pkg.name)
    if not id then return nil end
    opts = opts or {}
    local is_patch = Models.is_patch_package(pkg)
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
        settings_deleter = action == "uninstall" and resolve_plugin_settings_deleter(pkg) or nil,
    }
end

function App:queue_package_action(pkg, action, asset, opts)
    if self.state.queue_running then
        Modals.info(_("Queue is running. Please wait."))
        return false
    end
    opts = opts or {}
    if action_installs_package(action) and not opts.conflict_confirmed then
        local conflicts = self:conflicting_packages(pkg)
        if #conflicts > 0 then
            local names = {}
            for _, conflict in ipairs(conflicts) do
                table.insert(names, package_title(conflict, conflict.id or _("Package")))
            end
            Modals.confirm(
                string.format(
                    _("%s conflicts with %s. They should not be used together. Install anyway?"),
                    package_title(pkg, pkg.id or _("Package")),
                    table.concat(names, ", ")
                ),
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
                Modals.info_for(_("Added to Queue"), Constants.PACKAGE_NOTICE_SECONDS)
            end
            self:refresh()
            return true
        end
    end
    table.insert(self.state.queue, entry)
    if not opts.silent then
        Modals.info_for(_("Added to Queue"), Constants.PACKAGE_NOTICE_SECONDS)
    end
    self:refresh()
    return true
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

local function package_id(pkg)
    return Util.trim(tostring(pkg and (pkg.id or pkg.name) or "")):lower()
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

function App:clear_queue()
    if self.state.queue_running then return end
    self.state.queue = {}
    self:refresh()
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
            return
        end
    end
end

function App:confirm_remove_queue_entry(entry)
    if self.state.queue_running then return end
    Modals.confirm(
        string.format(_("Remove %s from queue?"), entry.name or _("Package")),
        _("Remove"),
        function()
            self:remove_queue_entry(entry)
            self:refresh()
        end
    )
end

function App:show_queue_entry_modify(entry)
    if self.state.queue_running or not entry or not entry.pkg then return end
    local pkg = entry.pkg
    local remove_queue = function() self:confirm_remove_queue_entry(entry) end
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
            downgrade = Models.has_github_source(pkg) and function()
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
    local ok, packages = self:load_packages(true, true)
    if not ok then return end
    self.state.packages = packages
    local installed = Models.installed_packages(packages)
    self.state.installed_packages = installed
    self.state.visible_packages = self:sorted_packages("installed", Models.filter_packages(installed, self.state.filters.installed))
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
            if queue_completed then self:close_queue() end
            Modals.info_for(result, #batch.failed > 0 and Constants.PACKAGE_ERROR_NOTICE_SECONDS or Constants.PACKAGE_NOTICE_SECONDS)
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

function App:confirm_queue()
    if self.busy or self.state.queue_running or self:queue_count() == 0 then return end
    local operations = {}
    for _, entry in ipairs(self.state.queue) do
        if entry.action == "uninstall" then table.insert(operations, entry) end
    end
    for _, entry in ipairs(self.state.queue) do
        if entry.action ~= "uninstall" then table.insert(operations, entry) end
    end
    self.state.queue_running = true
    self:run_next_queue_operation({
        operations = operations,
        index = 1,
        succeeded = {},
        failed = {},
        settings_cleanup = {},
        prompt_restart = false,
    })
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
    UIManager:show(self.view)
    self:schedule_automatic_update_check()
    self.scan_plugins_on_open = true
    if self.backend_ready then
        self:navigate(self.state.active_tab or "home")
        self:schedule_plugin_scan_after_open()
    else
        self.t_open = socket.gettime()
        self:set_loading(_("Loading packages, please wait"))
        self:start_backend_then_reload()
    end
end

function App:set_update_available(available)
    self.state.update_available = available == true
    App.save_setting("update_available", self.state.update_available)
end

function App:schedule_automatic_update_check()
    if not self.state.update_auto_check or self.state.update_checking then return end
    local now = os.time()
    local last_check = tonumber(App.load_setting("last_update_check", 0)) or 0
    if now - last_check < UPDATE_CHECK_INTERVAL then return end

    local ok_network, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_network and NetworkMgr and NetworkMgr.isWifiOn and not NetworkMgr:isWifiOn() then return end

    self.state.update_checking = true
    UIManager:scheduleIn(15, function()
        if not self.view or self.busy or not self.state.update_auto_check then
            self.state.update_checking = false
            return
        end
        self:run_update_task(function()
            return pcall(Updater.check, Updater, self.daemon, self.state.beta_updates)
        end, nil, function(completed, called, ok, result)
            self.state.update_checking = false
            if completed and called and ok then
                App.save_setting("last_update_check", os.time())
                self:set_update_available(result ~= "up_to_date")
                self:refresh()
            end
        end)
    end)
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

function App:quit()
    self:close()
end

function App:restart_koreader()
    self:close()
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
    if Models.has_readme(pkg) and cache_key ~= "" then
        local cached = self.state.readme_cache[cache_key]
        if cached == nil then
            local readme_ok, data = self.client:get_package_readme(cache_key)
            cached = readme_ok and type(data) == "table" and data.readme or false
            self.state.readme_cache[cache_key] = cached
        end
        if type(cached) == "string" then
            pkg.readme = cached
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
        title = _("Search installed packages")
        hint = _("Search installed...")
    elseif kind == "categories" then
        title = _("Search categories")
        hint = _("Search categories...")
    elseif kind == "category" then
        title = _("Search category")
        hint = _("Search category...")
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
            downgrade = Models.has_github_source(pkg) and function()
                self:prompt_package_versions(pkg, on_done)
            end or nil,
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
    self:queue_package_action(pkg, action, asset, { release = release_tag })
end

function App:confirm_package_action(pkg, action, on_done)
    self:start_package_action(pkg, action, on_done, nil)
end

function App:start_package_action(pkg, action, on_done, opts)
    local id = pkg.id or pkg.name
    if not id then
        Modals.info(_("Package has no id."))
        return
    end
    if action_installs_package(action) then
        local ok, info = self.client:get_package_assets(id)
        local has_candidates = type(info) == "table" and info.needs_choice
            and type(info.candidates) == "table" and #info.candidates > 0
        local has_remembered_candidate = false
        if has_candidates and pkg.installed_asset and pkg.installed_asset ~= "" then
            for _, candidate in ipairs(info.candidates) do
                if candidate.asset == pkg.installed_asset then
                    has_remembered_candidate = true
                    break
                end
            end
        end
        if not ok then
            if Models.has_github_source(pkg) then
                self:prompt_package_versions(pkg, on_done)
                return
            end
            Modals.info(_("Could not determine which build to install: ") .. tostring(info))
            return
        end
        if Models.has_github_source(pkg)
            and (type(info) ~= "table" or ((not info.auto or info.auto == "") and not has_candidates)) then
            self:prompt_package_versions(pkg, on_done)
            return
        end
        if has_candidates then
            if action == "update" and Models.has_github_source(pkg)
                and not has_remembered_candidate then
                self:prompt_package_versions(pkg, on_done)
                return
            end
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
                    self:queue_package_action(pkg, action, name, opts)
                end,
            })
        end
    end
    if #rows == 0 then
        self:queue_package_action(pkg, action, nil, opts)
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
    local display_name = is_patch and asset and asset ~= ""
        and (_("patch") .. " " .. tostring(asset))
        or package_title(pkg, id)
    self.busy = true
    Modals.status((opts and opts.status_prefix or "") .. action_progress(action) .. " "
        .. display_name .. "\n\n" .. _("Downloading... Please wait."))
    local ok, err = self.client:package_action(id, backend_action, asset, opts and opts.release or nil)
    if not ok then
        self.busy = false
        Modals.close_status()
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
        prompt_restart = (package_is_koreader_plugin(pkg) or is_patch)
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
            Modals.close_status()
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
                Modals.close_status()
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
            Modals.close_status()
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
            Modals.close_status()
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

function App:toggle_automatic_update_checks()
    self.state.update_auto_check = not self.state.update_auto_check
    App.save_setting("update_auto_check", self.state.update_auto_check)
    if self.state.update_auto_check then
        self:schedule_automatic_update_check()
    end
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
            text = self.state.update_available and "\239\128\155  " .. _("Update") or _("Update"),
            callback = function() self:start_update() end,
        },
        {
            text = _("Check for updates automatically"),
            checked_func = function()
                return self.state.update_auto_check
            end,
            callback = function()
                self:toggle_automatic_update_checks()
            end,
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
            text = _("Font size: ") .. tostring(self.state.base_font_size),
            callback = function()
                self:prompt_base_font_size()
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
    local version = self.daemon:installed_backend_version()
    if version == "" then
        version = self.version or "?"
    end
    version = tostring(version):gsub("^v", "")
    local platform = tostring(self:package_platforms())
    local device_platform = self.daemon:detect_platform()
    local abi = nil
    if device_platform == "kindle" or device_platform == "kobo" then
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
        return pcall(Updater.check, Updater, self.daemon, self.state.beta_updates)
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
            self:set_update_available(false)
            Modals.info(_("ZenPM is up to date."))
            return
        end

        self:set_update_available(true)
        Modals.confirm(
            _("ZenPM update v") .. tostring(result) .. _(" is available. Update now?"),
            _("Update"),
            function() self:apply_update() end,
            true
        )
    end)
end

function App:apply_update()
    local companion_update_started = false
    if self.daemon:is_android() then
        local started, err = self.daemon:request_android_update()
        if not started then
            Modals.info(_("Companion update failed to start: ") .. tostring(err))
            return
        end
        companion_update_started = true
    end
    self.busy = true
    local status = Modals.status(_("Updating ZenPM..."))
    UIManager:forceRePaint()
    self:run_update_task(function()
        return pcall(Updater.update, Updater, self.daemon, self.state.beta_updates)
    end, status, function(completed, called, ok, result)
        self.busy = false
        Modals.close_status()
        if not completed then
            Modals.info(_("Update was cancelled."))
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
            self:set_update_available(false)
            if companion_update_started then
                Modals.info(_("ZenPM Companion is checking for an update."))
            else
                Modals.info(_("ZenPM is up to date."))
            end
            return
        end

        -- The next startup copies the new bundled backend; stop the old one
        -- now so it cannot be reused after KOReader restarts.
        self:set_update_available(false)
        self.daemon:stop_standalone_backend()
        self.backend_ready = false
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
