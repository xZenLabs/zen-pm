local Constants = require("constants")
local Util = require("zenpm_util")
local sha256 = require("ffi/sha2").sha256
local ok_datastorage, DataStorage = pcall(require, "datastorage")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

local CACHE_MAX_BYTES = 32 * 1024 * 1024
local CACHE_MAX_FILES = 256
local CACHE_FILE_PREFIX = "image-"
local CACHE_REF_PREFIX = "url-"

local Images = {
    cached = {},
    failed = {},
    refresh_required = false,
}

local function platform_cache_dir(platform)
    if platform == "kobo" then
        return "/mnt/onboard/.adds/ZenPM/cache/koreader-images"
    elseif platform == "kindle" then
        return "/mnt/us/ZenPM/cache/koreader-images"
    end
    if ok_datastorage and DataStorage and DataStorage.getSettingsDir then
        return DataStorage:getSettingsDir() .. "/ZenPM/cache/koreader-images"
    end
    return "/tmp/zenpm-koreader-images"
end

local function is_remote(value)
    return tostring(value or ""):match("^https?://") ~= nil
end

local function cache_key(value)
    return sha256(tostring(value or ""))
end

local function cache_ref_path(dir, url_key)
    return dir .. "/" .. CACHE_REF_PREFIX .. url_key .. ".ref"
end

local function cache_filename(url_key, content_key, extension)
    return CACHE_FILE_PREFIX .. url_key .. "-" .. content_key .. extension
end

local function valid_cache_filename(name, url_key)
    local file_url_key, content_key, extension = tostring(name or ""):match(
        "^image%-(%x+)%-(%x+)%.([%w]+)$"
    )
    return file_url_key == url_key
        and #file_url_key == 64
        and #content_key == 64
        and (extension == "svg" or extension == "png" or extension == "gif"
            or extension == "jpg" or extension == "jpeg")
end

local function read_ref(dir, url_key)
    local f = io.open(cache_ref_path(dir, url_key), "r")
    if not f then
        return nil
    end
    local name = f:read("*l")
    f:close()
    if not valid_cache_filename(name, url_key) then
        return nil
    end
    return name
end

local function write_atomic(path, data)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then
        return false
    end
    local written = f:write(data)
    local closed = f:close()
    if not written or not closed or not os.rename(tmp, path) then
        os.remove(tmp)
        return false
    end
    return true
end

local function prune_cache(dir, keep_path)
    if not ok_lfs then
        return
    end
    local ok, iterator, directory = pcall(lfs.dir, dir)
    if not ok then
        return
    end

    local files = {}
    local total_size = 0
    for name in iterator, directory do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local url_key, content_key = name:match("^image%-(%x+)%-(%x+)%.")
            local legacy = name:match("^%x%x%x%x%x%x%x%x%.(svg|png|gif|jpg|jpeg)$")
            if name:match("%.tmp$") or legacy then
                os.remove(path)
            elseif url_key and #url_key == 64 and #content_key == 64 then
                local attrs = lfs.attributes(path)
                if attrs and attrs.mode == "file" then
                    local size = tonumber(attrs.size) or 0
                    table.insert(files, {
                        name = name,
                        path = path,
                        url_key = url_key,
                        size = size,
                        modified = tonumber(attrs.modification) or 0,
                    })
                    total_size = total_size + size
                end
            end
        end
    end

    table.sort(files, function(a, b)
        if a.modified == b.modified then
            return a.name < b.name
        end
        return a.modified < b.modified
    end)
    local count = #files
    for _, file in ipairs(files) do
        if count <= CACHE_MAX_FILES and total_size <= CACHE_MAX_BYTES then
            break
        end
        if file.path ~= keep_path then
            os.remove(file.path)
            if read_ref(dir, file.url_key) == file.name then
                os.remove(cache_ref_path(dir, file.url_key))
            end
            count = count - 1
            total_size = total_size - file.size
        end
    end
end

local function persistent_file(dir, value)
    local url_key = cache_key(value)
    local name = read_ref(dir, url_key)
    if not name then
        return nil
    end
    local path = dir .. "/" .. name
    if not Util.path_exists(path) then
        os.remove(cache_ref_path(dir, url_key))
        return nil
    end
    if ok_lfs and lfs.touch then
        pcall(lfs.touch, path)
    end
    Images.cached[value] = path
    return path
end

local function extension_from(url, headers)
    local content_type = ""
    headers = headers or {}
    for k, v in pairs(headers) do
        if tostring(k):lower() == "content-type" then
            content_type = tostring(v):lower()
        end
    end
    if content_type:find("svg", 1, true) then return ".svg" end
    if content_type:find("png", 1, true) then return ".png" end
    if content_type:find("jpeg", 1, true) or content_type:find("jpg", 1, true) then return ".jpg" end
    if content_type:find("gif", 1, true) then return ".gif" end

    local path = tostring(url or ""):match("^[^%?#]+") or ""
    local ext = path:match("%.([%w]+)$")
    ext = ext and ext:lower() or ""
    if ext == "svg" or ext == "png" or ext == "gif" or ext == "jpg" or ext == "jpeg" then
        return "." .. ext
    end
    return ".png"
end

function Images.asset(name)
    return Constants.ASSET_DIR .. "/" .. name
end

