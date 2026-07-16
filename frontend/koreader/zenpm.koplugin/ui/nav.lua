-- Bottom tab bar rendering for AppView. Takes the AppView instance to register
-- per-tab hitboxes.

local Constants = require("constants")
local Font = require("ui/font")
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
        local label_size = P.center_text(bb, label, tx, y + Theme.scale(50), tw, "nav")
        if view.app.state.active_tab == tab.id then
            local ux = tx + math.max(0, math.floor((tw - label_size.w) / 2))
            P.rect(bb, ux, y + h - Theme.scale(5), label_size.w, Theme.scale(3), Theme.border)
        end
        if tab.id == "installed" then
            local updates = view.app:installed_update_count()
            if updates > 0 then
                local badge_s = Theme.scale(24)
                local badge_x = tx + tw - badge_s - Theme.scale(8)
                local badge_y = y + Theme.scale(5)
                P.box(bb, badge_x, badge_y, badge_s, badge_s, {
                    border = false,
                    background = Theme.ink,
                    radius = math.floor(badge_s / 2),
                })
                local badge_face = updates >= 10 and Font:getFace("smallinfofont", Theme.font_scale(12)) or nil
                P.center_text_box(bb, tostring(updates), badge_x, badge_y - Theme.scale(3), badge_s, badge_s, "tiny", { bold = true, color = Theme.bg, face = badge_face })
            end
        end
        P.hit(view, tx, y, tw, h, function() view.app:navigate(tab.id) end, "tab:" .. tab.id)
    end
end

function Nav.draw_queue_banner(view, bb, x, y, w, h)
    P.box(bb, x, y, w, h, { border = false, background = Theme.panel })
    P.rect(bb, x, y, w, Theme.scale(2), Theme.muted)
    local pad = Theme.metrics().pad
    local chevron_s = Theme.scale(28)
    local count = view.app:queue_count()
    local label = count == 1 and _("1 package queued") or string.format(_("%d packages queued"), count)
    P.vcenter_text(bb, label, x + pad, y, w - pad * 2 - chevron_s, h, "small", { bold = true })
    P.image(bb, Images.asset("chevron.up.svg"), x + w - pad - chevron_s, y + math.floor((h - chevron_s) / 2), chevron_s, chevron_s, { is_icon = true })
    P.hit(view, x, y, w, h, function() view.app:show_queue() end, "queue-banner")
end

return Nav
