local socket = require("socket")
local _ = require("gettext")

local Constants = require("constants")
local Util = require("zenpm_util")

local ok_datastorage, DataStorage = pcall(require, "datastorage")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local ok_meta, Meta = pcall(dofile, Constants.PLUGIN_DIR .. "/_meta.lua")

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

local function command_output(cmd)
    local handle = io.popen(cmd)
    if not handle then
        return ""
    end
    local out = handle:read("*a") or ""
    handle:close()
    return Util.trim(out)
end

local function read_all(path)
    local f = io.open(path, "rb")
    if not f then
        return ""
    end
    local data = f:read("*a") or ""
    f:close()
    return data
end

local function read_text(path)
    return Util.trim(read_all(path))
end

-- Signature uses size+mtime only. Hashing the (14MB) binary in interpreted Lua
-- cost ~1.7s per call on-device and ran several times per startup. Size+mtime
-- changes whenever the bundled backend is updated, which is all we need here.
local function file_signature(path)
    if ok_lfs then
        local attrs = lfs.attributes(path)
        if attrs then
            return "size=" .. tostring(attrs.size or "") .. " mtime=" .. tostring(attrs.modification or "")
        end
    end
    -- No lfs: fall back to presence only (cannot detect content changes cheaply).
    return path_exists(path) and "exists" or "missing"
end

local function write_text(path, value)
    local f = io.open(path, "w")
    if not f then
        return false
    end
    f:write(value or "")
    f:close()
    return true
end

local function copy_file(source, target)
    local input = io.open(source, "rb")
    if not input then
        return false
    end
    local tmp = target .. ".tmp"
    local output = io.open(tmp, "wb")
    if not output then
        input:close()
        return false
    end
    while true do
        local chunk = input:read(8192)
        if not chunk then
            break
        end
        output:write(chunk)
    end
    input:close()
    output:close()
    if os.rename(tmp, target) then
        return true
    end
    os.remove(tmp)
    return false
end

local function dirname(path)
    local dir = tostring(path or ""):match("^(.*)/[^/]*$")
    if dir and dir ~= "" then
        return dir
    end
    return "."
end

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
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
    local platform = self:detect_platform()
    if platform == "host" then
        return "koreader"
    end
    return platform
end

function Daemon:package_platform_filter()
    local platform = self:detect_platform()
    if platform == "host" then
        return "host,koreader"
    end
    return platform .. ",koreader"
end

function Daemon:plugin_version()
    if ok_meta and type(Meta) == "table" and Meta.version then
        return tostring(Meta.version)
    end
    return read_text(Constants.PLUGIN_DIR .. "/VERSION")
end

function Daemon:standalone_home()
    local platform = self:detect_platform()
    if platform == "kindle" or platform == "kobo" then
        return self:state_home()
    end
    if ok_datastorage and DataStorage and DataStorage.getSettingsDir then
        return DataStorage:getSettingsDir() .. "/ZenPM"
    end
    return Constants.PLUGIN_DIR .. "/data"
end

-- state_home is the ZENPM_HOME the backend resolves to. On kindle/kobo this is
-- the platform default so state (sqlite DB + script cache) and the managed
-- backend are shared with the Kindle WAF; host runs stay isolated under
-- DataStorage. Must mirror the Go defaults in internal/state/state.go.
function Daemon:state_home()
    local platform = self:detect_platform()
    if platform == "kindle" then
        return "/mnt/us/ZenPM"
    elseif platform == "kobo" then
        return "/mnt/onboard/.adds/ZenPM"
    end
    return self:standalone_home()
end

function Daemon:standalone_backend_dir()
    return self:standalone_home() .. "/backend"
end

function Daemon:standalone_backend()
    return self:standalone_backend_dir() .. "/zenpm"
end

function Daemon:standalone_marker()
    return self:standalone_backend_dir() .. "/backend.version"
end

function Daemon:standalone_pid_file()
    return self:standalone_backend_dir() .. "/zenpm.pid"
end

function Daemon:bundled_backend_dir()
    return Constants.PLUGIN_DIR .. "/backend"
end

function Daemon:detect_abi()
    if path_exists("/lib/ld-linux-armhf.so.3") then
        return "hf"
    end
    return "sf"
end

-- uname output never changes within a session; cache the two reads on self.
function Daemon:uname_kernel()
    if self._uname_kernel == nil then
        self._uname_kernel = command_output("uname -s 2>/dev/null"):lower()
    end
    return self._uname_kernel
end

function Daemon:uname_machine()
    if self._uname_machine == nil then
        self._uname_machine = command_output("uname -m 2>/dev/null"):lower()
    end
    return self._uname_machine
end

