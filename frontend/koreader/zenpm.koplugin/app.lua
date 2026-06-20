local socket = require("socket")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Chrome = require("ui/chrome")
local Client = require("client")
local Constants = require("constants")
local Daemon = require("daemon")
local I18n = require("i18n")
local Images = require("ui/images")
local Modals = require("ui/modals")
local Models = require("models")
local Util = require("zenpm_util")

local App = {}

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
            current_package = nil,
            current_repo = nil,
            current_category = nil,
            details_from = "search",
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
    return I18n.dynamic_or(pkg and (pkg.name or pkg.id), fallback or _("Package"))
end

local function action_present(action)
    if action == "update" then
        return _("update")
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
    if action == "uninstall" then
        return _("Uninstalling")
    end
    if action == "reinstall" then
        return _("Reinstalling")
    end
    return _("Installing")
end

local function backend_action_for(action)
    return (action == "reinstall" or action == "update") and "install" or action
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

local function action_installs_package(action)
    return action == "install" or action == "reinstall" or action == "update"
end

function App:show()
    if not self.view then
        self.view = Chrome:new{ app = self }
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
        return "package:" .. tostring(self.state.current_package.id or self.state.current_package.name)
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
        self:show_package_details(self.state.current_package.id or self.state.current_package.name, self.state.details_from)
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

function App:load_packages(check_updates)
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
        return true, packages
    end
    for _, platform in ipairs(capabilities) do
        ok, data = self.client:list_packages(platform, check_updates)
        if not ok then
            return false, {}, data
        end
        merge_compatible_packages(packages, seen, type(data) == "table" and data or {}, capability_set)
    end
    return true, packages
end

function App:load_repos()
    local ok, data = self.client:list_repos()
    if not ok then
        return false, {}, data
    end
    return true, type(data) == "table" and data or {}
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
    -- Render cached catalog immediately; manifest enrichment is network-bound,
    -- so defer it and re-render once it returns (or fails).
    self.state.packages = packages
    self.state.featured_packages = Models.select_featured(packages, nil)
    self:clear_status()
    self:refresh()
    if self.t_open then
        self:log_timing("home rendered from cache (open -> paint)", self.t_open)
        self.t_open = nil
    end

    local cache_empty = #packages == 0
    local manifest_url = Constants.REPO_ZENLABS_URL:gsub("/+$", "") .. "/manifest.json"
    UIManager:scheduleIn(0.05, function()
        if self.state.page ~= "home" then return end
        -- First run: catalog cache was empty and the backend is refreshing repos
        -- in the background. Reload packages so the DB results appear.
        if cache_empty then
            self:reload_featured_until_ready(1)
        end
        local t_manifest = socket.gettime()
        local ok_manifest, manifest = self.client:request("GET", manifest_url, nil)
        self:log_timing("manifest fetch", t_manifest)
        if not ok_manifest or type(manifest) ~= "table" then return end
        if self.state.page ~= "home" then return end
        self.state.featured_packages = Models.select_featured(self.state.packages, manifest)
        self:refresh()
    end)
end

-- Poll the catalog after a first-run background refresh until packages appear.
function App:reload_featured_until_ready(attempt)
    if self.state.page ~= "home" then return end
    local ok, packages = self:load_packages()
    if ok and #packages > 0 then
        self.state.packages = packages
        self.state.featured_packages = Models.select_featured(packages, nil)
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

function App:show_package_details(package_id, from_tab)
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
    self:set_loading(_("Loading package..."))
    local ok, packages, err = self:load_packages()
    if not ok then
        self:set_error(_("Failed to load package: ") .. tostring(err))
        return
    end
    local pkg = Models.find_package(packages, package_id)
    if not pkg then
        self:set_error(_("Package not found."))
        return
    end
    self.state.packages = packages
    self.state.current_package = self:enrich_package_from_repo(pkg)
    self:clear_status()
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

