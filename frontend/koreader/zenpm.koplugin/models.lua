local Constants = require("constants")
local I18n = require("i18n")
local Util = require("zenpm_util")
local _ = require("gettext")

local Models = {}

function Models.repo_display_name(name)
    if name == Constants.REPO_ZENLABS_NAME then
        return Constants.REPO_ZENLABS_DISPLAY
    end
    return name
end

function Models.package_verified(pkg)
    local trust = pkg and pkg.repo_trust or ""
    return pkg and (pkg.repo_default
        or trust == "trusted"
        or trust == "signed"
        or pkg.repo == Constants.REPO_ZENLABS_NAME
        or pkg.repo == Constants.REPO_KINDLEFORGE_NAME) or false
end

function Models.repo_verified(repo)
    local trust = repo and repo.trust or ""
    return repo and (repo.default or trust == "trusted" or trust == "signed") or false
end

function Models.find_package(packages, id)
    return Util.table_find(packages, function(pkg)
        return pkg.id == id or pkg.name == id
    end)
end

function Models.filter_packages(packages, query)
    query = Util.trim(query):lower()
    if query == "" then
        return packages or {}
    end
    local out = {}
    for _, pkg in ipairs(packages or {}) do
        local hay = table.concat({
            tostring(pkg.name or ""),
            tostring(I18n.dynamic(pkg.name) or ""),
            tostring(pkg.id or ""),
            tostring(pkg.description or ""),
            tostring(I18n.dynamic(pkg.description) or ""),
            tostring(pkg.category or ""),
            tostring(I18n.dynamic(pkg.category) or ""),
            tostring(pkg.repo or ""),
            tostring(I18n.dynamic(pkg.repo) or ""),
        }, " "):lower()
        if hay:find(query, 1, true) then
            table.insert(out, pkg)
        end
    end
    return out
end

local function normalize_category(value)
    value = Util.trim(tostring(value or "")):lower()
    value = value:gsub("[%s_%-]+", "")
    if value == "game" then
        return "games"
    end
    if value == "utilities" then
        return "utility"
    end
    if value == "patch" or value == "patches"
            or value == "koreaderpatch" or value == "koreaderpatches"
            or value == "koreaderplatformpatch" or value == "koreaderplatformpatches" then
        return "koreaderpatches"
    end
    return value
end

function Models.category_label(category)
    return I18n.dynamic_or(category and category.label, tostring(category and category.id or ""))
end

function Models.category_for_id(id)
    id = normalize_category(id)
    for _, category in ipairs(Constants.CATEGORIES) do
        if normalize_category(category.id) == id or normalize_category(category.label) == id then
            return category
        end
    end
    return nil
end

function Models.package_in_category(pkg, category)
    if not pkg or not category then
        return false
    end
    local wanted = normalize_category(category.id)
    if normalize_category(pkg.category) == wanted then
        return true
    end
    if type(pkg.tags) == "table" then
        for _, tag in ipairs(pkg.tags) do
            if normalize_category(tag) == wanted then
                return true
            end
        end
    end
    return false
end

function Models.packages_in_category(packages, category)
    local out = {}
    for _, pkg in ipairs(packages or {}) do
        if Models.package_in_category(pkg, category) then
            table.insert(out, pkg)
        end
    end
    return out
end

function Models.category_cards(packages)
    local cards = {}
    for _, category in ipairs(Constants.CATEGORIES) do
        local count = 0
        for _, pkg in ipairs(packages or {}) do
            if Models.package_in_category(pkg, category) then
                count = count + 1
            end
        end
        table.insert(cards, {
            id = category.id,
            label = category.label,
            icon = category.icon,
            count = count,
        })
    end
    return cards
end

function Models.filter_categories(categories, query)
    query = Util.trim(query):lower()
    if query == "" then
        return categories or {}
    end
    local out = {}
    for _, category in ipairs(categories or {}) do
        local hay = table.concat({
            tostring(category.id or ""),
            tostring(category.label or ""),
            tostring(I18n.dynamic(category.label) or ""),
        }, " "):lower()
        if hay:find(query, 1, true) then
            table.insert(out, category)
        end
    end
    return out
