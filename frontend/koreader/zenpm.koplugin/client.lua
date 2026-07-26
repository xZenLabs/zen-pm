local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local _ = require("gettext")

local Constants = require("constants")

local ok_https, https = pcall(require, "ssl.https")
local ok_socketutil, socketutil = pcall(require, "socketutil")
local ok_logger, logger = pcall(require, "logger")
local ok_android = pcall(require, "android")
local ok_device, Device = pcall(require, "device")

local Client = {}
local UI_BLOCK_TIMEOUT_SECONDS = ok_android and 10 or 1
local UI_TOTAL_TIMEOUT_SECONDS = ok_android and 30 or 4
local REPO_REFRESH_TIMEOUT = { block = 10, total = 60 }
local PACKAGE_LIST_TIMEOUT = { block = 5, total = 20 }
local PACKAGE_RELEASES_TIMEOUT = { block = 10, total = 15 }
local PLUGIN_SCAN_TIMEOUT = { block = 10, total = 60 }
local LOG_TIMEOUT = { block = 5, total = 30 }

local function url_encode(value)
    value = tostring(value or "")
    return (value:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function request_target(url)
    if url:sub(1, #Constants.API_BASE) == Constants.API_BASE then
        return _("ZenPM backend")
    end
    local host = (url:match("^https?://([^/%?#:]+)") or ""):lower()
    if host == "github.com" or host:match("%.github%.com$") or host:match("githubusercontent%.com$") then
        return _("GitHub")
    end
    if host:match("^zen%-pm%-reporter%.") then
        return _("ZenPM bug reporter")
    end
    return _("remote server")
end

local function connection_error(url, detail)
    return _("Could not connect to ") .. request_target(url) .. ": "
        .. tostring(detail or _("request failed"))
end

local function http_error(url, code, detail)
    local message = request_target(url) .. _(" returned HTTP ") .. tostring(code)
    if detail and detail ~= "" then
        message = message .. ": " .. detail
    end
    return message
end

local function log_request(method, url, started_at, outcome)
    if not (ok_logger and logger and logger.info) then return end
    local elapsed_ms = math.floor((socket.gettime() - started_at) * 1000)
    logger.info("ZenPM HTTP " .. method .. " " .. url .. " " .. outcome .. " after " .. elapsed_ms .. "ms")
end

function Client:new(opts)
    opts = opts or {}
    local unix_socket = opts.unix_socket_path
    if unix_socket == nil and ok_device and Device and type(Device.isPocketBook) == "function" then
        local ok, is_pocketbook = pcall(Device.isPocketBook, Device)
        if ok and is_pocketbook then
            unix_socket = Constants.POCKETBOOK_SOCKET
        end
    end
    local o = {
        base_url = opts.base_url or Constants.API_BASE,
        unix_socket = unix_socket,
        unix_http = opts.unix_http,
    }
    if o.unix_socket and not o.unix_http then
        local ok, transport = pcall(dofile, Constants.PLUGIN_DIR .. "/unix_http.lua")
        if ok then
            o.unix_http = transport
        else
            o.unix_http_error = transport
        end
    end
    setmetatable(o, self)
    self.__index = self
    return o
end

function Client:build_url(path)
    if tostring(path or ""):match("^https?://") then
        return path
    end
    return self.base_url .. path
end

function Client:request(method, path, body, timeout)
    local backend_path = not tostring(path or ""):match("^https?://")
    local url = self:build_url(path)
    local started_at = socket.gettime()
    if ok_logger and logger and logger.info then
        logger.info("ZenPM HTTP " .. method .. " " .. url .. " started")
    end
    local sink = {}
    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
    }
    local body_json

    if body ~= nil then
        body_json = JSON.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body_json)
    end

    local code, resp_headers, status
    local text
    if self.unix_socket and backend_path then
        if not self.unix_http then
            local err = connection_error(url, self.unix_http_error or _("Unix socket support is unavailable."))
            log_request(method, url, started_at, err)
            return false, err
        end
        local response_body
        code, resp_headers, response_body, status = self.unix_http.request(
            self.unix_socket,
            method,
            path,
            body_json,
            timeout and timeout.total or UI_TOTAL_TIMEOUT_SECONDS,
            headers["Accept"])
        text = response_body or ""
    else
        local request = {
            url = url,
            method = method,
            headers = headers,
            sink = ltn12.sink.table(sink),
            source = body_json and ltn12.source.string(body_json) or nil,
        }

        local requester = http
        if url:match("^https://") then
            if not ok_https then
                local err = connection_error(url, _("HTTPS support is unavailable in this KOReader build."))
                log_request(method, url, started_at, err)
                return false, err
            end
            requester = https
        end

        if ok_socketutil then
            socketutil:set_timeout(
                timeout and timeout.block or UI_BLOCK_TIMEOUT_SECONDS,
                timeout and timeout.total or UI_TOTAL_TIMEOUT_SECONDS)
        end

        code, resp_headers, status = socket.skip(1, requester.request(request))

        if ok_socketutil then
            socketutil:reset_timeout()
        end
        text = table.concat(sink)
    end

    local numeric_code = tonumber(code)
    if not numeric_code then
        local err = connection_error(url, code or status or _("network error"))
        log_request(method, url, started_at, err)
        return false, err
    end
    if numeric_code < 200 or numeric_code >= 300 then
        local detail = text ~= "" and text or nil
        local err = http_error(url, numeric_code, detail)
        log_request(method, url, started_at, err)
        return false, err, numeric_code, resp_headers
    end
    if text == "" then
        log_request(method, url, started_at, "HTTP " .. numeric_code)
        return true, nil, numeric_code, resp_headers
    end

    local ok, decoded = pcall(JSON.decode, text)
    if ok then
        log_request(method, url, started_at, "HTTP " .. numeric_code)
        return true, decoded, numeric_code, resp_headers
    end
    log_request(method, url, started_at, "HTTP " .. numeric_code)
    return true, text, numeric_code, resp_headers
