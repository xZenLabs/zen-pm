local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local releases = {
    {
        tag_name = "v1.0.1-beta1",
        prerelease = true,
        published_at = "2026-07-24T10:00:00Z",
        assets = {
            {
                name = "ZenPM-koreader-linux-1.0.1-beta1.zip",
                browser_download_url = "https://github.com/xZenLabs/zen-pm/releases/download/v1.0.1-beta1/ZenPM-koreader-linux-1.0.1-beta1.zip",
                digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            },
        },
    },
    {
        tag_name = "v1.0.0",
        prerelease = false,
        published_at = "2026-07-23T10:00:00Z",
        assets = {
            {
                name = "ZenPM-koreader-linux-1.0.0.zip",
                browser_download_url = "https://github.com/xZenLabs/zen-pm/releases/download/v1.0.0/ZenPM-koreader-linux-1.0.0.zip",
                digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            },
        },
    },
}

local requested_url

package.preload["ffi/archiver"] = function() return {} end
package.preload["json"] = function() return { decode = function() return releases end } end
package.preload["socket"] = function() return { gettime = function() return 0 end } end
-- Some KOReader builds expose socketutil without the timeout helpers.
package.preload["socketutil"] = function() return {} end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["zenpm_constants"] = function() return {} end
package.preload["zenpm_util"] = function() return { path_exists = function() return false end } end
package.preload["ssl.https"] = function()
    return {
        request = function(options)
            requested_url = options.url
            options.sink("[]")
            return 1, 200, {}, "OK"
        end,
    }
end
package.preload["ltn12"] = function()
    return { sink = { table = function(target) return function(chunk) table.insert(target, chunk) end end } }
end

local Updater = require("updater")
local daemon = {
    detect_platform = function() return "desktop" end,
    host_backend_platform = function() return "linux" end,
    is_android = function() return false end,
    plugin_version = function() return "1.0.0" end,
}

local ok, version = Updater:check(daemon, true, true)
assert(ok and version == "1.0.1-beta1")
assert(requested_url:match("&cache_bust=%d+$"))

ok, version = Updater:check(daemon, false)
assert(ok and version == "up_to_date")
assert(not requested_url:find("cache_bust", 1, true))

local ereader_daemon = {
    detect_platform = function() return "ereader" end,
    host_backend_platform = function() return "linux" end,
    is_android = function() return false end,
    plugin_version = function() return "1.0.0" end,
}

ok, version = Updater:check(ereader_daemon, true)
assert(not ok)
assert(version:find("expected ZenPM%-koreader%-ereader%-1%.0%.1%-beta1%.zip"))

local standalone_ok, standalone_err = Updater:install_kindle_standalone({
    kindle_homepage_install_supported = function() return false end,
}, false, true)
assert(not standalone_ok)
assert(standalone_err == "Kindle standalone is not supported on this device.")

print("updater tests passed")