end

local function package_name(pkg)
    return I18n.dynamic_or(pkg and (pkg.name or pkg.id), ""):lower()
end

local function package_repo(pkg)
    return I18n.dynamic_or(pkg and pkg.repo, ""):lower()
end

local function package_stars_value(pkg)
    local stars = Util.trim(tostring(pkg and pkg.stars or ""))
    if stars == "" then
        return nil
    end
    return tonumber(stars)
end

local function compare_text(a, b)
    local an, bn = package_name(a), package_name(b)
    if an ~= bn then
        return an < bn
    end
    local ar, br = package_repo(a), package_repo(b)
    if ar ~= br then
        return ar < br
    end
    return tostring(a and a.id or "") < tostring(b and b.id or "")
end

function Models.sort_packages(packages, sort_key)
    local out = {}
    for _, pkg in ipairs(packages or {}) do
        table.insert(out, pkg)
    end
    sort_key = sort_key or "stars"
    table.sort(out, function(a, b)
        if sort_key == "name" then
            return compare_text(a, b)
        elseif sort_key == "repo" then
            local ar, br = package_repo(a), package_repo(b)
            if ar ~= br then
                return ar < br
            end
            return compare_text(a, b)
        end
        local as, bs = package_stars_value(a), package_stars_value(b)
        if as and bs and as ~= bs then
            return as > bs
        end
        if as and not bs then
            return true
        end
        if bs and not as then
            return false
        end
        return compare_text(a, b)
    end)
    return out
end

function Models.installed_packages(packages)
    local out = {}
    for _, pkg in ipairs(packages or {}) do
        if pkg.installed then
            table.insert(out, pkg)
        end
    end
    return out
end

function Models.select_featured(packages)
    local featured = {}
    for _, pkg in ipairs(packages or {}) do
        if pkg.featured then
            table.insert(featured, pkg)
            if #featured >= 4 then
                return featured
            end
        end
    end
    for _, id in ipairs(Constants.FEATURED_IDS) do
        local pkg = Models.find_package(packages, id)
        if pkg then
            table.insert(featured, pkg)
        end
        if #featured >= 4 then
            break
        end
    end
    return featured
end

function Models.package_action_label(pkg)
    if pkg and pkg.installed then
        return _("Modify")
    end
    return _("Get")
end

function Models.is_patch_package(pkg)
    if not pkg then
        return false
    end
    return normalize_category(pkg.category) == "koreaderpatches"
end

function Models.package_assets(pkg)
    local assets = pkg and pkg.assets
    if type(assets) ~= "table" then
        return {}
    end
    local out = {}
    for _, asset in ipairs(assets) do
        if type(asset) == "table" and asset.asset and asset.asset ~= "" then
            table.insert(out, asset)
        end
    end
    return out
end

function Models.has_github_source(pkg)
    local source = tostring(pkg and pkg.source or "")
    return source:match("^https?://github%.com/[^/]+/[^/]+/?$") ~= nil
end

function Models.readme_text(value)
    value = tostring(value or ""):gsub("\r\n", "\n")
    value = value:gsub("<!%-%-.-%-%->", "")
    value = value:gsub("!%[([^%]]*)%]%([^%)]+%)", "%1")
    value = value:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
    value = value:gsub("<[^>]+>", "")
    value = value:gsub("\n[ \t]*#+[ \t]+", "\n")
    value = value:gsub("^#+[ \t]+", "")
    value = value:gsub("```[%w_-]*", "")
    value = value:gsub("[%*_]([%w][^%*_]-)[%*_]", "%1")
    value = value:gsub("\n[ \t]*\n[ \t]*\n+", "\n\n")
    return Util.trim(value)
end

function Models.package_meta(pkg)
    local parts = {}
    if pkg and pkg.version and pkg.version ~= "" and pkg.version ~= "0.0.0" then
        table.insert(parts, "v" .. tostring(pkg.version):gsub("^[vV]", ""))
    end
    table.insert(parts, Models.repo_display_name(I18n.dynamic_or(pkg and pkg.repo, "?")))
    return table.concat(parts, " - ")
end

return Models
