local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

package.preload["constants"] = function()
    return {
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
