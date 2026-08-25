local socket = require("socket")
local _ = require("gettext")

local Constants = require("zenpm_constants")
local Util = require("zenpm_util")

local ok_datastorage, DataStorage = pcall(require, "datastorage")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local ok_android, android = pcall(require, "android")

local Daemon = {}
local cli_wrapper_marker = "# Managed by ZenPM."
local legacy_tcp_port = 8080

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

local function append_text(path, value)
    local f = io.open(path, "a")
    if not f then
        return false
    end
    f:write(value or "")
    f:close()
    return true
end

local function log_timestamp()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
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

local function absolute_path(path, base)
    path = tostring(path or "")
    if path:sub(1, 1) == "/" then
        return path
    end
    base = tostring(base or "")
    if base == "" then
        return path
    end
    return base:gsub("/+$", "") .. "/" .. path:gsub("^%./", "")
end

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

local function uri_escape(value)
    return (tostring(value or ""):gsub("([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

function Daemon:detect_platform()
    if self.platform then
        return self.platform
    end
    if self:is_android() then
        self.platform = "android"
    elseif path_exists("/mnt/onboard/.kobo") then
        self.platform = "kobo"
    elseif path_exists("/mnt/us") then
        self.platform = "kindle"
    elseif self:host_backend_suffix() then
        self.platform = "host"
    else
        self.platform = "ereader"
    end
    return self.platform
end

local function version_is_newer(version, maximum)
    local version_parts = {}
    local maximum_parts = {}
    for part in tostring(version or ""):gmatch("%d+") do
        table.insert(version_parts, tonumber(part))
    end
    for part in tostring(maximum or ""):gmatch("%d+") do
        table.insert(maximum_parts, tonumber(part))
    end
    if #version_parts < 3 or #maximum_parts < 3 then
        return false
    end
    local count = math.max(#version_parts, #maximum_parts)
    for index = 1, count do
        local left = version_parts[index] or 0
        local right = maximum_parts[index] or 0
        if left ~= right then
            return left > right
        end
    end
    return false
end

function Daemon:kindle_firmware_version()
    if self:detect_platform() ~= "kindle" then
        return nil
    end
    return read_text("/etc/version.txt"):match("(%d+%.%d+%.%d+[%d%.]*)")
end

function Daemon:kindle_kpm_installed()
    return path_exists("/mnt/us/kmc/kpm")
end

function Daemon:kindle_homepage_install_supported()
    if self:detect_platform() ~= "kindle" or self:kindle_kpm_installed() then
        return false
    end
    local version = self:kindle_firmware_version()
    return not version_is_newer(version, "5.18.3")
end

function Daemon:is_android()
    return ok_android and android ~= nil
end

function Daemon:is_pocketbook()
    return path_exists("/ebrmain")
end

function Daemon:unix_socket_path()
    return Constants.UNIX_SOCKET
end

function Daemon:platform_filter()
    local platform = self:detect_platform()
    if platform == "host" or platform == "android" then
        return "koreader"
    end
    return platform
end

function Daemon:package_platform_filter()
    local platform = self:detect_platform()
    if platform == "host" then
        return "host,koreader"
    end
    if platform == "android" then
        return "android,koreader"
    end
    return platform .. ",koreader"
end

function Daemon:plugin_version()
    local version = read_text(Constants.PLUGIN_DIR .. "/VERSION")
    if version ~= "" then
        return version
    end
    local ok_meta, meta = pcall(dofile, Constants.PLUGIN_DIR .. "/_meta.lua")
    if ok_meta and type(meta) == "table" and meta.version then
        return tostring(meta.version)
    end
    return ""
end

function Daemon:native_home()
    local platform = self:detect_platform()
    if platform == "kindle" then
        return "/mnt/us/ZenPM"
    elseif platform == "kobo" then
        return "/mnt/onboard/.adds/ZenPM"
    end
    return nil
end

function Daemon:device_home()
    if ok_android and android and type(android.getExternalStoragePath) == "function" then
        local ok, storage = pcall(android.getExternalStoragePath)
        if ok and type(storage) == "string" and storage ~= "" then
            return storage .. "/ZenPM"
        end
    end
    if ok_datastorage and DataStorage and DataStorage.getSettingsDir then
        return DataStorage:getSettingsDir() .. "/ZenPM"
    end
    return Constants.PLUGIN_DIR .. "/data"
end

function Daemon:standalone_home()
    return self:device_home()
end

-- state_home is the ZENPM_HOME the backend resolves to. Keep all KOReader
-- plugin state under KOReader's settings directory.
function Daemon:state_home()
    return self:device_home()
end

function Daemon:android_companion_version()
    if not self:is_android() then
        return nil
    end
    local version = read_text(self:state_home() .. "/android-companion.version")
    return version ~= "" and version or nil
end

function Daemon:koreader_data_dir()
    if ok_datastorage and DataStorage and DataStorage.getFullDataDir then
        local data_dir = DataStorage:getFullDataDir()
        if type(data_dir) == "string" and data_dir ~= "" then
            return data_dir
        end
    end
    local plugin_dir = tostring(Constants.PLUGIN_DIR or "")
    local root = plugin_dir:match("^(.*)/plugins%-user/[^/]+$")
        or plugin_dir:match("^(.*)/plugins/[^/]+$")
    return root or ""
end

function Daemon:koreader_plugin_dir()
    local plugin_dir = tostring(Constants.PLUGIN_DIR or "")
    local parent = plugin_dir:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
        return parent
    end
    return self:koreader_data_dir() .. "/plugins"
end

function Daemon:koreader_patch_dir()
    return self:koreader_data_dir() .. "/patches"
end

function Daemon:koreader_root()
    return self:koreader_data_dir()
end

function Daemon:standalone_backend_dir()
    return self:standalone_home() .. "/backend"
end

function Daemon:standalone_backend()
    return self:standalone_backend_dir() .. "/zenpm"
end

function Daemon:cli_wrapper_path()
    if self:detect_platform() == "kindle" then
        return "/usr/local/bin/zenpm"
    end
    return self:koreader_data_dir() .. "/zenpm"
end

function Daemon:legacy_cli_wrapper_path()
    return Constants.PLUGIN_DIR .. "/bin/zenpm"
end

function Daemon:cli_alias_path()
    return dirname(self:cli_wrapper_path()) .. "/zpm"
end

function Daemon:log_cli(message)
    Util.ensure_dir(self:state_home())
    append_text(self:state_home() .. "/ZenPM.log", log_timestamp() .. "  ZenPM CLI: " .. message .. "\n")
end

function Daemon:write_cli_wrapper(path, script)
    if read_all(path) == script then
        return true
    end
    self:log_cli("installing at " .. path)
    local rootfs = dirname(path) == "/usr/local/bin"
    if rootfs and os.execute("mntroot rw") ~= 0 then
        self:log_cli("could not make the root filesystem writable")
        return false
    end
    local ok = Util.ensure_dir(dirname(path)) and write_text(path, script)
    if ok then
        ok = os.execute("chmod +x " .. Util.sh_quote(path)) == 0
    end
    if rootfs then
        os.execute("mntroot ro")
    end
    self:log_cli(ok and "installed at " .. path or "installation failed at " .. path)
    return ok
end

function Daemon:remove_cli_wrapper(path)
    if not read_all(path):find(cli_wrapper_marker, 1, true) then
        return true
    end
    local rootfs = dirname(path) == "/usr/local/bin"
    if rootfs and os.execute("mntroot rw") ~= 0 then
        return false
    end
    os.remove(path)
    os.remove(path .. ".tmp")
    if rootfs then
        os.execute("mntroot ro")
    end
    return true
end

function Daemon:install_cli_wrapper()
    if self:is_android() then
        return true
    end
    local wrapper = self:cli_wrapper_path()
    if not self:remove_cli_wrapper(self:legacy_cli_wrapper_path()) then
        return false
    end
    local data_dir = self:koreader_data_dir()
    local state_home = absolute_path(self:state_home(), data_dir)
    local script = table.concat({
        "#!/bin/sh",
        cli_wrapper_marker,
        "export ZENPM_PLATFORM=" .. Util.sh_quote(self:package_platform_filter()),
        "export ZENPM_HOME=" .. Util.sh_quote(state_home),
        "export ZENPM_KOREADER_DIR=" .. Util.sh_quote(data_dir),
        "export ZENPM_KOREADER_PLUGIN_DIR=" .. Util.sh_quote(self:koreader_plugin_dir()),
        "export ZENPM_KOREADER_PATCH_DIR=" .. Util.sh_quote(self:koreader_patch_dir()),
        "exec " .. Util.sh_quote(absolute_path(self:standalone_backend(), data_dir)) .. " \"$@\"",
        "",
    }, "\n")
    if not self:write_cli_wrapper(wrapper, script) then
        return false
    end
    return self:write_cli_wrapper(self:cli_alias_path(), script)
end

function Daemon:remove_all_settings()
    self:stop_standalone_backend()
    local cli_removed = self:remove_cli_wrapper(self:cli_wrapper_path())
    local cli_alias_removed = self:remove_cli_wrapper(self:cli_alias_path())
    local legacy_cli_removed = self:remove_cli_wrapper(self:legacy_cli_wrapper_path())
    local settings_removed = os.execute("rm -rf " .. Util.sh_quote(self:state_home())) == 0
    local standalone_removed = true
    if self:detect_platform() == "kindle" then
        standalone_removed = os.execute("rm -rf " .. Util.sh_quote("/mnt/us/ZenPM")) == 0
            and os.execute("rm -rf " .. Util.sh_quote("/mnt/us/.ZenPM")) == 0
            and (os.remove("/mnt/us/documents/ZenPM.sh") or not path_exists("/mnt/us/documents/ZenPM.sh"))
    end
    return cli_removed and cli_alias_removed and legacy_cli_removed and settings_removed and standalone_removed
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

function Daemon:ereader_backend_suffix()
    -- KOReader's PocketBook target uses the soft-float ABI even on devices
    -- whose firmware also ships a hard-float loader.
    if self:is_pocketbook() then
        return "sf"
    end
    if self:detect_platform() == "kobo" then
        local machine = self:uname_machine()
        if machine == "arm64" or machine == "aarch64" then
            return "arm64"
        end
    end
    return self:detect_abi()
end

function Daemon:expected_plugin_asset()
    local version = self:plugin_version()
    if version == "" then
        return nil
    end
    local platform = self:detect_platform()
    if platform == "kindle" or platform == "kobo" or platform == "ereader" then
        if platform == "kobo" and self:ereader_backend_suffix() == "arm64" then
            return "ZenPM-koreader-linux-" .. version .. ".zip"
        end
        return "ZenPM-koreader-ereader-" .. version .. ".zip"
    end
    if self:is_android() then
        return "ZenPM-koreader-android-" .. version .. ".zip"
    end
    local host_platform = self:host_backend_platform()
    if host_platform == "darwin" then
        return "ZenPM-koreader-macos-" .. version .. ".zip"
    elseif host_platform == "linux" then
        return "ZenPM-koreader-linux-" .. version .. ".zip"
    end
    return nil
end

function Daemon:backend_not_started_error()
    local message = _("ZenPM backend did not start. Ensure you used the correct ZenPM version for this device.")
    local asset = self:expected_plugin_asset()
    if asset then
        message = message .. " " .. _("Download this asset: ") .. asset
    end
    return message
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
    local ereader_suffix = self:ereader_backend_suffix()
    if platform == "kobo" or platform == "kindle" or platform == "ereader" then
        if platform == "kobo" and ereader_suffix == "arm64" then
            return { dir .. "/zenpm-linux" }
        end
        return { dir .. "/zenpm-" .. ereader_suffix }
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
    table.insert(candidates, dir .. "/zenpm-ereader")
    table.insert(candidates, dir .. "/zenpm-hf")
    table.insert(candidates, dir .. "/zenpm-" .. self:detect_abi())
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

function Daemon:installed_backend_version()
    if self:is_pocketbook() then
        return self:bundled_backend_version()
    end
    return read_text(self:standalone_backend_dir() .. "/VERSION")
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
    if self:is_android() then
        self:stop_android_backend()
        return
    end
    local pid = read_text(self:standalone_pid_file())
    if pid ~= "" and pid:match("^%d+$") then
        os.execute("kill " .. pid .. " >/dev/null 2>&1")
    end
    self:stop_tcp_backend(self:standalone_backend())
    self:stop_socket_backend(self:standalone_backend())
    for _, candidate in ipairs(self:bundled_backend_candidates()) do
        self:stop_tcp_backend(candidate)
        self:stop_socket_backend(candidate)
    end
    socket.sleep(0.8)
end

function Daemon:stop_known_backends()
    self:stop_standalone_backend()
    if self:is_android() then
        return
    end
    for _, candidate in ipairs(self:candidate_backends()) do
        self:stop_tcp_backend(candidate)
        self:stop_socket_backend(candidate)
    end
    socket.sleep(0.8)
end

function Daemon:stop_socket_backend(backend)
    os.execute("pkill -f " .. Util.sh_quote(backend .. " serve --socket " .. self:unix_socket_path()) .. " >/dev/null 2>&1")
end

function Daemon:stop_tcp_backend(backend)
    for _, port in ipairs({ Constants.PORT, legacy_tcp_port }) do
        os.execute("pkill -f " .. Util.sh_quote(backend .. " serve --port " .. port) .. " >/dev/null 2>&1")
    end
end

function Daemon:stop_android_backend()
    local uri = "zenpm://stop"
    if android and type(android.openLink) == "function" then
        local called, opened = pcall(android.openLink, uri)
        if called and opened then
            return true
        end
    end
    local cmd = "/system/bin/am start -W -n org.zenlabs.zenpm/.ZenPMActivity"
        .. " -a android.intent.action.VIEW -d " .. Util.sh_quote(uri)
    return os.execute(cmd) == 0
end

function Daemon:health_matches(data)
    if type(data) ~= "table" then
        return false
    end
    -- The Android companion keeps its state in private app storage, which is
    -- intentionally different from KOReader's shared ZenPM directory.
    if ok_android then
        return data.ok == true
    end
    if tostring(data.home or "") ~= self:state_home() then
        return false
    end
    local expected_version = self:bundled_backend_version():gsub("^v", "")
    local running_version = tostring(data.version or ""):gsub("^v", "")
    return expected_version == "" or running_version == expected_version
end

function Daemon:ensure_backend_files()
    if ok_android then
        local dirs_missing, dirs_err = self:ensure_runtime_dirs()
        return dirs_missing, dirs_err
    end
    local dirs_missing, dirs_err = self:ensure_runtime_dirs()
    if dirs_err then
        return false, dirs_err
    end
    local source = self:bundled_backend()
    if not source then
        return false, self:backend_not_started_error()
    end
    -- PocketBook mounts KOReader's settings without allowing executable bits
    -- to be set. Keep using the executable shipped with the plugin instead.
    if self:is_pocketbook() then
        self.backend_path = source
        return false, nil
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
    -- Normalize the selected ABI-specific source (for example zenpm-hf) to
    -- the stable executable name used by the launcher.
    if not copy_file(source, backend) then
        return false, _("Could not install bundled ZenPM backend to: ") .. backend
    end
    os.execute("chmod +x " .. Util.sh_quote(backend))
    for _, companion in ipairs(self:bundled_backend_companions(source)) do
        if not path_exists(companion) then
            return false, self:backend_not_started_error()
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
    local candidates = { self:standalone_backend() }
    for _, candidate in ipairs(self:bundled_backend_candidates()) do
        table.insert(candidates, candidate)
    end
    for _, candidate in ipairs(candidates) do
        if path_exists(candidate) then
            self.backend_path = candidate
            return candidate
        end
    end
    return nil
end

function Daemon:start(prepared)
    local changed = false
    if not prepared then
        local err
        changed, err = self:ensure_backend_files()
        if err then
            return false, err
        end
    end
    if ok_android then
        local root = self:koreader_root()
        local companion_log = self:state_home() .. "/android-companion.log"
        if android and type(android.openLink) == "function" then
            local uri = "zenpm://start?home=" .. uri_escape(self:state_home())
                .. "&root=" .. uri_escape(root)
            append_text(companion_log, log_timestamp() .. "  KOReader opening ZenPM companion.\n")
            local called, opened = pcall(android.openLink, uri)
            append_text(companion_log, log_timestamp() .. "  ZenPM companion link result: called="
                .. tostring(called) .. " opened=" .. tostring(opened) .. "\n")
            if called and opened then
                return true
            end
        end
        -- Some Android builds decline custom-scheme links from KOReader. Start
        -- the exported activity explicitly first so it can start its own
        -- foreground service while it is in the foreground.
        local uri = "zenpm://start?home=" .. uri_escape(self:state_home())
            .. "&root=" .. uri_escape(root)
        local activity_args = " -W -n org.zenlabs.zenpm/.ZenPMActivity"
            .. " -a android.intent.action.VIEW -d " .. Util.sh_quote(uri)
        local service_args = " -n org.zenlabs.zenpm/.ZenPMService"
            .. " --es zenpm_log_home " .. Util.sh_quote(self:state_home())
            .. " --es koreader_root " .. Util.sh_quote(root)
        append_text(companion_log, log_timestamp() .. "  KOReader starting ZenPM companion explicitly.\n")
        -- ActivityManager writes command output from system_server. Some BOOX
        -- SELinux policies reject the external-storage log FD, causing the
        -- otherwise valid Binder request itself to fail. Log the exit status
        -- from KOReader instead and keep ActivityManager's output on /dev/null.
        local cmd = "( /system/bin/am start" .. activity_args
            .. " || /system/bin/am start-foreground-service" .. service_args
            .. " || /system/bin/am startservice" .. service_args
            .. " ) </dev/null >/dev/null 2>&1"
        local result = os.execute(cmd)
        append_text(companion_log, log_timestamp() .. "  ZenPM explicit start result: "
            .. tostring(result) .. "\n")
        if result ~= 0 then
            return false, _("ZenPM Android companion is not installed or could not start. See ") .. companion_log
        end
        return true
    end
    if changed then
        self.backend_path = self:standalone_backend()
    end
    local backend = self:find_backend()
    if not backend then
        return false, self:backend_not_started_error()
    end

    local platform = self:detect_platform()
    -- The managed backend always keeps its state under KOReader's settings.
    local set_home = nil
    local write_pid = false
    local log_path = nil
    if backend == self:standalone_backend() or tostring(backend):find(self:bundled_backend_dir(), 1, true) == 1 then
        if backend ~= self:standalone_backend() and not self:is_pocketbook() then
            local _, prep_err = self:ensure_backend_files()
            if prep_err then
                return false, prep_err
            end
            backend = self:standalone_backend()
        end
        write_pid = true
        set_home = self:state_home()
        log_path = self:state_home() .. "/ZenPM.log"
    elseif platform == "kobo" then
        log_path = "/mnt/onboard/.adds/ZenPM/ZenPM.log"
    elseif platform == "kindle" then
        log_path = "/mnt/us/ZenPM/ZenPM.log"
    else
        log_path = "/tmp/ZenPM.log"
    end

    local env = "ZENPM_PLATFORM=" .. Util.sh_quote(platform)
        .. " ZENPM_KOREADER_DIR=" .. Util.sh_quote(self:koreader_data_dir())
        .. " ZENPM_KOREADER_PLUGIN_DIR=" .. Util.sh_quote(self:koreader_plugin_dir())
        .. " ZENPM_KOREADER_PATCH_DIR=" .. Util.sh_quote(self:koreader_patch_dir())
    if set_home then
        env = env .. " ZENPM_HOME=" .. Util.sh_quote(set_home)
    end
    self:log_cli("starting backend " .. backend
        .. " platform=" .. platform
        .. " abi=" .. self:ereader_backend_suffix())
    local serve_args = " serve --socket " .. Util.sh_quote(self:unix_socket_path())
    -- Some Android e-reader shells do not provide nohup. Ignore SIGHUP with
    -- POSIX shell built-ins instead, while keeping the daemon detached from
    -- KOReader's stdout/stderr.
    local cmd = "( trap '' HUP; " .. env
        .. " exec " .. Util.sh_quote(backend)
        .. serve_args .. " >>" .. Util.sh_quote(log_path)
        .. " 2>&1 ) &"
    if write_pid then
        cmd = cmd .. " echo $! >" .. Util.sh_quote(self:standalone_pid_file())
    end

    os.execute(cmd)
    return true
end

function Daemon:request_android_update()
    if not self:is_android() or type(android.openLink) ~= "function" then
        return false, _("ZenPM Android companion is not available.")
    end
    local status_path = self:state_home() .. "/android-companion-update.status"
    os.remove(status_path)
    local companion_log = self:state_home() .. "/android-companion.log"
    append_text(companion_log, log_timestamp() .. "  KOReader requesting ZenPM companion update.\n")
    local called, opened = pcall(android.openLink, "zenpm://update?home=" .. uri_escape(self:state_home()))
    append_text(companion_log, log_timestamp() .. "  ZenPM companion update link result: called="
        .. tostring(called) .. " opened=" .. tostring(opened) .. "\n")
    if called and opened then
        for _ = 1, 10 do
            local state, detail = read_all(status_path):match("^([^\n]*)\n?([^\n]*)")
            if state == "failed" then
                return false, detail ~= "" and detail or _("ZenPM companion update failed.")
            end
            if state ~= "" then
                break
            end
            socket.sleep(0.1)
        end
        return true
    end
    return false, _("ZenPM Android companion could not start its updater.")
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

    return false, _(Constants.DAEMON_UNAVAILABLE_MESSAGE)
end

return Daemon