function Daemon:host_backend_suffix()
    local kernel = self:uname_kernel()
    local machine = self:uname_machine()
    local os_name = nil
    local arch = nil
    if kernel == "linux" then
        os_name = "linux"
    elseif kernel == "darwin" then
        os_name = "darwin"
    else
        return nil
    end
    if machine == "arm64" or machine == "aarch64" then
        arch = "arm64"
    elseif machine == "x86_64" or machine == "amd64" then
        arch = "amd64"
    else
        return nil
    end
    return os_name .. "-" .. arch
end

function Daemon:host_backend_platform()
    local kernel = self:uname_kernel()
    if kernel == "linux" then
        return "linux"
    elseif kernel == "darwin" then
        return "darwin"
    end
    return nil
end

function Daemon:bundled_backend_candidates()
    local dir = self:bundled_backend_dir()
    local platform = self:detect_platform()
    if platform == "kobo" or platform == "kindle" then
        local abi = self:detect_abi()
        return { dir .. "/zenpm-ereader", dir .. "/zenpm-" .. abi, dir .. "/zenpm" }
    end
    local host_platform = self:host_backend_platform()
    local suffix = self:host_backend_suffix()
    local candidates = {}
    if host_platform then
        table.insert(candidates, dir .. "/zenpm-" .. host_platform)
    end
    if suffix then
        table.insert(candidates, dir .. "/zenpm-" .. suffix)
    end
    table.insert(candidates, dir .. "/zenpm")
    return candidates
end

function Daemon:bundled_backend()
    for _, candidate in ipairs(self:bundled_backend_candidates()) do
        if path_exists(candidate) then
            return candidate
        end
    end
    return nil
end

function Daemon:bundled_backend_version()
    local value = read_text(self:bundled_backend_dir() .. "/VERSION")
    if value ~= "" then
        return value
    end
    return read_text(Constants.PLUGIN_DIR .. "/VERSION")
end

function Daemon:bundled_backend_companions(source)
    if basename(source) == "zenpm-linux" then
        local dir = dirname(source)
        return {
            dir .. "/zenpm-linux-amd64",
            dir .. "/zenpm-linux-arm64",
        }
    end
    return {}
end

function Daemon:desired_marker(source)
    local marker = {
        "plugin_version=" .. self:plugin_version(),
        "backend_version=" .. self:bundled_backend_version(),
        "backend_source=" .. tostring(source or ""),
        "backend_signature=" .. file_signature(source),
    }
    for _, companion in ipairs(self:bundled_backend_companions(source)) do
        table.insert(marker, "backend_companion=" .. companion .. " " .. file_signature(companion))
    end
    return table.concat(marker, "\n") .. "\n"
end

function Daemon:runtime_dirs()
    local home = self:standalone_home()
    -- The backend's state.Init MkdirAll's its own runtime/state dirs; we only
    -- ensure the dir holding the bundled backend binary exists here.
    return {
        home,
        self:standalone_backend_dir(),
    }
end

function Daemon:ensure_runtime_dirs()
    local had_missing = false
    for _, dir in ipairs(self:runtime_dirs()) do
        if not path_exists(dir) then
            had_missing = true
        end
        if not Util.ensure_dir(dir) then
            return had_missing, _("Could not create ZenPM directory: ") .. dir
        end
    end
    return had_missing, nil
end

function Daemon:stop_standalone_backend()
    local pid = read_text(self:standalone_pid_file())
    if pid ~= "" and pid:match("^%d+$") then
        os.execute("kill " .. pid .. " >/dev/null 2>&1")
    end
    os.execute("pkill -f " .. Util.sh_quote(self:standalone_backend() .. " serve --port 8080") .. " >/dev/null 2>&1")
    for _, candidate in ipairs(self:bundled_backend_candidates()) do
        os.execute("pkill -f " .. Util.sh_quote(candidate .. " serve --port 8080") .. " >/dev/null 2>&1")
    end
    socket.sleep(0.8)
end

function Daemon:stop_known_backends()
    self:stop_standalone_backend()
    for _, candidate in ipairs(self:candidate_backends()) do
        os.execute("pkill -f " .. Util.sh_quote(candidate .. " serve --port 8080") .. " >/dev/null 2>&1")
    end
    socket.sleep(0.8)
end

function Daemon:health_matches(data)
    if type(data) ~= "table" then
        return false
    end
    return tostring(data.home or "") == self:state_home()
end

