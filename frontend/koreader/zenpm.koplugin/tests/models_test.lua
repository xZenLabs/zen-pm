local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

package.preload["zenpm_constants"] = function()
    return {
        PLUGIN_DIR = root,
        REPO_ZENLABS_NAME = "ZenLabs",
        REPO_ZENLABS_DISPLAY = "ZenLabs",
        REPO_KINDLEFORGE_NAME = "KindleForge",
        KINDLE_SCRIPTLETS_CATEGORY = {
            id = "kindle-scriptlets",
            label = "Kindle Scriptlets",
            icon = "kindleforge.svg",
        },
        CATEGORIES = {
            { id = "fonts", label = "Fonts" },
            { id = "games", label = "Games" },
            { id = "utility", label = "Utility" },
        },
    }
end
package.preload["i18n"] = function()
    return {
        dynamic = function(value) return value end,
        dynamic_or = function(value, fallback) return value or fallback end,
    }
end
package.preload["zenpm_util"] = function()
    return {
        trim = function(value)
            return tostring(value or ""):gsub("^%s*(.-)%s*$", "%1")
        end,
    }
end
package.preload["gettext"] = function() return function(value) return value end end

local Models = require("models")
assert(Models.package_action_label({ installed = true, update_available = true }) == "Update")
assert(Models.package_action_label({ installed = true }) == "Modify")
assert(Models.package_action_label({}) == "Get")
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

