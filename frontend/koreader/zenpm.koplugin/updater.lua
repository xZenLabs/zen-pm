local Archiver = require("ffi/archiver")
local JSON = require("json")
local socket = require("socket")
local _ = require("gettext")

local Constants = require("constants")
local Util = require("zenpm_util")

local Updater = {}

local ok_logger, logger = pcall(require, "logger")
local ok_socketutil, socketutil = pcall(require, "socketutil")

local function log_info(...)
    if ok_logger and logger and logger.info then
        logger.info("ZenPM updater:", ...)
    end
end

local function log_warn(...)
    if ok_logger and logger and logger.warn then
        logger.warn("ZenPM updater:", ...)
    end
end

local function standalone_log(daemon, message)
    log_info("Kindle standalone:", message)
    if not daemon or type(daemon.state_home) ~= "function" then return end
    local ok, home = pcall(daemon.state_home, daemon)
    if not ok or type(home) ~= "string" or home == "" then return end
    local file = io.open(home .. "/ZenPM.log", "a")
    if not file then return end
    file:write(os.date("!%Y-%m-%dT%H:%M:%SZ"), "  Kindle standalone: ", message, "\n")
    file:close()
end

local function standalone_failure(daemon, message)
    standalone_log(daemon, "failed: " .. message)
    return false, message
end

local REPOSITORY = "xZenLabs/zen-pm"
local RELEASES_URL = "https://api.github.com/repos/" .. REPOSITORY .. "/releases?per_page=100"
local RELEASE_ROOT = "zenpm.koplugin"
local STANDALONE_ROOT = "ZenPM"
local STANDALONE_SCRIPT = "documents/ZenPM.sh"

local trusted_download_hosts = {
    ["github.com"] = true,
    ["objects.githubusercontent.com"] = true,
    ["release-assets.githubusercontent.com"] = true,
    ["github-releases.githubusercontent.com"] = true,
}

local function path_exists(path)
    return Util.path_exists(path)
end

local function is_dir(path)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local attrs = ok_lfs and lfs.attributes(path)
    return attrs and attrs.mode == "directory"
end

local function remove_tree(path)
    os.execute("rm -rf " .. Util.sh_quote(path))
end

local function copy_file(source, destination)
    local input, input_err = io.open(source, "rb")
    if not input then return false, tostring(input_err) end
    local output, open_err = io.open(destination, "wb")
    if not output then
        input:close()
        return false, tostring(open_err)
    end
    while true do
        local chunk = input:read(8192)
        if not chunk then break end
        local written, write_err = output:write(chunk)
        if not written then
            input:close()
            output:close()
            return false, tostring(write_err)
        end
    end
    input:close()
    local closed, close_err = output:close()
    if not closed then return false, tostring(close_err) end
    return true
end

local function semver_parts(version)
    local value = (tostring(version or ""):match("^v?(.+)$") or "")
    local base = value:match("^([%d%.]+)") or ""
    local prerelease = value:match("^[%d%.]+[-+](.+)$") or ""
    local major, minor, patch = base:match("^(%d+)%.(%d+)%.?(%d*)$")
    return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0,
        prerelease ~= "", tonumber(prerelease:match("(%d+)$")) or 0
end

local function version_gt(left, right)
    local left_major, left_minor, left_patch, left_prerelease, left_prerelease_number = semver_parts(left)
    local right_major, right_minor, right_patch, right_prerelease, right_prerelease_number = semver_parts(right)
    if left_major ~= right_major then return left_major > right_major end
    if left_minor ~= right_minor then return left_minor > right_minor end
    if left_patch ~= right_patch then return left_patch > right_patch end
    if left_prerelease ~= right_prerelease then return not left_prerelease end
    return left_prerelease and left_prerelease_number > right_prerelease_number
end

local function semver_base(version)
    local major, minor, patch = semver_parts(version)
    return string.format("%d.%d.%d", major, minor, patch)
end