end

function Client:download(path)
    local backend_path = not tostring(path or ""):match("^https?://")
    local url = self:build_url(path)
    local started_at = socket.gettime()
    if ok_logger and logger and logger.info then
        logger.info("ZenPM HTTP GET " .. url .. " started")
    end
    local sink = {}
    local accept = "image/svg+xml,image/png,image/jpeg,image/gif,*/*"
    local code, resp_headers, status
    local response_body
    if self.unix_socket and backend_path then
        if not self.unix_http then
            local err = connection_error(url, self.unix_http_error or _("Unix socket support is unavailable."))
            log_request("GET", url, started_at, err)
            return false, err
        end
        code, resp_headers, response_body, status = self.unix_http.request(
            self.unix_socket,
            "GET",
            path,
            nil,
            UI_TOTAL_TIMEOUT_SECONDS,
            accept)
    else
        local request = {
            url = url,
            method = "GET",
            headers = {
                ["Accept"] = accept,
            },
            sink = ltn12.sink.table(sink),
        }

        local requester = http
        if url:match("^https://") then
            if not ok_https then
                local err = connection_error(url, _("HTTPS support is unavailable in this KOReader build."))
                log_request("GET", url, started_at, err)
                return false, err
            end
            requester = https
        end

        if ok_socketutil then
            socketutil:set_timeout(UI_BLOCK_TIMEOUT_SECONDS, UI_TOTAL_TIMEOUT_SECONDS)
        end

        code, resp_headers, status = socket.skip(1, requester.request(request))

        if ok_socketutil then
            socketutil:reset_timeout()
        end
        response_body = table.concat(sink)
    end

    local numeric_code = tonumber(code)
    if not numeric_code then
        local err = connection_error(url, code or status or _("download failed"))
        log_request("GET", url, started_at, err)
        return false, err
    end
    if numeric_code < 200 or numeric_code >= 300 then
        local err = http_error(url, numeric_code, nil)
        log_request("GET", url, started_at, err)
        return false, err, numeric_code, resp_headers
    end
    log_request("GET", url, started_at, "HTTP " .. numeric_code)
    return true, response_body or "", numeric_code, resp_headers
end

function Client:health()
    -- Startup runs on KOReader's UI thread. A daemon that is unavailable or
    -- wedged must not make the reader appear unresponsive while it is probed.
    return self:request("GET", "/health", nil, { block = 1, total = 1 })
end

function Client:list_repos()
    return self:request("GET", "/repos", nil)
end

function Client:add_repo(name, url)
    return self:request("POST", "/repos", { name = name, url = url })
end

function Client:remove_repo(name)
    return self:request("DELETE", "/repos/" .. url_encode(name), nil)
end

function Client:refresh_repos()
    return self:request("POST", "/repo/refresh", nil, REPO_REFRESH_TIMEOUT)
end

function Client:scan_installed_plugins()
    return self:request("POST", "/koreader/plugins/scan", nil, PLUGIN_SCAN_TIMEOUT)
end

function Client:list_packages(platform, check_updates, allow_prerelease)
    local path = "/packages"
    local query = {}
    if platform and platform ~= "" then
        table.insert(query, "platform=" .. url_encode(platform))
    end
    if check_updates then
        table.insert(query, "check_updates=1")
    end
    if allow_prerelease then
        table.insert(query, "beta=1")
    end
    if #query > 0 then
        path = path .. "?" .. table.concat(query, "&")
    end
    return self:request("GET", path, nil, PACKAGE_LIST_TIMEOUT)
end

function Client:package_action(id, action, asset, release)
    local path = "/packages/" .. url_encode(id) .. "/" .. action
    local query = {}
    if asset and asset ~= "" then
        table.insert(query, "asset=" .. url_encode(asset))
    end
    if release and release ~= "" then
        table.insert(query, "release=" .. url_encode(release))
    end
    if #query > 0 then
        path = path .. "?" .. table.concat(query, "&")
    end
    return self:request("POST", path, nil)
end

function Client:update_all_packages()
    return self:request("POST", "/packages/update", nil)
end

function Client:get_package_assets(id)
    return self:request("GET", "/packages/" .. url_encode(id) .. "/assets", nil)
end

function Client:get_package_readme(id)
    return self:request("GET", "/packages/" .. url_encode(id) .. "/readme", nil)
end

function Client:get_package_release_notes(id, prerelease)
    local path = "/packages/" .. url_encode(id) .. "/release-notes"
    if prerelease then
        path = path .. "?prerelease=1"
    end
    return self:request("GET", path, nil)
end

function Client:get_package_releases(id)
    return self:request("GET", "/packages/" .. url_encode(id) .. "/releases", nil, PACKAGE_RELEASES_TIMEOUT)
end

function Client:get_log(tail)
    return self:request("GET", "/log?tail=" .. tostring(tail or 500), nil, LOG_TIMEOUT)
end

function Client:start_update()
    return self:request("POST", "/update", nil)
end

function Client:post_log(message)
    return self:request("POST", "/log/client", { message = message })
end

return Client
