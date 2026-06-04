local Constants = require("constants")
local Util = require("zenpm_util")

local Images = {
    cached = {},
    failed = {},
}

local function platform_cache_dir(platform)
    if platform == "kobo" then
        return "/mnt/onboard/.adds/ZenPM/cache/koreader-images"
    elseif platform == "kindle" then
        return "/mnt/us/ZenPM/cache/koreader-images"
    end
    return "/tmp/zenpm-koreader-images"
end

local function hash_url(value)
    local h = 5381
    value = tostring(value or "")
    for i = 1, #value do
        h = (h * 33 + value:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
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

function Images.repo_icon(repo)
    if repo and repo.name == Constants.REPO_KINDLEFORGE_NAME then
        return Images.asset("kindleforge.svg")
    end
    if repo and repo.name == Constants.REPO_ZENLABS_NAME then
        return Images.asset("zen.svg")
    end
    if repo and repo.icon_url and repo.icon_url ~= "" then
        return repo.icon_url
    end
    if repo and repo.url and repo.url ~= "" then
        return repo.url:gsub("/+$", "") .. "/favicon.svg"
    end
    return Images.asset("sources.svg")
end

function Images.package_fallback(pkg)
    if pkg and pkg.repo == Constants.REPO_KINDLEFORGE_NAME then
        return Images.asset("kindleforge.svg")
    end
    if pkg and pkg.repo == Constants.REPO_ZENLABS_NAME then
        return Images.asset("zen.svg")
    end
    return pkg and pkg.repo_icon_url and pkg.repo_icon_url ~= "" and pkg.repo_icon_url or Images.asset("packages.svg")
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
    if not value:match("^https?://") then
        return value
    end
    if Images.cached[value] and Util.path_exists(Images.cached[value]) then
        return Images.cached[value]
    end
    if Images.failed[value] or not client then
        return nil
    end

    local ok, data, _, headers = client:download(value)
    if not ok or type(data) ~= "string" or data == "" then
        Images.failed[value] = true
        return nil
    end

    local dir = platform_cache_dir(platform)
    if not Util.ensure_dir(dir) then
        Images.failed[value] = true
        return nil
    end

    local path = dir .. "/" .. hash_url(value) .. extension_from(value, headers)
    local f = io.open(path, "wb")
    if not f then
        Images.failed[value] = true
        return nil
    end
    f:write(data)
    f:close()
    Images.cached[value] = path
    return path
end

return Images
