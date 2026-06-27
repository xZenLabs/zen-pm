local P = require("ui/primitives")
local Images = require("ui/images")
local Theme = require("ui/theme")
local _ = require("gettext")

local Search = {}

function Search.draw(view, bb, x, y, w, value, placeholder, callback, clear_callback)
    local m = Theme.metrics()
    P.box(bb, x, y, w, m.search_h, { radius = math.floor(m.search_h / 2), background = Theme.bg })
    local icon_size = Theme.scale(24)
    if not P.image(bb, Images.asset("search.svg"), x + Theme.scale(14), y + math.floor((m.search_h - icon_size) / 2), icon_size, icon_size, { is_icon = true }) then
        P.text(bb, _("Search"), x + Theme.scale(14), y + Theme.scale(14), Theme.scale(46), "small", { bold = true })
    end
    local text = value and value ~= "" and value or placeholder
    local color = value and value ~= "" and Theme.ink or Theme.muted
    P.vcenter_text(bb, text, x + Theme.scale(46), y, w - Theme.scale(94), m.search_h, "default", { color = color })
    P.hit(view, x, y, w - Theme.scale(46), m.search_h, callback, "search")
    if value and value ~= "" then
        local clear_w = Theme.scale(48)
        local clear_x = x + w - clear_w
        if not P.image(bb, Images.asset("close.svg"), clear_x + math.floor((clear_w - icon_size) / 2), y + math.floor((m.search_h - icon_size) / 2), icon_size, icon_size, { is_icon = true }) then
            P.center_text_box(bb, "x", clear_x, y, clear_w, m.search_h, "default")
        end
        P.hit(view, clear_x, y, clear_w, m.search_h, clear_callback, "clear-search")
    end
    return m.search_h
end

return Search
