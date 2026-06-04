local socket = require("socket")

local Constants = require("constants")
local Util = require("zenpm_util")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

local Daemon = {}

function Daemon:new()
    local o = {
        platform = nil,
        backend_path = nil,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

local function path_exists(path)
    if ok_lfs and lfs.attributes(path) then
        return true
    end
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

function Daemon:detect_platform()
    if self.platform then
        return self.platform
    end
    if path_exists("/mnt/onboard/.kobo") then
        self.platform = "kobo"
    elseif path_exists("/mnt/us") then
        self.platform = "kindle"
    else
        self.platform = "host"
    end
    return self.platform
end

function Daemon:platform_filter()
    return self:detect_platform()
end

function Daemon:candidate_backends()
    local platform = self:detect_platform()
    if platform == "kobo" then
        return { "/mnt/onboard/.adds/ZenPM/backend/zenpm" }
    end
    if platform == "kindle" then
        return { "/mnt/us/ZenPM/backend/zenpm" }
    end
    return { "./zenpm", "zenpm" }
end

function Daemon:find_backend()
    if self.backend_path and path_exists(self.backend_path) then
        return self.backend_path
    end
    for _, candidate in ipairs(self:candidate_backends()) do
        if path_exists(candidate) then
            self.backend_path = candidate
            return candidate
        end
    end
    return nil
end

function Daemon:start()
    local backend = self:find_backend()
    if not backend then
        return false, "ZenPM backend not found. Expected " .. table.concat(self:candidate_backends(), " or ") .. "."
    end

    local platform = self:detect_platform()
    local log_path
    if platform == "kobo" then
        log_path = "/mnt/onboard/.adds/ZenPM/ZenPM.log"
    elseif platform == "kindle" then
        log_path = "/mnt/us/ZenPM/ZenPM.log"
    else
        log_path = "/tmp/ZenPM.log"
    end

    local cmd = "ZENPM_PLATFORM=" .. Util.sh_quote(platform)
        .. " nohup " .. Util.sh_quote(backend)
        .. " serve --port 8080 >>" .. Util.sh_quote(log_path)
        .. " 2>&1 &"

    os.execute(cmd)
    return true
end

function Daemon:ensure(client)
    local ok, data = client:health()
    if ok then
        return true, data
    end

    local started, err = self:start()
    if not started then
        return false, err
    end

    for _ = 1, Constants.CONNECT_RETRIES do
        socket.sleep(Constants.CONNECT_RETRY_DELAY_SECONDS)
        ok, data = client:health()
        if ok then
            return true, data
        end
    end

    return false, Constants.DAEMON_UNAVAILABLE_MESSAGE
end

return Daemon