local function is_favicon(value)
    value = tostring(value or ""):lower()
    return value:find("favicon", 1, true) ~= nil or value:match("%.ico[%?%#]?$") ~= nil
end

local function normalize_category(value)
    value = tostring(value or ""):lower()
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("[%s_%-]+", "")
    if value == "game" then
        return "games"
    end
    if value == "tools" or value == "tool" or value == "utilities" then
        return "utility"
    end
    if value == "patch" or value == "patches"
            or value == "koreaderpatch" or value == "koreaderpatches" then
        return "koreaderpatches"
    end
    return value
end

function Images.category_icon(category)
    local id = normalize_category(category and (category.id or category.category or category.label) or category)
    for _, item in ipairs(Constants.CATEGORIES or {}) do
        if normalize_category(item.id) == id or normalize_category(item.label) == id then
            return Images.asset(item.icon or "packages.svg")
        end
    end
    return nil
end

function Images.repo_icon(repo)
    if repo and repo.icon_url and repo.icon_url ~= "" and not is_favicon(repo.icon_url) then
        return repo.icon_url
    end
    if repo and repo.name == Constants.REPO_KINDLEFORGE_NAME then
        return Images.asset("kindleforge.svg")
    end
    if repo and repo.name == Constants.REPO_ZENLABS_NAME then
        return Images.asset("zen.svg")
    end
    if repo and repo.url and repo.url ~= "" then
        return repo.url:gsub("/+$", "") .. "/favicon.svg"
    end
    return Images.asset("sources.svg")
end

function Images.package_fallback(pkg)
    if pkg and pkg.repo_icon_url and pkg.repo_icon_url ~= "" and not is_favicon(pkg.repo_icon_url) then
        return pkg.repo_icon_url
    end
    if pkg and pkg.repo == Constants.REPO_KINDLEFORGE_NAME then
        return Images.asset("kindleforge.svg")
    end
    if pkg and pkg.repo == Constants.REPO_ZENLABS_NAME then
        return Images.asset("zen.svg")
    end
    if pkg and pkg.repo_icon_url and pkg.repo_icon_url ~= "" then
        return pkg.repo_icon_url
    end
    return Images.asset("packages.svg")
end

function Images.package_icon(pkg)
    if not pkg then
        return Images.asset("packages.svg")
    end
    if pkg.icon_url and pkg.icon_url ~= "" then return pkg.icon_url end
    if pkg.icon and pkg.icon ~= "" then return pkg.icon end
    if pkg.image_url and pkg.image_url ~= "" then return pkg.image_url end
    if type(pkg.images) == "table" and pkg.images[1] then return pkg.images[1] end
    if pkg.image and pkg.image ~= "" then return pkg.image end
    local category_icon = Images.category_icon(pkg.category)
    if category_icon then return category_icon end
    return Images.package_fallback(pkg)
end

function Images.featured_image(pkg)
    if not pkg then
        return Images.asset("packages.svg")
    end
    if pkg.featured_image and pkg.featured_image ~= "" then return pkg.featured_image end
    return Images.package_icon(pkg)
end

function Images.file_for(client, platform, value)
    value = tostring(value or "")
    if value == "" then
        return nil
    end
    if value:match("^file://") then
        return value:gsub("^file://", "")
    end
    if not is_remote(value) then
        return value
    end
    if Images.cached[value] and Util.path_exists(Images.cached[value]) then
        return Images.cached[value]
    end
    if Images.failed[value] or not client then
        return nil
    end

    local dir = platform_cache_dir(platform)
    if not Images.refresh_required then
        local file = persistent_file(dir, value)
        if file then
            return file
        end
    end

    local ok, data, _, headers = client:download(value)
    if not ok or type(data) ~= "string" or data == "" then
        Images.failed[value] = true
        return nil
    end
    if #data > CACHE_MAX_BYTES then
        Images.failed[value] = true
        return nil
    end

    if not Util.ensure_dir(dir) then
        Images.failed[value] = true
        return nil
    end

    local url_key = cache_key(value)
    local old_name = read_ref(dir, url_key)
    local name = cache_filename(url_key, cache_key(data), extension_from(value, headers))
    local path = dir .. "/" .. name
    if not Util.path_exists(path) and not write_atomic(path, data) then
        Images.failed[value] = true
        return nil
    end
    if old_name ~= name and not write_atomic(cache_ref_path(dir, url_key), name .. "\n") then
        os.remove(path)
        Images.failed[value] = true
        return nil
    end
    if old_name and old_name ~= name then
        os.remove(dir .. "/" .. old_name)
    end
    Images.cached[value] = path
    prune_cache(dir, path)
    return path
end

function Images.cached_file(platform, value)
    if value == nil then
        value = platform
        platform = nil
    end
    value = tostring(value or "")
    if value == "" then
        return nil
    end
    if value:match("^file://") then
        return value:gsub("^file://", "")
    end
    if not is_remote(value) then
        return value
    end
    if Images.cached[value] and Util.path_exists(Images.cached[value]) then
        return Images.cached[value]
    end
    if not Images.refresh_required and platform then
        return persistent_file(platform_cache_dir(platform), value)
    end
    return nil
end

function Images.invalidate_cache()
    Images.cached = {}
    Images.failed = {}
    Images.refresh_required = true
end

function Images.is_failed(value)
    return Images.failed[tostring(value or "")] == true
end

return Images