local function release_asset_name(daemon, version)
    if daemon:is_android() then
        return "ZenPM-koreader-android-" .. version .. ".zip"
    end
    local platform = daemon:detect_platform()
    if platform == "kindle" or platform == "kobo" or platform == "ereader" then
        if platform == "kobo" and daemon:ereader_backend_suffix() == "arm64" then
            return "ZenPM-koreader-linux-" .. version .. ".zip"
        end
        return "ZenPM-koreader-ereader-" .. version .. ".zip"
    end

    local host_platform = daemon:host_backend_platform()
    if host_platform == "darwin" then
        return "ZenPM-koreader-macos-" .. version .. ".zip"
    elseif host_platform == "linux" then
        return "ZenPM-koreader-linux-" .. version .. ".zip"
    end
end

local function valid_download_url(url)
    local scheme, host, path = tostring(url or ""):match("^(https?)://([^/%?#]+)([^#]*)$")
    if scheme ~= "https" or not trusted_download_hosts[host and host:lower()] then return false end
    if host:lower() ~= "github.com" then return true end
    local release_prefix = "/" .. REPOSITORY .. "/releases/download/"
    return path:sub(1, #release_prefix) == release_prefix
end

local function valid_digest(digest)
    local value = type(digest) == "string" and digest:match("^sha256:([0-9a-fA-F]+)$")
    return value ~= nil and #value == 64
end

local function sha256(path)
    local ok_sha, sha2 = pcall(require, "ffi/sha2")
    if not ok_sha or not sha2 or not sha2.sha256 then return nil end

    local file = io.open(path, "rb")
    if not file then return nil end
    local append = sha2.sha256()
    while true do
        local chunk = file:read(64 * 1024)
        if not chunk then break end
        append(chunk)
    end
    file:close()
    local ok, digest = pcall(append)
    return ok and type(digest) == "string" and digest:lower() or nil
end

local function request(url, sink, method)
    local ok_https, https = pcall(require, "ssl.https")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    if not ok_https or not ok_ltn12 then
        return nil, _("Could not connect to GitHub: HTTPS support is unavailable in this KOReader build.")
    end
    local response = {}
    local started_at = socket.gettime()
    log_info("GitHub request started", method or "GET", url)
    if ok_socketutil then
        socketutil:set_timeout(10, 30)
    end
    local ok, code, headers, status = https.request{
        url = url,
        method = method,
        headers = { ["User-Agent"] = "zenpm.koplugin" },
        sink = sink or ltn12.sink.table(response),
    }
    if ok_socketutil then
        socketutil:reset_timeout()
    end
    local elapsed_ms = math.floor((socket.gettime() - started_at) * 1000)
    if not ok or not tonumber(code) then
        local err = _("Could not connect to GitHub: ") .. tostring(code or status or _("request failed"))
        log_warn("GitHub request failed after", elapsed_ms .. "ms", err)
        return nil, err
    end
    log_info("GitHub request completed", method or "GET", "HTTP", code, "after", elapsed_ms .. "ms")
    return {
        code = tonumber(code),
        headers = headers,
        body = table.concat(response),
        status = status,
    }
end

local function resolve_redirect(base_url, location)
    if type(location) ~= "string" or location == "" then return nil end
    if location:match("^https?://") then return location end
    local scheme, host, path = base_url:match("^(https?)://([^/%?#]+)([^#]*)$")
    if not scheme or not host then return nil end
    if location:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. location
    end
    local dir = (path or "/"):match("^(.*)/") or "/"
    return scheme .. "://" .. host .. dir .. "/" .. location
end

local function resolved_download_url(url)
    local resolved = url
    for _ = 1, 5 do
        if not valid_download_url(resolved) then
            log_warn("download URL failed trust validation")
            return nil, _("GitHub supplied an untrusted download URL.")
        end
        local response, err = request(resolved, nil, "HEAD")
        if not response then
            log_warn("download URL probe failed", err)
            return nil, err
        end
        if response.code ~= 301 and response.code ~= 302 and response.code ~= 307 and response.code ~= 308 then
            if response.code ~= 200 then
                log_warn("download URL probe returned HTTP", response.code or response.status or "?")
                return nil, _("GitHub download returned HTTP ") .. tostring(response.code or "?")
            end
            return resolved
        end
        resolved = resolve_redirect(resolved, response.headers and response.headers.location)
        if not resolved then
            log_warn("download URL redirect was invalid")
            return nil, _("GitHub supplied an invalid download redirect.")
        end
    end
    log_warn("download URL exceeded redirect limit")
    return nil, _("GitHub download redirected too many times.")
end

local function find_asset(release, daemon)
    local version = tostring(release.tag_name or ""):gsub("^v", "")
    local asset_name = release_asset_name(daemon, version)
    if version == "" or not asset_name then
        log_warn("cannot determine release asset", "tag=", release.tag_name, "platform=", daemon:detect_platform())
        return nil
    end
    for _, asset in ipairs(release.assets or {}) do
        if asset.name == asset_name
            and valid_download_url(asset.browser_download_url)
            and valid_digest(asset.digest) then
            return {
                version = version,
                tag = release.tag_name,
                prerelease = release.prerelease == true,
                published_at = release.published_at or release.created_at or "",
                asset = asset,
            }
        end
    end
    log_warn("release asset not found", "tag=", release.tag_name, "expected=", asset_name)
end

local function find_standalone_asset(release)
    local version = tostring(release.tag_name or ""):gsub("^v", "")
    if version == "" then return nil end
    local asset_name = "ZenPM-kindle-standalone-" .. version .. ".zip"
    for _, asset in ipairs(release.assets or {}) do
        if asset.name == asset_name
            and valid_download_url(asset.browser_download_url)
            and valid_digest(asset.digest) then
            return {
                version = version,
                tag = release.tag_name,
                prerelease = release.prerelease == true,
                published_at = release.published_at or release.created_at or "",
                asset = asset,
            }
        end
    end
end

local function select_release(releases, daemon, allow_prerelease)
    local entries = {}
    for index, release in ipairs(releases) do
        local entry = find_asset(release, daemon)
        if entry then
            entry.index = index
            table.insert(entries, entry)
        end
    end
    table.sort(entries, function(left, right)
        if left.published_at ~= right.published_at then return left.published_at > right.published_at end
        return left.index < right.index
    end)
    if not allow_prerelease then
        for _, entry in ipairs(entries) do
            if not entry.prerelease then return entry end
        end
        return nil, release_asset_name(daemon, tostring(releases[1] and releases[1].tag_name or ""):gsub("^v", ""))
    end

    local selected_by_base = {}
    local selected = {}
    for _, entry in ipairs(entries) do
        local base = semver_base(entry.tag)
        local index = selected_by_base[base]
        if not index then
            selected_by_base[base] = #selected + 1
            table.insert(selected, entry)
        elseif selected[index].prerelease and not entry.prerelease then
            selected[index] = entry
        end
    end
    return selected[1], release_asset_name(daemon, tostring(releases[1] and releases[1].tag_name or ""):gsub("^v", ""))
end

local function select_standalone_release(releases, allow_prerelease)
    local entries = {}
    for index, release in ipairs(releases) do
        local entry = find_standalone_asset(release)
        if entry then
            entry.index = index
            table.insert(entries, entry)
        end
    end
    table.sort(entries, function(left, right)
        if left.published_at ~= right.published_at then return left.published_at > right.published_at end
        return left.index < right.index
    end)
    for _, entry in ipairs(entries) do
        if allow_prerelease or not entry.prerelease then return entry end
    end
    return nil
end

local function fetch_releases(force_refresh)
    local url = RELEASES_URL
    if force_refresh then url = url .. "&cache_bust=" .. tostring(os.time()) end
    local response, err = request(url)
    if not response then
        log_warn("release request failed", err)
        return nil, err
    end
    if response.code ~= 200 then
        log_warn("release request returned HTTP", response.code or response.status or "?")
        return nil, "GitHub returned HTTP " .. tostring(response.code or response.status or "?")
    end
    local ok, releases = pcall(JSON.decode, response.body)
    if not ok or type(releases) ~= "table" or #releases == 0 then
        log_warn("release response could not be decoded")
        return nil, "Could not read GitHub release information."
    end
    log_info("fetched releases", #releases)
    return releases
end

local function download(url, path, digest)
    local resolved, resolve_err = resolved_download_url(url)
    if not resolved then
        return false, resolve_err
    end
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    if not ok_ltn12 then
        log_warn("download support is unavailable")
        return false, "Download support is unavailable in this KOReader build."
    end
    local file, err = io.open(path, "wb")
    if not file then
        log_warn("could not create update archive", err)
        return false, tostring(err)
    end
    log_info("downloading update archive")
    local response, request_err = request(resolved, ltn12.sink.file(file))
    pcall(file.close, file)
    if not response or response.code ~= 200 then
        os.remove(path)
        log_warn("update download failed", request_err or (response and response.code) or "?")
        return false, request_err or "Download failed with HTTP " .. tostring(response and response.code or "?")
    end
    if valid_digest(digest) then
        local actual = sha256(path)
        local expected = digest:sub(#"sha256:" + 1):lower()
        if not actual then
            os.remove(path)
            log_warn("update checksum could not be calculated")
            return false, "Could not verify the update download."
        end
        if actual ~= expected then
            os.remove(path)
            log_warn("update checksum did not match")
            return false, "Downloaded update checksum did not match."
        end
    end
    log_info("update archive downloaded and verified")
    return true
end

local function unsafe_entry(path)
    if path == "" or path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" then return true end
    for part in path:gmatch("[^/\\]+") do
        if part == ".." then return true end
    end
    return false
end

local function extract(zip_path, stage_dir)
    local archive = Archiver.Reader:new()
    if not archive:open(zip_path) then
        return false, archive.err or "Could not open update archive."
    end

    local entries = 0
    for entry in archive:iterate() do
        if unsafe_entry(entry.path)
            or (entry.mode ~= "file" and entry.mode ~= "directory")
            or (entry.path ~= RELEASE_ROOT and entry.path:sub(1, #RELEASE_ROOT + 1) ~= RELEASE_ROOT .. "/") then
            archive:close()
            return false, "Update archive has an invalid layout."
        end
        if not archive:extractToPath(entry.path, stage_dir .. "/" .. entry.path) then
            local err = archive.err or "Could not unpack update archive."
            archive:close()
            return false, err
        end
        entries = entries + 1
    end
    local err = archive.err
    archive:close()
    if err or entries == 0 then return false, err or "Update archive is empty." end
    if not is_dir(stage_dir .. "/" .. RELEASE_ROOT)
        or not path_exists(stage_dir .. "/" .. RELEASE_ROOT .. "/_meta.lua")
        or not path_exists(stage_dir .. "/" .. RELEASE_ROOT .. "/main.lua") then
        return false, "Update archive does not contain a ZenPM plugin."
    end
    return true
end

local function extract_standalone(zip_path, stage_dir)
    local archive = Archiver.Reader:new()
    if not archive:open(zip_path) then
        return false, archive.err or "Could not open standalone archive."
    end

    local entries = 0
    for entry in archive:iterate() do
        local path = entry.path
        local in_payload = path == STANDALONE_ROOT or path:sub(1, #STANDALONE_ROOT + 1) == STANDALONE_ROOT .. "/"
        local in_documents = path == "documents" or path:sub(1, 10) == "documents/"
        if unsafe_entry(path) or (entry.mode ~= "file" and entry.mode ~= "directory") or not (in_payload or in_documents) then
            archive:close()
            return false, "Standalone archive has an invalid layout."
        end
        if not archive:extractToPath(path, stage_dir .. "/" .. path) then
            local err = archive.err or "Could not unpack standalone archive."
            archive:close()
            return false, err
        end
        entries = entries + 1
    end
    local err = archive.err
    archive:close()
    if err or entries == 0 then return false, err or "Standalone archive is empty." end
    if not is_dir(stage_dir .. "/" .. STANDALONE_ROOT)
        or not path_exists(stage_dir .. "/" .. STANDALONE_ROOT .. "/frontend/kindle")
        or not path_exists(stage_dir .. "/" .. STANDALONE_ROOT .. "/backend/zenpm-hf")
        or not path_exists(stage_dir .. "/" .. STANDALONE_ROOT .. "/backend/zenpm-sf")
        or not path_exists(stage_dir .. "/" .. STANDALONE_SCRIPT) then
        return false, "Standalone archive does not contain a complete Kindle installation."
    end
    return true
end

local function latest_release(daemon, allow_prerelease, force_refresh)
    log_info("checking for updates", "platform=", daemon:detect_platform(), "prereleases=", allow_prerelease == true)
    local releases, err = fetch_releases(force_refresh)
    if not releases then return false, err end
    local release, expected_asset = select_release(releases, daemon, allow_prerelease)
    if not release then
        log_warn("no compatible release", "platform=", daemon:detect_platform(), "expected=", expected_asset)
        if expected_asset then
            return false, "No compatible ZenPM release is available for this platform (expected " .. expected_asset .. ")."
        end
        return false, "No compatible ZenPM release is available for this platform."
    end
    log_info("selected release", release.tag, "asset=", release.asset.name)
    return true, release
end

function Updater:check(daemon, allow_prerelease, force_refresh)
    local ok, release_or_err = latest_release(daemon, allow_prerelease, force_refresh)
    if not ok then return false, release_or_err end
    local release = release_or_err
    local plugin_version = daemon:plugin_version()
    local plugin_update = release and version_gt(release.tag, plugin_version)
    local companion_version = daemon:is_android() and daemon:android_companion_version() or nil
    local companion_update = release and companion_version and version_gt(release.tag, companion_version)
    log_info("version comparison", "release=", release and release.tag or "", "plugin=", plugin_version,
        "companion=", companion_version or "")
    if not plugin_update and not companion_update then
        log_info("already up to date", plugin_version, companion_version or "")
        return true, "up_to_date"
    end
    return true, release.version
end

function Updater:update(daemon, allow_prerelease, force_refresh)
    local ok, release_or_err = latest_release(daemon, allow_prerelease, force_refresh)
    if not ok then return false, release_or_err end
    local release = release_or_err
    if not release or not version_gt(release.tag, daemon:plugin_version()) then
        return true, "up_to_date"
    end

    local plugin_dir = Constants.PLUGIN_DIR
    local plugins_dir = plugin_dir:match("^(.*)/[^/]+$")
    local plugin_name = plugin_dir:match("([^/]+)$")
    if not plugins_dir or not plugin_name or not is_dir(plugin_dir) then
        log_warn("installed plugin directory could not be found")
        return false, "Could not find the installed ZenPM plugin directory."
    end
    local probe = plugins_dir .. "/.zenpm-update-write-probe"
    local probe_file = io.open(probe, "wb")
    if not probe_file then
        log_warn("plugins directory is not writable")
        return false, "KOReader's plugins directory is not writable."
    end
    probe_file:close()
    os.remove(probe)

    local zip_path = plugins_dir .. "/.zenpm-update.zip"
    local stage_dir = plugins_dir .. "/.zenpm-update-stage"
    local staged_plugin = stage_dir .. "/" .. RELEASE_ROOT
    local backup_dir = plugins_dir .. "/." .. plugin_name .. ".backup"
    remove_tree(stage_dir)
    remove_tree(backup_dir)
    os.remove(zip_path)

    local downloaded, download_err = download(release.asset.browser_download_url, zip_path, release.asset.digest)
    if not downloaded then return false, download_err end
    if not Util.ensure_dir(stage_dir) then
        os.remove(zip_path)
        log_warn("could not create update staging directory")
        return false, "Could not prepare the update directory."
    end
    local unpacked, unpack_err = extract(zip_path, stage_dir)
    os.remove(zip_path)
    if not unpacked then
        remove_tree(stage_dir)
        log_warn("could not extract update archive", unpack_err)
        return false, unpack_err
    end

    if not os.rename(plugin_dir, backup_dir) then
        remove_tree(stage_dir)
        log_warn("could not back up installed plugin")
        return false, "Could not move the old ZenPM plugin."
    end
    if not os.rename(staged_plugin, plugin_dir) then
        os.rename(backup_dir, plugin_dir)
        remove_tree(stage_dir)
        log_warn("could not install staged plugin; restored previous version")
        return false, "Could not install the updated ZenPM plugin."
    end
    remove_tree(stage_dir)
    remove_tree(backup_dir)
    log_info("update installed", release.version)
    return true, release.version
end

function Updater:install_kindle_standalone(daemon, allow_prerelease, force_refresh)
    local releases, releases_err = fetch_releases(force_refresh)
    if not releases then return standalone_failure(daemon, releases_err) end
    local release = select_standalone_release(releases, allow_prerelease)
    if not release then
        return standalone_failure(daemon, "No standalone Kindle ZenPM release is available.")
    end
    standalone_log(daemon, "selected " .. release.asset.name .. " (" .. release.tag .. ")")

    local usb_root = "/mnt/us"
    local work_dir = usb_root .. "/.ZenPM"
    local zip_path = work_dir .. "/" .. release.asset.name
    local stage_dir = work_dir .. "/.zenpm-standalone-stage"
    local payload_backup = work_dir .. "/.zenpm-standalone-backup"
    local script_backup = work_dir .. "/.zenpm-standalone-script-backup"
    local payload_path = usb_root .. "/" .. STANDALONE_ROOT
    local script_path = usb_root .. "/" .. STANDALONE_SCRIPT

    if not Util.ensure_dir(work_dir) then
        return standalone_failure(daemon, "Could not prepare the Kindle USB storage.")
    end
    remove_tree(stage_dir)
    remove_tree(payload_backup)
    os.remove(script_backup)
    os.remove(zip_path)

    standalone_log(daemon, "downloading " .. release.asset.name)
    local downloaded, download_err = download(release.asset.browser_download_url, zip_path, release.asset.digest)
    if not downloaded then return standalone_failure(daemon, download_err) end
    if not Util.ensure_dir(stage_dir) then
        os.remove(zip_path)
        return standalone_failure(daemon, "Could not prepare the standalone installation directory.")
    end
    local unpacked, unpack_err = extract_standalone(zip_path, stage_dir)
    os.remove(zip_path)
    if not unpacked then
        remove_tree(stage_dir)
        return standalone_failure(daemon, unpack_err)
    end
    standalone_log(daemon, "archive verified and extracted")

    if path_exists(payload_path) then
        local moved, move_err = os.rename(payload_path, payload_backup)
        if not moved then
            remove_tree(stage_dir)
            return standalone_failure(daemon, "Could not back up the existing standalone ZenPM installation: " .. tostring(move_err))
        end
    end
    if path_exists(script_path) then
        local moved, move_err = os.rename(script_path, script_backup)
        if not moved then
            os.rename(payload_backup, payload_path)
            remove_tree(stage_dir)
            return standalone_failure(daemon, "Could not back up the existing Kindle homepage script: " .. tostring(move_err))
        end
    end
    local payload_moved, payload_move_err = os.rename(stage_dir .. "/" .. STANDALONE_ROOT, payload_path)
    if not payload_moved then
        os.rename(script_backup, script_path)
        os.rename(payload_backup, payload_path)
        remove_tree(stage_dir)
        return standalone_failure(daemon, "Could not install the standalone ZenPM payload: " .. tostring(payload_move_err))
    end
    local staged_script = stage_dir .. "/" .. STANDALONE_SCRIPT
    local script_moved, script_move_err = os.rename(staged_script, script_path)
    local script_copied, script_copy_err = false, nil
    if not script_moved then
        script_copied, script_copy_err = copy_file(staged_script, script_path)
    end
    if not script_moved and not script_copied then
        remove_tree(payload_path)
        os.rename(script_backup, script_path)
        os.rename(payload_backup, payload_path)
        remove_tree(stage_dir)
        return standalone_failure(daemon, "Could not install the Kindle homepage script: rename failed: "
            .. tostring(script_move_err) .. "; copy failed: " .. tostring(script_copy_err))
    end
    os.execute("chmod +x " .. Util.sh_quote(script_path))
    remove_tree(stage_dir)

    standalone_log(daemon, "configuring Kindle standalone installation")
    local installer_log = daemon and daemon:state_home() .. "/ZenPM.log" or "/tmp/ZenPM-standalone.log"
    if os.execute("ZENPM_NO_LAUNCH=1 sh " .. Util.sh_quote(script_path) .. " >>" .. Util.sh_quote(installer_log) .. " 2>&1") ~= 0 then
        return standalone_failure(daemon, "The standalone payload was installed, but its Kindle setup script failed. See " .. installer_log .. " or run " .. script_path .. " from KUAL to retry.")
    end

    remove_tree(payload_backup)
    os.remove(script_backup)
    standalone_log(daemon, "installed v" .. release.version)
    return true, release.version
end

return Updater
