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
            tostring(pkg.repo or ""),
            tostring(I18n.dynamic(pkg.repo) or ""),
        }, " "):lower()
        if hay:find(query, 1, true) then
            table.insert(out, pkg)
        end
    end
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
    return pkg and pkg.installed and _("Modify") or _("Get")
end

function Models.package_meta(pkg)
    local parts = {}
    if pkg and pkg.version and pkg.version ~= "" and pkg.version ~= "0.0.0" then
        table.insert(parts, "v" .. pkg.version)
    end
    table.insert(parts, I18n.dynamic_or(pkg and pkg.repo, "?"))
    return table.concat(parts, " - ")
end

return Models
