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
        image_files = {},
        icon_logs = {},
        state = {
            page = "home",
            active_tab = "home",
            filters = { search = "", installed = "" },
            scroll = {},
            packages = {},
            visible_packages = {},
            featured_packages = {},
            installed_packages = {},
            repos = {},
            current_package = nil,
            current_repo = nil,
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
    if action == "uninstall" then
        return _("uninstall")
    end
    if action == "reinstall" then
        return _("reinstall")
    end
    return _("install")
end

local function action_progress(action)
    if action == "uninstall" then
        return _("Uninstalling")
    end
    if action == "reinstall" then
        return _("Reinstalling")
    end
    return _("Installing")
end

local function backend_action_for(action)
    return action == "reinstall" and "install" or action
end

local function action_done(action)
    if action == "install" then
        return _("installed")
    end
    if action == "reinstall" then
        return _("reinstalled")
    end
    return _("uninstalled")
end

function App:show()
    if not self.view then
        self.view = Chrome:new{ app = self }
    end
    UIManager:show(self.view)
    self:navigate(self.state.active_tab or "home")
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
        self.view:refresh()
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

function App:ensure_backend()
    local changed, prepare_err = self.daemon:ensure_backend_files()
    if prepare_err then
        self:set_error(prepare_err)
        Modals.info(prepare_err)
        return false
    end

    local healthy, health_data = self.client:health()
    if healthy and not changed then
        self.version = health_data and health_data.version or self.version or "?"
        return true
    end

    self:set_loading(_("Connecting to ZenPM..."))
    local ok, data = self.daemon:ensure(self.client, changed)
    if not ok then
        local message = data or _("ZenPM daemon not reachable. Re-run ZenPM installer if it is not running.")
        self:set_error(message)
        Modals.info(message)
        return false
    end
    self.version = data and data.version or "?"
    return true
end

function App:platform()
    return self.daemon:platform_filter()
end

local function file_content_hash(data)
    local hash = 5381
    data = tostring(data or "")
    for i = 1, #data do
        hash = (hash * 33 + data:byte(i)) % 4294967296
    end
    return string.format("%08x", hash)
end

local function cache_busted_zen_asset(file)
    file = tostring(file or "")
    if not Util.endswith(file, "/zen.svg") then
        return file
    end
    local input = io.open(file, "rb")
    if not input then
        return file
    end
    local data = input:read("*a") or ""
    input:close()
    if data == "" then
        return file
    end
    local cache_dir = "/tmp/zenpm-koreader-images/assets"
    if not Util.ensure_dir(cache_dir) then
        return file
    end
    local target = cache_dir .. "/zen-" .. tostring(#data) .. "-" .. file_content_hash(data) .. ".svg"
    if Util.path_exists(target) then
        return target
    end
    local output = io.open(target, "wb")
    if not output then
        return file
    end
    output:write(data)
    output:close()
    return target
end

function App:image_file_for(value)
    value = tostring(value or "")
    if value == "" then
        return nil
    end
    local cacheable = not Util.endswith(value, "/zen.svg")
    if cacheable and self.image_files[value] and Util.path_exists(self.image_files[value]) then
        return self.image_files[value]
    end
    local file = Images.file_for(self.client, self:platform(), value)
    if file then
        file = cache_busted_zen_asset(file)
        if cacheable then
            self.image_files[value] = file
        end
    end
    return file
end

function App:log_icon_once(key, message)
    key = tostring(key or "")
    if key == "" or self.icon_logs[key] then
        return
    end
    self.icon_logs[key] = true
    pcall(function()
        self.client:post_log(message)
    end)
end

local function file_fingerprint(file)
    file = tostring(file or "")
    if file == "" then
        return ""
    end
    local f = io.open(file, "rb")
    if not f then
        return " file_read=failed"
    end
    local head = f:read(160) or ""
    local size = f:seek("end") or 0
    f:close()
    local hint = head:gsub("%s+", " "):sub(1, 80)
    return " file_size=" .. tostring(size)
        .. " file_head_hash=" .. file_content_hash(head)
        .. " file_head=" .. hint
end

local function repo_icon_source(repo, value)
    if repo and repo.icon_url and repo.icon_url ~= "" and value == repo.icon_url then
        return "manifest"
    end
    if value:find("favicon", 1, true) then
        return "favicon"
    end
    if value:find("/assets/", 1, true) then
        return "bundled"
    end
    return "fallback"
end

function App:package_icon_file(pkg)
    local icon_value = Images.package_icon(pkg)
    local fallback_value = Images.package_fallback(pkg)
    local id = tostring(pkg and (pkg.id or pkg.name) or "?")
    local source = icon_value == fallback_value and "repo-fallback" or "package"
    local file = self:image_file_for(icon_value)
    if file then
        self:log_icon_once("package:" .. id .. ":" .. icon_value,
            "[icon] package id=" .. id
            .. " repo=" .. tostring(pkg and pkg.repo or "")
            .. " source=" .. source
            .. " value=" .. tostring(icon_value)
            .. " file=" .. tostring(file)
            .. file_fingerprint(file)
            .. " fallback=" .. tostring(fallback_value))
        return file, icon_value == fallback_value, icon_value, source
    end
    local fallback_file = self:image_file_for(fallback_value)
    self:log_icon_once("package:" .. id .. ":fallback:" .. fallback_value,
        "[icon] package id=" .. id
        .. " repo=" .. tostring(pkg and pkg.repo or "")
        .. " source=fallback"
        .. " value=" .. tostring(fallback_value)
        .. " file=" .. tostring(fallback_file)
        .. file_fingerprint(fallback_file)
        .. " primary_failed=" .. tostring(icon_value))
    return fallback_file, true, fallback_value, "fallback"
end

function App:package_featured_file(pkg)
    return self:image_file_for(Images.featured_image(pkg)) or self:package_icon_file(pkg)
end

function App:repo_icon_file(repo)
    local value = Images.repo_icon(repo)
    local file = self:image_file_for(value)
    local name = tostring(repo and repo.name or "?")
    if file then
        self:log_icon_once("repo:" .. name .. ":" .. value,
            "[icon] repo name=" .. name
            .. " source=" .. repo_icon_source(repo, value)
            .. " value=" .. tostring(value)
            .. " file=" .. tostring(file)
            .. file_fingerprint(file))
        return file
    end
    local fallback = Images.asset("sources.svg")
    local fallback_file = self:image_file_for(fallback)
    self:log_icon_once("repo:" .. name .. ":fallback:" .. fallback,
        "[icon] repo name=" .. name
        .. " source=fallback"
        .. " value=" .. tostring(fallback)
        .. " file=" .. tostring(fallback_file)
        .. file_fingerprint(fallback_file)
        .. " primary_failed=" .. tostring(value))
    return fallback_file
end

function App:scroll_key()
    if self.state.page == "source_details" and self.state.current_repo then
        return "source:" .. tostring(self.state.current_repo.name)
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
    if tab_id == "home" then
        self:show_featured()
    elseif tab_id == "sources" then
        self:show_sources()
    elseif tab_id == "installed" then
        self:show_installed()
    elseif tab_id == "debug" then
        self:show_debug()
    else
        self:show_search()
    end
end

function App:reload_current_page()
    if self.state.page == "package_details" and self.state.current_package then
        self:show_package_details(self.state.current_package.id or self.state.current_package.name, self.state.details_from)
    elseif self.state.page == "source_details" and self.state.current_repo then
        self:show_source_details(self.state.current_repo.name)
    else
        self:navigate(self.state.active_tab or "home")
    end
end

function App:load_packages()
    local ok, data = self.client:list_packages(self:platform())
    if not ok then
        return false, {}, data
    end
    return true, type(data) == "table" and data or {}
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
    local ok, packages, err = self:load_packages()
    if not ok then
        self:set_error(_("Failed to load packages: ") .. tostring(err))
        return
    end
    local ok_manifest, manifest = self.client:request("GET", Constants.REPO_ZENLABS_URL:gsub("/+$", "") .. "/manifest.json", nil)
    self.state.packages = packages
    self.state.featured_packages = Models.select_featured(packages, ok_manifest and manifest or nil)
    self:clear_status()
    self:refresh()
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
    self.state.visible_packages = Models.filter_packages(packages, self.state.filters.search)
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
    self.state.visible_packages = Models.filter_packages(installed, self.state.filters.installed)
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
    self.state.visible_packages = visible
    self:clear_status()
    self:refresh()
end

function App:show_package_details(package_id, from_tab)
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

function App:set_filter(kind, value)
    self.state.filters[kind] = value or ""
    self:reset_scroll(kind == "installed" and "installed" or "search")
    if kind == "installed" then
        self:show_installed()
    else
        self:show_search()
    end
end

function App:prompt_filter(kind)
    local title = kind == "installed" and _("Filter installed packages") or _("Search packages")
    local hint = kind == "installed" and _("Filter installed...") or _("Search...")
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
    elseif action == "uninstall" then
        question = _("Are you sure you want to uninstall ") .. name .. "?"
        label = _("Uninstall")
    end
    Modals.confirm(question, label, function()
        self:start_package_action(pkg, action, on_done)
    end)
end

function App:start_package_action(pkg, action, on_done)
    local backend_action = backend_action_for(action)
    local id = pkg.id or pkg.name
    if not id then
        Modals.info(_("Package has no id."))
        return
    end
    self.busy = true
    Modals.status(action_progress(action) .. " "
        .. package_title(pkg, id) .. "\n\n" .. _("Downloading... Please wait."))
    local ok, err = self.client:package_action(id, backend_action)
    if not ok then
        self.busy = false
        Modals.close_status()
        Modals.info(_("Failed to start package action: ") .. tostring(err))
        return
    end
    self:poll_package_action({
        id = id,
        name = package_title(pkg, id),
        action = action,
        was_installed = pkg.installed and true or false,
        on_done = on_done,
    }, 1)
end

function App:package_action_failure_detail(op)
    local ok, log_text = self.client:get_log(200)
    if not ok or type(log_text) ~= "string" then
        return nil
    end
    local needle = "Package " .. tostring(op.id) .. " " .. backend_action_for(op.action) .. " failed: "
    local detail = nil
    for _, line in ipairs(Util.split_lines(log_text)) do
        local pos = line:find(needle, 1, true)
        if pos then
            detail = line:sub(pos + #needle)
        end
    end
    return detail and Util.trim(detail) ~= "" and Util.trim(detail) or nil
end

function App:poll_package_action(op, attempt)
    UIManager:scheduleIn(Constants.POLL_DELAY_SECONDS, function()
        local ok, packages = self:load_packages()
        if not ok then
            if attempt >= Constants.MAX_POLL_RETRIES then
                self.busy = false
                Modals.close_status()
                Modals.info(_("Package operation status could not be checked. See Debug log."))
                return
            end
            self:poll_package_action(op, attempt + 1)
            return
        end

        local pkg = Models.find_package(packages, op.id)
        local succeeded = false
        if op.action == "reinstall" then
            succeeded = pkg and pkg.installed
        else
            succeeded = pkg and ((pkg.installed and true or false) ~= op.was_installed)
        end

        if succeeded then
            self.busy = false
            local done = action_done(op.action)
            Modals.close_status()
            Modals.info(op.name .. " " .. done .. _(" successfully."))
            if op.on_done then op.on_done() end
        elseif attempt >= Constants.MAX_POLL_RETRIES then
            self.busy = false
            local detail = self:package_action_failure_detail(op)
            local message = action_present(op.action) .. " " .. _("of") .. " " .. op.name .. " did not complete."
            if detail then
                message = message .. "\n\n" .. detail
            else
                message = action_present(op.action) .. " " .. _("of") .. " " .. op.name .. _(" did not complete.\n\nCheck the debug log for details.")
            end
            Modals.close_status()
            Modals.info(message)
        else
            self:poll_package_action(op, attempt + 1)
        end
    end)
end

function App:refresh_repos()
    Modals.info(_("Refreshing repositories..."))
    local ok, data = self.client:refresh_repos()
    if ok then
        self:reload_current_page()
    else
        Modals.info(_("Refresh failed: ") .. tostring(data))
    end
end

function App:show_actions()
    Modals.actions(_("ZenPM"), {
        {
            text = _("Refresh"),
            callback = function()
                if self.state.page == "search" or self.state.active_tab == "search" then
                    self:refresh_repos()
                else
                    self:reload_current_page()
                end
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
