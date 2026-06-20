local Constants = require("constants")
local I18n = require("i18n")
local Util = require("zenpm_util")
local _ = require("gettext")

local Models = {}

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

function Models.resolve_repo_url(base, value)
    return Util.join_url(base, value)
end

function Models.merge_repo_metadata(pkg, repo_pkg, repo_url)
    if not pkg or not repo_pkg then
        return pkg
    end
    for _, key in ipairs({ "name", "description", "author", "version", "image_url", "image", "repo_icon_url" }) do
        if repo_pkg[key] then
            pkg[key] = repo_pkg[key]
        end
    end
    if type(repo_pkg.images) == "table" then
        pkg.images = repo_pkg.images
    end
    if repo_pkg.icon_url then
        pkg.icon_url = Models.resolve_repo_url(repo_url, repo_pkg.icon_url)
    end
    if repo_pkg.featured_image then
        pkg.featured_image = Models.resolve_repo_url(repo_url, repo_pkg.featured_image)
    end
    if repo_pkg.featured then
        pkg.featured = true
    end
    return pkg
end

function Models.select_featured(packages, zenlabs_index)
    local featured = {}
    if type(zenlabs_index) == "table" and type(zenlabs_index.packages) == "table" then
        for _, repo_pkg in ipairs(zenlabs_index.packages) do
            if repo_pkg.featured then
                local pkg = Models.find_package(packages, repo_pkg.id)
                if pkg then
                    table.insert(featured, Models.merge_repo_metadata(pkg, repo_pkg, Constants.REPO_ZENLABS_URL))
                end
            end
        end
    end
    if #featured > 0 then
        return featured
    end
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
    if pkg and pkg.installed and pkg.update_available then
        return _("Update")
    end
    return pkg and pkg.installed and _("Modify") or _("Get")
end

function Models.package_meta(pkg)
    local parts = {}
    if pkg and pkg.version and pkg.version ~= "" and pkg.version ~= "0.0.0" then
        table.insert(parts, "v" .. tostring(pkg.version):gsub("^[vV]", ""))
    end
    table.insert(parts, I18n.dynamic_or(pkg and pkg.repo, "?"))
    return table.concat(parts, " - ")
end

return Models
