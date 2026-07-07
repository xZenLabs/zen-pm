local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local _ = require("gettext")

local Constants = require("constants")

local ok_https, https = pcall(require, "ssl.https")
local ok_socketutil, socketutil = pcall(require, "socketutil")

local Client = {}

local function url_encode(value)
    value = tostring(value or "")
    return (value:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function Client:new(opts)
    opts = opts or {}
    local o = {
        base_url = opts.base_url or Constants.API_BASE,
    }
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

function Client:request(method, path, body)
    local url = self:build_url(path)
    local sink = {}
    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
    }
    local source
    local body_json

    if body ~= nil then
        body_json = JSON.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body_json)
        source = ltn12.source.string(body_json)
    end

    local request = {
        url = url,
        method = method,
        headers = headers,
        sink = ltn12.sink.table(sink),
        source = source,
    }

    local requester = http
    if url:match("^https://") then
        if not ok_https then
            return false, _("HTTPS support is unavailable in this KOReader build.")
        end
        requester = https
    end

    if ok_socketutil then
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end

    local code, resp_headers, status = socket.skip(1, requester.request(request))

    if ok_socketutil then
        socketutil:reset_timeout()
    end

    local text = table.concat(sink)
    if not code then
        return false, status or _("network error")
    end
    if type(code) ~= "number" then
        code = tonumber(code)
    end
    if not code or code < 200 or code >= 300 then
        local detail = text ~= "" and text or tostring(status or _("request failed"))
        return false, "HTTP " .. tostring(code or "?") .. ": " .. detail, code, resp_headers
    end
    if text == "" then
        return true, nil, code, resp_headers
    end

    local ok, decoded = pcall(JSON.decode, text)
    if ok then
        return true, decoded, code, resp_headers
    end
    return true, text, code, resp_headers
end

function Client:download(path)
    local url = self:build_url(path)
    local sink = {}
    local request = {
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = "image/svg+xml,image/png,image/jpeg,image/gif,*/*",
        },
        sink = ltn12.sink.table(sink),
    }

    local requester = http
    if url:match("^https://") then
        if not ok_https then
            return false, _("HTTPS support is unavailable in this KOReader build.")
        end
        requester = https
    end

    if ok_socketutil then
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end

    local code, resp_headers, status = socket.skip(1, requester.request(request))

    if ok_socketutil then
        socketutil:reset_timeout()
    end

    if type(code) ~= "number" then
        code = tonumber(code)
    end
    if not code or code < 200 or code >= 300 then
        return false, "HTTP " .. tostring(code or "?") .. ": " .. tostring(status or _("download failed")), code, resp_headers
    end
    return true, table.concat(sink), code, resp_headers
end

function Client:health()
    return self:request("GET", "/health", nil)
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
    return self:request("POST", "/repo/refresh", nil)
end

function Client:list_packages(platform, check_updates)
    local path = "/packages"
    local query = {}
    if platform and platform ~= "" then
        table.insert(query, "platform=" .. url_encode(platform))
    end
    if check_updates then
        table.insert(query, "check_updates=1")
    end
    if #query > 0 then
        path = path .. "?" .. table.concat(query, "&")
    end
    return self:request("GET", path, nil)
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

function Client:get_package_assets(id)
    return self:request("GET", "/packages/" .. url_encode(id) .. "/assets", nil)
end

function Client:get_package_readme(id)
    return self:request("GET", "/packages/" .. url_encode(id) .. "/readme", nil)
end

function Client:get_package_releases(id, page)
    local path = "/packages/" .. url_encode(id) .. "/releases"
    if page and page > 1 then
        path = path .. "?page=" .. tostring(page)
    end
    return self:request("GET", path, nil)
end

function Client:get_log(tail)
    return self:request("GET", "/log?tail=" .. tostring(tail or 500), nil)
end

function Client:start_update()
    return self:request("POST", "/update", nil)
end

function Client:post_log(message)
    return self:request("POST", "/log/client", { message = message })
end

return Client
