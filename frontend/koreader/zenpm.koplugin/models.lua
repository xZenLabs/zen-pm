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
            tostring(pkg.patch_asset or ""),
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
            or value == "koreaderpatch" or value == "koreaderpatches" then
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

-- Build the single-file view of an installed patch: a shallow clone of the parent
-- patch package narrowed to one asset, so its name/title and modify actions target
-- that patch file rather than the parent package.
function Models.installed_patch_item(pkg, asset)
    local item = {}
    for key, value in pairs(pkg) do
        item[key] = value
    end
    item.name = asset
    item.patch_asset = asset
    item.installed_assets = { asset }
    item.installed = true
    -- Drop the multi-asset list so the details view shows the patch itself, not the
    -- parent's per-file "Patches" tab.
    item.assets = nil
    return item
end

function Models.installed_packages(packages)
    local out = {}
    for _, pkg in ipairs(packages or {}) do
        if Models.is_patch_package(pkg) then
            for _, asset in ipairs(pkg.installed_assets or {}) do
                if type(asset) == "string" and asset ~= "" then
                    table.insert(out, Models.installed_patch_item(pkg, asset))
                end
            end
        elseif pkg.installed then
            table.insert(out, pkg)
        end
    end
    return out
end

function Models.select_featured(packages)
    local featured = {}
    for index, pkg in ipairs(packages or {}) do
        if pkg.featured then
            table.insert(featured, { pkg = pkg, index = index })
        end
    end
    table.sort(featured, function(a, b)
        local a_order = tonumber(a.pkg.featured_order)
        local b_order = tonumber(b.pkg.featured_order)
        if a_order ~= nil and b_order ~= nil then
            if a_order ~= b_order then return a_order < b_order end
            return a.index < b.index
        end
        if a_order ~= nil then return true end
        if b_order ~= nil then return false end
        return a.index < b.index
    end)
    for index, item in ipairs(featured) do
        featured[index] = item.pkg
    end
    if #featured >= 4 then
        return { featured[1], featured[2], featured[3], featured[4] }
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
    if Models.is_patch_package(pkg) and not Models.is_installed_patch_item(pkg) then
        if type(pkg.installed_assets) == "table" and #pkg.installed_assets > 0 then
            return _("Modify")
        end
        return _("Get")
    end
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

function Models.is_installed_patch_item(pkg)
    return Models.is_patch_package(pkg) and type(pkg.patch_asset) == "string" and pkg.patch_asset ~= ""
end

function Models.is_unmanaged_patch(pkg)
    return Models.is_installed_patch_item(pkg) and pkg.unmanaged_patch == true
end

local function github_repo_name(source)
    local repo = tostring(source or ""):match("^https?://github%.com/[^/]+/([^/%?#]+)")
    if repo then
        return repo:gsub("%.git$", "")
    end
    return nil
end

function Models.package_display_name(pkg, fallback)
    if Models.is_installed_patch_item(pkg) then
        return pkg.patch_asset
    end
    if Models.is_patch_package(pkg) then
        local source_repo = github_repo_name(pkg.source)
        if source_repo and source_repo ~= "" then
            return source_repo
        end
        local repo = I18n.dynamic_or(pkg.repo, "")
        if repo ~= "" and repo ~= Constants.REPO_ZENLABS_NAME and repo ~= Constants.REPO_KINDLEFORGE_NAME then
            return repo
        end
    end
    return I18n.dynamic_or(pkg and (pkg.name or pkg.id), fallback or _("Package"))
end

function Models.installed_asset_set(pkg)
    local set = {}
    local list = pkg and pkg.installed_assets
    if type(list) == "table" then
        for _, name in ipairs(list) do
            if type(name) == "string" and name ~= "" then
                set[name] = true
            end
        end
    end
    return set
end

function Models.patch_file_installed(pkg, asset)
    if not asset or asset == "" then
        return false
    end
    return Models.installed_asset_set(pkg)[asset] == true
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

function Models.has_readme(pkg)
    return tostring(pkg and pkg.readme_url or "") ~= "" or Models.has_github_source(pkg)
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
        local v = tostring(pkg.version):gsub("^[vV]", "")
        table.insert(parts, v:lower() == "source" and v or "v" .. v)
    end
    table.insert(parts, Models.repo_display_name(I18n.dynamic_or(pkg and pkg.repo, "?")))
    return table.concat(parts, " - ")
end

return Models