local discover_candidates = {
    { id = "old-installed", name = "Old installed", installed = true, update_available = true, published_at = "2026-07-25T11:59:59Z" },
    { id = "older-installed", name = "Older installed", installed = true, published_at = "2026-07-24T12:00:00Z" },
    { id = "new", name = "New", published_at = "2026-08-02T11:00:00Z" },
    { id = "new-installed", name = "New installed", installed = true, update_available = true, published_at = "2026-08-01T10:00:00Z" },
    { id = "recent-installed", name = "Recent installed", installed = true, published_at = "2026-08-02T10:00:00Z" },
    { id = "undated-update", name = "Undated update", installed = true, update_available = true },
    { id = "ignored", name = "Ignored", installed = true, update_available = true, update_ignored = true, published_at = "2026-08-02T11:30:00Z" },
    { id = "future", name = "Future", installed = true, update_available = true, published_at = "2026-08-03T10:00:00Z" },
    { id = "invalid", name = "Invalid", installed = true, update_available = true, published_at = "2026-07-99T10:00:00Z" },
    { id = "undated", name = "Undated" },
    { id = "edge", name = "Edge", installed = true, published_at = "2026-07-26T12:00:00Z" },
    { id = "outside", name = "Outside", installed = true, published_at = "2026-07-26T11:59:59Z" },
}
local discover = Models.sort_packages(discover_candidates, nil, "search", 1785672000)
assert(#discover == #discover_candidates)
for index, id in ipairs({ "recent-installed", "new-installed", "edge", "future" }) do
    assert(discover[index].id == id, "Discover priority: " .. id)
end
assert(discover_candidates[1].id == "old-installed")
local named_discover = Models.sort_packages(discover_candidates, "name", "search", 1785672000)
for index, id in ipairs({ "edge", "new-installed", "recent-installed", "future" }) do
    assert(named_discover[index].id == id, "Discover name priority: " .. id)
end
assert(Models.sort_packages(published, nil, "search", 1785672000)[1].id == "third")

local installed_candidates = {
    { id = "a", installed = true, installed_at = "2026-08-04", stars = 40 },
    { id = "b", installed = true, installed_at = "2026-08-03", stars = 30, update_available = true, update_ignored = true },
    { id = "c", installed = true, installed_at = "2026-08-02", stars = 20, update_available = true },
    { id = "d", installed = true, installed_at = "2026-08-01", stars = 10, update_available = true },
}
for sort_key, expected in pairs({
    name_asc = "cdab", name_desc = "dcba", installed_at_desc = "cdab", installed_at_asc = "dcba", stars = "cdab",
}) do
    local sorted = Models.sort_packages(installed_candidates, sort_key, "installed")
    local ids = {}
    for _, pkg in ipairs(sorted) do table.insert(ids, pkg.id) end
    assert(table.concat(ids) == expected, "Installed priority: " .. sort_key)
end
assert(Models.sort_packages(installed_candidates, "stars", "category")[1].id == "a")
assert(#Models.sort_packages({}, nil, "search", 1785672000) == 0)

assert(Models.friendly_published_at({ published_at = "2026-08-02T01:00:00Z" }, 1785672000) == "Today")
assert(Models.friendly_published_at({ published_at = "2026-08-01T23:00:00Z" }, 1785672000) == "Yesterday")
assert(Models.friendly_published_at({ published_at = "2026-07-30T12:00:00Z" }, 1785672000) == "3 days ago")
assert(Models.friendly_published_at({ published_at = "2026-07-99T12:00:00Z" }, 1785672000) == "")
assert(Models.friendly_published_at({ installed = true, update_available = true }, 1785672000) == "Update available")

local searchable = {
    { id = "title", name = "Title match", author = "Other", description = "No match" },
    { id = "author", name = "Other", author = "Author match", description = "No match" },
    { id = "description", name = "Other", author = "Other", description = "Description match" },
}
assert(#Models.filter_packages(searchable, "title match") == 1)
assert(#Models.filter_packages(searchable, "author match") == 1)
assert(#Models.filter_packages(searchable, "description match") == 0)

local categorized = {
    { id = "font", category = "fonts" },
    { id = "game", category = "other", tags = { "Games" } },
    { id = "utility", category = "utility" },
    { id = "scriptlet", category = "games", repo = "KindleForge" },
    { id = "zenlabs-scriptlet", category = "utility", repo = "ZenLabs", platforms = { "kindle" } },
    { id = "zenlabs-koreader-kindle", category = "utility", repo = "ZenLabs", platforms = { "kindle", "koreader" } },
}
assert(Models.filter_packages_by_category(categorized, "") == categorized)
local games = Models.filter_packages_by_category(categorized, "games")
assert(#games == 1 and games[1].id == "game")
local utilities = Models.filter_packages_by_category(categorized, "utilities")
assert(#utilities == 1 and utilities[1].id == "utility")
assert(Models.category_for_id("kindle-scriptlets", false) == nil)
local scriptlet_category = Models.category_for_id("kindle-scriptlets", true)
assert(scriptlet_category.label == "Kindle Scriptlets")
local scriptlets = Models.filter_packages_by_category(categorized, "kindle-scriptlets", true)
assert(#scriptlets == 3 and scriptlets[1].id == "scriptlet"
    and scriptlets[2].id == "zenlabs-scriptlet"
    and scriptlets[3].id == "zenlabs-koreader-kindle")
assert(#Models.filter_kindle_scriptlets(categorized, false) == 3)
assert(Models.filter_kindle_scriptlets(categorized, true) == categorized)
assert(#Models.category_cards(categorized, false) == 3)
local category_cards = Models.category_cards(categorized, true)
assert(#category_cards == 4)
assert(category_cards[4].id == "kindle-scriptlets" and category_cards[4].count == 3)

local notes = {
    release_notes_url = "https://example.invalid/RELEASE_NOTES.md",
    prerelease_notes_url = "https://example.invalid/PRERELEASE_NOTES.md",
}
assert(Models.has_release_notes(notes, false))
assert(Models.release_notes_url(notes, false) == notes.release_notes_url)
assert(Models.has_version_history({ versions_url = "https://example.invalid/versions.json" }))
assert(not Models.has_version_history({ versions_url = "   " }))
assert(not Models.has_version_history({ source = "https://github.com/owner/plugin" }))
assert(not Models.has_version_history({ source = "https://example.invalid/plugin" }))
assert(Models.release_notes_url(notes, true) == notes.prerelease_notes_url)
assert(not Models.has_release_notes({ prerelease_notes_url = notes.prerelease_notes_url }, false))
assert(Models.has_release_notes({ prerelease_notes_url = notes.prerelease_notes_url }, true))

local patch = Models.installed_patch_item({
    id = "patch", installed_asset_dates = { ["patch.lua"] = "2026-07-23T10:00:00Z" },
}, "patch.lua")
assert(patch.installed_at == "2026-07-23T10:00:00Z")

print("models tests passed")