function Daemon:ensure_backend_files()
    local dirs_missing, dirs_err = self:ensure_runtime_dirs()
    if dirs_err then
        return false, dirs_err
    end
    local source = self:bundled_backend()
    if not source then
        return false, _("Bundled ZenPM backend not found. Expected ") .. table.concat(self:bundled_backend_candidates(), " " .. _("or") .. " ") .. "."
    end
    local backend_dir = self:standalone_backend_dir()
    if not Util.ensure_dir(backend_dir) then
        return false, _("Could not create ZenPM settings directory: ") .. backend_dir
    end
    local backend = self:standalone_backend()
    local marker = self:desired_marker(source)
    local changed = dirs_missing or read_all(self:standalone_marker()) ~= marker or not path_exists(backend)
    for _, companion in ipairs(self:bundled_backend_companions(source)) do
        if not path_exists(backend_dir .. "/" .. basename(companion)) then
            changed = true
        end
    end
    if not changed then
        os.execute("chmod +x " .. Util.sh_quote(backend))
        for _, companion in ipairs(self:bundled_backend_companions(source)) do
            os.execute("chmod +x " .. Util.sh_quote(backend_dir .. "/" .. basename(companion)))
        end
        self.backend_path = backend
        return false, nil
    end
    if not copy_file(source, backend) then
        return false, _("Could not install bundled ZenPM backend to: ") .. backend
    end
    os.execute("chmod +x " .. Util.sh_quote(backend))
    for _, companion in ipairs(self:bundled_backend_companions(source)) do
        if not path_exists(companion) then
            return false, _("Bundled ZenPM backend not found. Expected ") .. companion .. "."
        end
        local target = backend_dir .. "/" .. basename(companion)
        if not copy_file(companion, target) then
            return false, _("Could not install bundled ZenPM backend to: ") .. target
        end
        os.execute("chmod +x " .. Util.sh_quote(target))
    end
    write_text(self:standalone_backend_dir() .. "/VERSION", self:bundled_backend_version() .. "\n")
    write_text(self:standalone_marker(), marker)
    self.backend_path = backend
    self:stop_standalone_backend()
    return true, nil
end

function Daemon:candidate_backends()
    local platform = self:detect_platform()
    local candidates = { self:standalone_backend() }
    if platform == "kobo" then
        table.insert(candidates, "/mnt/onboard/.adds/ZenPM/backend/zenpm")
    end
    if platform == "kindle" then
        table.insert(candidates, "/mnt/us/ZenPM/backend/zenpm")
    end
    for _, candidate in ipairs(self:bundled_backend_candidates()) do
        table.insert(candidates, candidate)
    end
    if platform == "host" then
        table.insert(candidates, "./zenpm")
        table.insert(candidates, "zenpm")
    end
    return candidates
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
    local changed, err = self:ensure_backend_files()
    if err then
        return false, err
    end
    if changed then
        self.backend_path = self:standalone_backend()
    end
    local backend = self:find_backend()
    if not backend then
        return false, _("ZenPM backend not found. Expected ") .. table.concat(self:candidate_backends(), " " .. _("or") .. " ") .. "."
    end

    local platform = self:detect_platform()
    -- set_home is the ZENPM_HOME to export; nil lets the backend resolve the
    -- platform default so device state is shared with the Kindle WAF.
    local set_home = nil
    local write_pid = false
    local log_path = nil
    if backend == self:standalone_backend() or tostring(backend):find(self:bundled_backend_dir(), 1, true) == 1 then
        if backend ~= self:standalone_backend() then
            local _, prep_err = self:ensure_backend_files()
            if prep_err then
                return false, prep_err
            end
            backend = self:standalone_backend()
        end
        write_pid = true
        if platform == "host" then
            set_home = self:standalone_home()
        end
        log_path = self:state_home() .. "/ZenPM.log"
    elseif platform == "kobo" then
        log_path = "/mnt/onboard/.adds/ZenPM/ZenPM.log"
    elseif platform == "kindle" then
        log_path = "/mnt/us/ZenPM/ZenPM.log"
    else
        log_path = "/tmp/ZenPM.log"
    end

    local cmd = "ZENPM_PLATFORM=" .. Util.sh_quote(platform)
    if set_home then
        cmd = cmd .. " ZENPM_HOME=" .. Util.sh_quote(set_home)
    end
    cmd = cmd
        .. " nohup " .. Util.sh_quote(backend)
        .. " serve --port 8080 >>" .. Util.sh_quote(log_path)
        .. " 2>&1 &"
    if write_pid then
        cmd = cmd .. " echo $! >" .. Util.sh_quote(self:standalone_pid_file())
    end

    os.execute(cmd)
    return true
end

function Daemon:ensure(client, force_start)
    local ok, data = false, nil
    if not force_start then
        ok, data = client:health()
        if ok and self:health_matches(data) then
            return true, data
        elseif ok then
            self:stop_known_backends()
            force_start = true
        end
    end

    local started, err = self:start()
    if not started then
        return false, err
    end

    for attempt = 1, Constants.CONNECT_RETRIES do
        if attempt <= 1 then
            socket.sleep(Constants.CONNECT_INITIAL_DELAY_SECONDS)
        else
            socket.sleep(Constants.CONNECT_RETRY_DELAY_SECONDS)
        end
        ok, data = client:health()
        if ok and self:health_matches(data) then
            return true, data
        end
    end

    return false, Constants.DAEMON_UNAVAILABLE_MESSAGE
end

return Daemon
