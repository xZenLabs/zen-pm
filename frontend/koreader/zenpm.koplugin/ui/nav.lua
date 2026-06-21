-- Bottom tab bar rendering for AppView. Takes the AppView instance to register
-- per-tab hitboxes.

local Constants = require("constants")
local Images = require("ui/images")
local P = require("ui/primitives")
local Theme = require("ui/theme")
local _ = require("gettext")

local Nav = {}

local function tab_label(tab_id)
    if tab_id == "home" then
        return _("Featured")
    elseif tab_id == "categories" then
        return _("Categories")
    elseif tab_id == "sources" then
        return _("Sources")
    elseif tab_id == "installed" then
        return _("Installed")
    elseif tab_id == "debug" then
        return _("Debug")
    elseif tab_id == "search" then
        return _("Search")
    end
    return tostring(tab_id or "")
end

local ICONS = {
    home = "star.svg",
    categories = "categories.svg",
    sources = "sources.svg",
    installed = "packages.svg",
    debug = "debug.svg",
    search = "search.svg",
}

function Nav.draw(view, bb, x, y, w, h)
    local tab_w = math.floor(w / #Constants.TABS)
    P.box(bb, x, y, w, h, { border = false, background = Theme.bg })
    P.rect(bb, x, y, w, Theme.scale(2), Theme.muted)
    for i, tab in ipairs(Constants.TABS) do
        local label = tab_label(tab.id)
        local tx = x + (i - 1) * tab_w
        local tw = i == #Constants.TABS and (w - (i - 1) * tab_w) or tab_w
        local icon_size = Theme.scale(44)
        if not P.image(bb, Images.asset(ICONS[tab.id] or "packages.svg"), tx + math.floor((tw - icon_size) / 2), y + Theme.scale(5), icon_size, icon_size, { is_icon = true }) then
            P.center_text(bb, label:sub(1, 1), tx, y + Theme.scale(14), tw, "heading", { bold = true })
        end
        local label_size = P.center_text(bb, label, tx, y + Theme.scale(50), tw, "nav", { bold = view.app.state.active_tab == tab.id })
        if view.app.state.active_tab == tab.id then
            local ux = tx + math.max(0, math.floor((tw - label_size.w) / 2))
            P.rect(bb, ux, y + h - Theme.scale(5), label_size.w, Theme.scale(3), Theme.border)
        end
        P.hit(view, tx, y, tw, h, function() view.app:navigate(tab.id) end, "tab:" .. tab.id)
    end
end

return Nav
