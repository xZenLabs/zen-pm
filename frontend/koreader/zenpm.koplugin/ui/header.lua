-- Top bar rendering for AppView: the per-page header, plus the shared back
-- button, overflow-actions button and sort button. Each function takes the
-- AppView instance so it can register hitboxes via P.hit(view, ...).

local Images = require("ui/images")
local Models = require("models")

local Geom = require("ui/geometry")
local I18n = require("i18n")
local P = require("ui/primitives")
local Theme = require("ui/theme")
local _ = require("gettext")

local Header = {}

local function protect_koreader_menu_tap(view, x, y, size)
    local exclusion_s = Theme.scale(72)
    local exclusion_pad = math.floor((exclusion_s - size) / 2)
    view.koreader_menu_tap_exclusions = view.koreader_menu_tap_exclusions or {}
    table.insert(view.koreader_menu_tap_exclusions, {
        x = x - exclusion_pad,
        y = y - exclusion_pad,
        w = exclusion_s,
        h = exclusion_s,
    })
end

local function ellipsize(value, limit)
    local title = tostring(value or "")
    if title and #title > limit then
        title = title:sub(1, limit)
        title = require("zenpm_util").fixUtf8(title, "") .. "…"
    end
    return title
end

function Header.draw_actions(view, bb, x, y)
    local s = Theme.scale(42)
    P.box(bb, x, y, s, s, { border = false })
    local dot = Theme.scale(6)
    local cx = x + math.floor((s - dot) / 2)
    local first_y = y + math.floor((s - Theme.scale(24)) / 2)
    for i = 0, 2 do
        P.box(bb, cx, first_y + i * Theme.scale(9), dot, dot, { border = false, background = Theme.ink, radius = math.floor(dot / 2) })
    end
    P.hit(view, x, y, s, s, function()
        view.app:show_actions(Geom:new{ x = x, y = y, w = s, h = s })
    end, "actions")
    protect_koreader_menu_tap(view, x, y, s)
    return s
end

function Header.draw_sort_button(view, bb, x, y, kind)
    local s = Theme.scale(42)
    local icon = Theme.scale(32)
    P.box(bb, x, y, s, s, { border = false })
    local icon_y = y + math.floor((s - icon) / 2) + Theme.scale(8)
    if not P.image(bb, Images.asset("sort.svg"), x + math.floor((s - icon) / 2), icon_y, icon, icon, { is_icon = true }) then
        P.center_text_box(bb, "Sort", x, y + Theme.scale(8), s, s, "small", { bold = true })
    end
    P.hit(view, x, y, s, s, function() view.app:prompt_sort(kind) end, "sort:" .. tostring(kind))
    return s
end

function Header.draw_back(view, bb, x, y, callback)
    local s = Theme.scale(46)
    P.box(bb, x, y, s, s, { border = false })
    if not P.image(bb, Images.asset("chevron.left.svg"), x + Theme.scale(8), y + Theme.scale(8), s - Theme.scale(16), s - Theme.scale(16), { is_icon = true }) then
        P.center_text(bb, "<", x, y + Theme.scale(13), s, "title", { bold = true })
    end
    P.hit(view, x, y, s, s, callback, "back")
    protect_koreader_menu_tap(view, x, y, s)
end

