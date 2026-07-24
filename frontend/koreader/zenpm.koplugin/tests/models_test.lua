local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

package.preload["constants"] = function()
    return { REPO_ZENLABS_NAME = "ZenLabs", REPO_ZENLABS_DISPLAY = "ZenLabs", REPO_KINDLEFORGE_NAME = "KindleForge" }
end
package.preload["i18n"] = function()
    return {
        dynamic = function(value) return value end,
        dynamic_or = function(value, fallback) return value or fallback end,
    }
end
package.preload["zenpm_util"] = function() return {} end
package.preload["gettext"] = function() return function(value) return value end end

local Models = require("models")
local repos = {
    { name = "ZenLabs", url = "https://zenlabs.example" },
    { name = "Alpha", url = "https://alpha.example" },
    { name = "Beta", url = "https://beta.example" },
}

local ascending = Models.sort_repos(repos, "name_asc")
assert(ascending[1].name == "Alpha" and ascending[2].name == "Beta" and ascending[3].name == "ZenLabs")
assert(repos[1].name == "ZenLabs")

local descending = Models.sort_repos(repos, "name_desc")
assert(descending[1].name == "ZenLabs" and descending[2].name == "Beta" and descending[3].name == "Alpha")

local installed = {
    { id = "first", name = "First", installed_at = "2026-07-21T10:00:00Z" },
    { id = "second", name = "Second", installed_at = "2026-07-22T10:00:00Z" },
    { id = "third", name = "Third", installed_at = "2026-07-23T10:00:00Z" },
}
local newest = Models.sort_packages(installed, "installed_at_desc")
assert(newest[1].id == "third" and newest[2].id == "second" and newest[3].id == "first")

local oldest = Models.sort_packages(installed, "installed_at_asc")
assert(oldest[1].id == "first" and oldest[2].id == "second" and oldest[3].id == "third")

local published = {
    { id = "first", name = "First", published_at = "2026-07-21T10:00:00Z" },
    { id = "second", name = "Second", published_at = "2026-07-22T10:00:00Z" },
    { id = "third", name = "Third", published_at = "2026-07-23T10:00:00Z" },
}
local recent = Models.sort_packages(published, "published_at_desc")
assert(recent[1].id == "third" and recent[2].id == "second" and recent[3].id == "first")

local patch = Models.installed_patch_item({
    id = "patch", installed_asset_dates = { ["patch.lua"] = "2026-07-23T10:00:00Z" },
}, "patch.lua")
assert(patch.installed_at == "2026-07-23T10:00:00Z")

print("models tests passed")