function App:enrich_package_from_repo(pkg)
    if not pkg or not pkg.repo then
        return pkg
    end
    local ok, repos = self:load_repos()
    if not ok then
        return pkg
    end
    local repo = Util.table_find(repos, function(r) return r.name == pkg.repo end)
    if not repo or not repo.url then
        return pkg
    end
    local ok_manifest, manifest = self.client:request("GET", repo.url:gsub("/+$", "") .. "/manifest.json", nil)
    if not ok_manifest or type(manifest) ~= "table" or type(manifest.packages) ~= "table" then
        return pkg
    end
    for _, repo_pkg in ipairs(manifest.packages) do
        if repo_pkg.id == pkg.id then
            return Models.merge_repo_metadata(pkg, repo_pkg, repo.url)
        end
    end
    return pkg
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
    if pkg.installed then
        if pkg.update_available then
            self:confirm_package_action(pkg, "update", on_done)
            return
        end
        Modals.package_modify(pkg, {
            info = function()
                self:show_package_details(pkg.id or pkg.name, self.state.active_tab)
            end,
            reinstall = function()
                self:confirm_package_action(pkg, "reinstall", on_done)
            end,
            uninstall = function()
                self:confirm_package_action(pkg, "uninstall", on_done)
            end,
        })
    else
        self:confirm_package_action(pkg, "install", on_done)
    end
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
    Modals.confirm(question, label, function()
        self:start_package_action(pkg, action, on_done)
    end)
end

function App:start_package_action(pkg, action, on_done)
    local id = pkg.id or pkg.name
    if not id then
        Modals.info(_("Package has no id."))
        return
    end
    if action_installs_package(action) then
        local ok, info = self.client:get_package_assets(id)
        if ok and type(info) == "table" and info.needs_choice and type(info.candidates) == "table" then
            self:choose_package_asset(pkg, action, info.candidates, on_done)
            return
        end
    end
    self:run_package_action(pkg, action, nil, on_done)
end

function App:choose_package_asset(pkg, action, candidates, on_done)
    local rows = {}
    for _, asset in ipairs(candidates) do
        local name = asset.asset
        if name and name ~= "" then
            table.insert(rows, {
                text = name,
                callback = function()
                    self:run_package_action(pkg, action, name, on_done)
                end,
            })
        end
    end
    if #rows == 0 then
        self:run_package_action(pkg, action, nil, on_done)
        return
    end
    Modals.actions(_("Choose a build for ") .. package_title(pkg, pkg.id or pkg.name), rows)
end

function App:run_package_action(pkg, action, asset, on_done)
    local backend_action = backend_action_for(action)
    local id = pkg.id or pkg.name
    local failure_baseline = self:package_action_failure_stats({
        id = id,
        action = action,
    })
    self.busy = true
    Modals.status(action_progress(action) .. " "
        .. package_title(pkg, id) .. "\n\n" .. _("Downloading... Please wait."))
    local ok, err = self.client:package_action(id, backend_action, asset)
    if not ok then
        self.busy = false
        Modals.close_status()
        Modals.info_for(_("Failed to start package action: ") .. tostring(err), Constants.PACKAGE_NOTICE_SECONDS)
        return
    end
    self:poll_package_action({
        id = id,
        name = package_title(pkg, id),
        action = action,
        was_installed = pkg.installed and true or false,
        target_version = pkg.latest_version,
        prompt_restart = action_installs_package(action) and package_is_koreader_plugin(pkg),
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
    if op.action == "reinstall" then
        return pkg and pkg.installed
    end
    return pkg and pkg.installed
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

        local ok, packages = self:load_packages()
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

        if succeeded then
            self.busy = false
            local done = action_done(op.action)
            Modals.close_status()
            if op.prompt_restart then
                Modals.restart_koreader(op.name .. " " .. done .. _(" successfully.\n\nRestart KOReader to load the plugin."), function()
                    UIManager:restartKOReader()
                end)
            else
                Modals.info_for(op.name .. " " .. done .. _(" successfully."), Constants.PACKAGE_NOTICE_SECONDS)
            end
            if op.on_done then op.on_done() end
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
        local found, packages = self:load_packages()
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

function App:show_actions()
    Modals.actions(_("ZenPM"), {
        {
            text = _("Refresh"),
            callback = function()
                self:refresh_repos()
            end,
        },
        {
            text = _("About"),
            callback = function() self:show_about() end,
        },
        {
            text = _("Update"),
            callback = function() self:start_update() end,
        },
        {
            text = _("Quit"),
            callback = function() self:quit() end,
        },
    })
end

function App:show_about()
    local ok, data = self.client:health()
    local version = ok and data and data.version or self.version or "?"
    version = tostring(version):gsub("^v", "")
    Modals.info(_("ZenPM") .. "\n\n" .. _("Version: ") .. version .. "\n" .. _("Author: Anthony Gress (ZenLabs)") .. "\n2026")
end

function App:start_update()
    Modals.confirm(_("Check for and start a ZenPM update?"), _("Update"), function()
        local ok, data = self.client:start_update()
        if ok then
            Modals.info(_("Update accepted. The daemon may restart."))
        else
            Modals.info(_("Update failed: ") .. tostring(data))
        end
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
