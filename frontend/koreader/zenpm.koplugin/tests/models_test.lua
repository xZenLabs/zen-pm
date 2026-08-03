local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

package.preload["constants"] = function()
    return {
        PLUGIN_DIR = root,
        REPO_ZENLABS_NAME = "ZenLabs",
        REPO_ZENLABS_DISPLAY = "ZenLabs",
        REPO_KINDLEFORGE_NAME = "KindleForge",
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

local updates = Models.sort_packages({
    { id = "current", name = "Current" },
    { id = "beta", name = "Beta", update_available = false },
    { id = "zulu", name = "Zulu", update_available = true },
    { id = "alpha", name = "Alpha", update_available = true },
    { id = "ignored", name = "Aardvark", update_available = true, update_ignored = true },
}, "update_available")
assert(updates[1].id == "alpha" and updates[2].id == "zulu" and updates[3].id == "ignored" and updates[4].id == "beta" and updates[5].id == "current")

local published = {
    { id = "first", name = "First", published_at = "2026-07-21T10:00:00Z" },
    { id = "second", name = "Second", published_at = "2026-07-22T10:00:00Z" },
    { id = "third", name = "Third", published_at = "2026-07-23T10:00:00Z" },
}
local recent = Models.sort_packages(published, "published_at_desc")
assert(recent[1].id == "third" and recent[2].id == "second" and recent[3].id == "first")

local change_candidates = {
    { id = "old-installed", name = "Old installed", installed = true, update_available = true, published_at = "2026-07-19T11:59:59Z" },
    { id = "older-installed", name = "Older installed", installed = true, published_at = "2026-07-20T12:00:00Z" },
    { id = "new", name = "New", published_at = "2026-08-02T11:00:00Z" },
    { id = "new-installed", name = "New installed", installed = true, update_available = true, published_at = "2026-08-01T10:00:00Z" },
    { id = "undated-update", name = "Undated update", installed = true, update_available = true },
    { id = "ignored", name = "Ignored", installed = true, update_available = true, update_ignored = true, published_at = "2026-08-02T11:30:00Z" },
    { id = "future", name = "Future", published_at = "2026-08-03T10:00:00Z" },
    { id = "invalid", name = "Invalid", published_at = "2026-07-99T10:00:00Z" },
    { id = "undated", name = "Undated" },
}
local changes = Models.changes_packages(change_candidates, 14, 40, "published_at_desc", 1785672000)
assert(#changes == 4)
assert(changes[1].id == "new-installed")
assert(changes[2].id == "old-installed")
assert(changes[3].id == "undated-update")
assert(changes[4].id == "new")

local ascending_changes = Models.changes_packages(change_candidates, 14, 40, "published_at_asc", 1785672000)
assert(ascending_changes[1].id == "old-installed")
assert(ascending_changes[2].id == "new-installed")
assert(ascending_changes[3].id == "undated-update")
assert(ascending_changes[4].id == "new")

local edge = Models.changes_packages({
    { id = "outside", published_at = "2026-07-19T11:59:59Z" },
    { id = "edge", published_at = "2026-07-19T12:00:00Z" },
}, 14, 20, "published_at_desc", 1785672000)
assert(#edge == 1 and edge[1].id == "edge")

local fallback = Models.changes_packages({
    { id = "latest", published_at = "2026-07-10T12:00:00Z" },
    { id = "second", published_at = "2026-07-09T12:00:00Z" },
    { id = "oldest", published_at = "2026-07-08T12:00:00Z" },
}, 14, 2, "published_at_desc", 1785672000)
assert(#fallback == 2)
assert(fallback[1].id == "latest" and fallback[2].id == "second")

local ascending_fallback = Models.changes_packages({
    { id = "latest", published_at = "2026-07-10T12:00:00Z" },
    { id = "second", published_at = "2026-07-09T12:00:00Z" },
    { id = "oldest", published_at = "2026-07-08T12:00:00Z" },
}, 14, 2, "published_at_asc", 1785672000)
assert(ascending_fallback[1].id == "second" and ascending_fallback[2].id == "latest")

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
}
assert(Models.filter_packages_by_category(categorized, "") == categorized)
local games = Models.filter_packages_by_category(categorized, "games")
assert(#games == 1 and games[1].id == "game")
local utilities = Models.filter_packages_by_category(categorized, "utilities")
assert(#utilities == 1 and utilities[1].id == "utility")

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