function Header.draw(view, bb, x, y, w)
    local page = view.app.state.page
    local m = Theme.metrics()
    local pad = m.pad
    if page == "home" then
        local h = Theme.scale(78)
        P.box(bb, x, y, w, h, { border = false })
        local row_h = Theme.scale(42)
        local row_y = y + Theme.scale(12)
        local action_x = x + w - pad - row_h
        Header.draw_actions(view, bb, action_x, row_y)
        local logo = Theme.scale(42)
        if not P.image(bb, Images.asset("zenpm.svg"), x + pad, row_y, logo, logo, { is_icon = true }) then
            P.center_text_box(bb, "Z", x + pad, row_y, logo, logo, "title", { bold = true })
        end
        local text_x = x + pad + logo + Theme.scale(14)
        local title = _("Welcome") .. " " .. _("to") .. " " .. _("ZenPM")
        local title_size = P.text_size(title, action_x - text_x - Theme.scale(8), "title", { bold = true })
        local title_y = row_y + math.floor((row_h - title_size.h) / 2) - Theme.scale(3)
        P.text(bb, title, text_x, title_y, action_x - text_x - Theme.scale(8), "title", { bold = true })
        return y + h
    elseif page == "search" then
        local h = Theme.scale(68)
        Header.draw_actions(view, bb, x + w - pad - Theme.scale(42), y + Theme.scale(12))
        require("ui/search").draw(view, bb, x + pad, y + Theme.scale(11), w - pad * 2 - Theme.scale(52), view.app.state.filters.search, _("Search..."), function()
            view.app:prompt_filter("search")
        end, function()
            view.app:set_filter("search", "")
        end)
        return y + h
    elseif page == "categories" then
        local h = Theme.scale(68)
        Header.draw_actions(view, bb, x + w - pad - Theme.scale(42), y + Theme.scale(12))
        require("ui/search").draw(view, bb, x + pad, y + Theme.scale(11), w - pad * 2 - Theme.scale(52), view.app.state.filters.categories, _("Search categories..."), function()
            view.app:prompt_filter("categories")
        end, function()
            view.app:set_filter("categories", "")
        end)
        return y + h
    elseif page == "category_details" then
        local h = Theme.scale(68)
        local action_s = Theme.scale(42)
        local back_s = Theme.scale(46)
        local gap = Theme.scale(6)
        local action_x = x + w - pad - action_s
        local search_x = x + pad + back_s + gap
        Header.draw_back(view, bb, x + pad, y + Theme.scale(11), function() view.app:show_categories() end)
        Header.draw_actions(view, bb, action_x, y + Theme.scale(12))
        require("ui/search").draw(view, bb, search_x, y + Theme.scale(11), action_x - search_x - gap, view.app.state.filters.category, _("Search category..."), function()
            view.app:prompt_filter("category")
        end, function()
            view.app:set_filter("category", "")
        end)
        return y + h
    elseif page == "installed" then
        local h = Theme.scale(68)
        Header.draw_actions(view, bb, x + w - pad - Theme.scale(42), y + Theme.scale(12))
        require("ui/search").draw(view, bb, x + pad, y + Theme.scale(11), w - pad * 2 - Theme.scale(52), view.app.state.filters.installed, _("Filter installed..."), function()
            view.app:prompt_filter("installed")
        end, function()
            view.app:set_filter("installed", "")
        end)
        return y + h
    elseif page == "sources" then
        local h = Theme.scale(68)
        local action_s = Theme.scale(42)
        local bw, bh = Theme.scale(170), Theme.scale(44)
        local gap = Theme.scale(8)
        local action_x = x + w - pad - action_s
        local button_x = action_x - gap - bw
        P.vcenter_text(bb, _("Sources"), x + pad, y + Theme.scale(12), button_x - x - pad - Theme.scale(8), bh, "title", { bold = true })
        P.box(bb, button_x, y + Theme.scale(12), bw, bh, { radius = math.floor(bh / 2) })
        P.center_text_box(bb, "+ " .. _("Add Source"), button_x, y + Theme.scale(12), bw, bh, "small", { bold = true })
        P.hit(view, button_x, y + Theme.scale(12), bw, bh, function() view.app:prompt_add_source() end, "add-source")
        Header.draw_actions(view, bb, action_x, y + Theme.scale(13))
        return y + h
    elseif page == "source_details" then
        local h = Theme.scale(78)
        Header.draw_actions(view, bb, x + w - pad - Theme.scale(42), y + Theme.scale(18))
        Header.draw_back(view, bb, x + pad, y + Theme.scale(14), function() view.app:show_sources() end)
        local repo = view.app.state.current_repo or {}
        local icon = Theme.scale(68)
        local icon_x = x + pad + Theme.scale(56)
        local icon_y = y + Theme.scale(5)
        if not P.image(bb, view.app:repo_icon_file(repo), icon_x, icon_y, icon, icon, { is_icon = true }) then
            P.center_text(bb, "SRC", icon_x, icon_y + Theme.scale(27), icon, "small", { bold = true })
        end
        local text_x = icon_x + icon + Theme.scale(18)
        P.text(bb, ellipsize(Models.repo_display_name(I18n.dynamic_or(repo.name, _("Source Details"))), 60), text_x, y + Theme.scale(13), w - text_x - pad - Theme.scale(48), "heading", { bold = true })
        P.text(bb, ellipsize(repo.url or "", 70), text_x, y + Theme.scale(44), w - text_x - pad - Theme.scale(48), "small")
        return y + h
    elseif page == "package_details" then
        local h = Theme.scale(68)
        Header.draw_actions(view, bb, x + w - pad - Theme.scale(42), y + Theme.scale(8))
        Header.draw_back(view, bb, x + pad, y + Theme.scale(8), function() view.app:go_back_from_details() end)
        local pkg = view.app.state.current_package or {}
        P.vcenter_text(bb, ellipsize(Models.package_display_name(pkg, _("Package Details")), 60), x + pad + Theme.scale(60), y + Theme.scale(8), w - pad * 2 - Theme.scale(112), Theme.scale(46), "heading", { bold = true })
        return y + h
    elseif page == "debug" then
        local h = Theme.scale(54)
        Header.draw_actions(view, bb, x + w - pad - Theme.scale(42), y + Theme.scale(6))
        P.text(bb, _("ZenPM - Debug"), x + pad, y + Theme.scale(18), w - pad * 2, "heading", { bold = true })
        return y + h
    end
    return y
end

return Header
