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

print("models tests passed")
