local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")

local Cards = require("ui/cards")
local Constants = require("constants")
local I18n = require("i18n")
local Images = require("ui/images")
local P = require("ui/primitives")
local Search = require("ui/search")
local Theme = require("ui/theme")
local Util = require("zenpm_util")
local _ = require("gettext")

local Screen = Device.screen

local Chrome = InputContainer:extend{
    modal = false,
    stop_events_propagation = true,
}

local function tab_label(tab_id)
    if tab_id == "home" then
        return _("Featured")
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

local function ellipsize(value, limit)
    local title = tostring(value or "")
    if title and #title > limit then
        title = title:sub(1, limit)
        title = Util.fixUtf8(title, "") .. "…"
    end
    return title
end

function Chrome:init()
    self.hitboxes = {}
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapZenPM = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
        SwipeZenPM = {
            GestureRange:new{
                ges = "swipe",
                range = self.dimen,
            },
        },
    }
end

function Chrome:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    return self.dimen
end

function Chrome:onTapZenPM(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    for i = #self.hitboxes, 1, -1 do
        local box = self.hitboxes[i]
        if P.contains(box, x, y) then
            box.callback(x, y)
            return true
        end
    end
    if self:show_koreader_menu_from_gesture(ges, "tap") then
        return true
    end
    return true
end

function Chrome:gesture_in_menu_zone(ges)
    local pos = ges and ges.pos
    if not pos then
        return false
    end
    return pos.y <= (self.dimen.y or 0) + math.floor(Screen:getHeight() * 0.05)
end

function Chrome:show_koreader_menu_from_gesture(ges, kind)
    if not self:gesture_in_menu_zone(ges) then
        return false
    end
    local activation = G_reader_settings and G_reader_settings.readSetting and G_reader_settings:readSetting("activate_menu") or "swipe_tap"
    if activation == "swipe_tap" or activation == "tap_swipe" or activation == "both" then
        -- enabled for both activation gestures
    elseif activation ~= kind then
        return false
    end
    local plugin = self.app and self.app.plugin
    local ui = plugin and plugin.ui
    local menu = ui and ui.menu
    if not menu then
        return false
    end
    if kind == "swipe" and menu.onSwipeShowMenu then
        local ok = pcall(function()
            menu:onSwipeShowMenu(ges)
        end)
        return ok
    elseif kind == "tap" and menu.onTapShowMenu then
        local ok = pcall(function()
            menu:onTapShowMenu(ges)
        end)
        return ok
    elseif menu.onShowMenu then
        local ok = pcall(function()
            menu:onShowMenu()
        end)
        return ok
    end
    return false
end

function Chrome:onSwipeZenPM(_, ges)
    local direction = ges.direction
    if direction ~= "north" and direction ~= "south" then
        return true
    end
    if direction == "south" and self:show_koreader_menu_from_gesture(ges, "swipe") then
        return true
    end
    if self.list_bounds and not P.contains(self.list_bounds, ges.pos.x, ges.pos.y) then
        return true
    end
    local key = self.app:scroll_key()
    local old = self.app.state.scroll[key] or 0
    local delta = self.scroll_step or math.floor(Screen:getHeight() * 0.45)
    if direction == "north" then
        old = old + delta
    else
        old = old - delta
    end
    self.app.state.scroll[key] = math.max(0, math.min(old, self.max_scroll or 0))
    self:refresh()
    return true
end

function Chrome:refresh()
    UIManager:setDirty(self, "ui", self.dimen)
end

function Chrome:onCloseWidget()
    UIManager:setDirty("all", "flashui", self.dimen)
end

function Chrome:paintTo(bb, x, y)
    self.hitboxes = {}
    self.list_bounds = nil
    self.scroll_step = nil
    local m = Theme.metrics()
    self.dimen = Geom:new{ x = x, y = y, w = m.screen_w, h = m.screen_h }
    P.rect(bb, x, y, m.screen_w, m.screen_h, Theme.bg)

    local content_top = y
    content_top = self:draw_header(bb, x, content_top, m.screen_w)
    local nav_top = y + m.screen_h - m.nav_h
    local content_h = nav_top - content_top
    self:draw_content(bb, x, content_top, m.screen_w, content_h)
    self:draw_nav(bb, x, nav_top, m.screen_w, m.nav_h)
end

function Chrome:draw_actions(bb, x, y)
    local s = Theme.scale(42)
    P.box(bb, x, y, s, s, { border = false })
    local dot = Theme.scale(6)
    local cx = x + math.floor((s - dot) / 2)
    local first_y = y + math.floor((s - Theme.scale(24)) / 2)
    for i = 0, 2 do
        P.box(bb, cx, first_y + i * Theme.scale(9), dot, dot, { border = false, background = Theme.ink, radius = math.floor(dot / 2) })
    end
    P.hit(self, x, y, s, s, function() self.app:show_actions() end, "actions")
    return s
end

function Chrome:draw_header(bb, x, y, w)
    local page = self.app.state.page
    local m = Theme.metrics()
    local pad = m.pad
    if page == "home" then
        local h = Theme.scale(78)
        P.box(bb, x, y, w, h, { border = false })
        self:draw_actions(bb, x + w - pad - Theme.scale(42), y + Theme.scale(18))
        local logo = Theme.scale(52)
        local logo_y = y + Theme.scale(13)
        if not P.image(bb, Images.asset("zenpm.svg"), x + pad, y + Theme.scale(13), logo, logo, { is_icon = true }) then
            P.center_text(bb, "Z", x + pad, y + Theme.scale(30), logo, "title", { bold = true })
        end
        P.vcenter_text(bb, _("Welcome") .. " ZenPM", x + pad + Theme.scale(66), logo_y, w - pad * 2 - Theme.scale(112), logo, "title", { bold = true })
        return y + h
    elseif page == "search" then
        local h = Theme.scale(68)
        self:draw_actions(bb, x + w - pad - Theme.scale(42), y + Theme.scale(12))
        Search.draw(self, bb, x + pad, y + Theme.scale(11), w - pad * 2 - Theme.scale(52), self.app.state.filters.search, _("Search..."), function()
            self.app:prompt_filter("search")
        end, function()
            self.app:set_filter("search", "")
        end)
        return y + h
    elseif page == "installed" then
        local h = Theme.scale(68)
        self:draw_actions(bb, x + w - pad - Theme.scale(42), y + Theme.scale(12))
        Search.draw(self, bb, x + pad, y + Theme.scale(11), w - pad * 2 - Theme.scale(52), self.app.state.filters.installed, _("Filter installed..."), function()
            self.app:prompt_filter("installed")
        end, function()
            self.app:set_filter("installed", "")
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
        P.hit(self, button_x, y + Theme.scale(12), bw, bh, function() self.app:prompt_add_source() end, "add-source")
        self:draw_actions(bb, action_x, y + Theme.scale(13))
        return y + h
    elseif page == "source_details" then
        local h = Theme.scale(78)
        self:draw_actions(bb, x + w - pad - Theme.scale(42), y + Theme.scale(18))
        self:draw_back(bb, x + pad, y + Theme.scale(14), function() self.app:show_sources() end)
        local repo = self.app.state.current_repo or {}
        local icon = Theme.scale(68)
        local icon_x = x + pad + Theme.scale(56)
        local icon_y = y + Theme.scale(5)
        if not P.image(bb, self.app:repo_icon_file(repo), icon_x, icon_y, icon, icon, { is_icon = true }) then
            P.center_text(bb, "SRC", icon_x, icon_y + Theme.scale(27), icon, "small", { bold = true })
        end
        local text_x = icon_x + icon + Theme.scale(18)
        P.text(bb, ellipsize(I18n.dynamic_or(repo.name, _("Source Details")), 60), text_x, y + Theme.scale(13), w - text_x - pad - Theme.scale(48), "heading", { bold = true })
        P.text(bb, ellipsize(repo.url or "", 70), text_x, y + Theme.scale(44), w - text_x - pad - Theme.scale(48), "small")
        return y + h
    elseif page == "package_details" then
        local h = Theme.scale(68)
        self:draw_actions(bb, x + w - pad - Theme.scale(42), y + Theme.scale(8))
        self:draw_back(bb, x + pad, y + Theme.scale(8), function() self.app:go_back_from_details() end)
        local pkg = self.app.state.current_package or {}
        P.vcenter_text(bb, ellipsize(I18n.dynamic_or(pkg.name or pkg.id, _("Package Details")), 60), x + pad + Theme.scale(60), y + Theme.scale(8), w - pad * 2 - Theme.scale(112), Theme.scale(46), "heading", { bold = true })
        return y + h
    elseif page == "debug" then
        local h = Theme.scale(54)
        self:draw_actions(bb, x + w - pad - Theme.scale(42), y + Theme.scale(6))
        P.text(bb, _("ZenPM - Debug"), x + pad, y + Theme.scale(18), w - pad * 2, "heading", { bold = true })
        return y + h
    end
    return y
end

function Chrome:draw_back(bb, x, y, callback)
    local s = Theme.scale(46)
    P.box(bb, x, y, s, s, { border = false })
    if not P.image(bb, Images.asset("chevron.left.svg"), x + Theme.scale(8), y + Theme.scale(8), s - Theme.scale(16), s - Theme.scale(16), { is_icon = true }) then
        P.center_text(bb, "<", x, y + Theme.scale(13), s, "title", { bold = true })
    end
    P.hit(self, x, y, s, s, callback, "back")
end

function Chrome:set_list_bounds(x, y, w, h, step)
    self.list_bounds = { x = x, y = y, w = w, h = h }
    self.scroll_step = step
end

function Chrome:draw_scrollbar(bb, max_scroll, scroll)
    if not self.list_bounds or not max_scroll or max_scroll <= 0 then
        return
    end
    local b = self.list_bounds
    local margin = Theme.scale(9)
    local track_w = math.max(Theme.scale(3), 3)
    local touch_w = math.max(Theme.scale(28), 28)
    local track_x = b.x + b.w - margin - track_w
    local track_y = b.y + margin
    local track_h = b.h - margin * 2
    if track_h <= Theme.scale(24) then
        return
    end

    scroll = math.max(0, math.min(scroll or 0, max_scroll))
    local total_h = max_scroll + b.h
    local thumb_h = math.max(Theme.scale(28), math.floor(track_h * b.h / total_h))
    thumb_h = math.min(track_h, thumb_h)
    local travel = track_h - thumb_h
    local thumb_y = track_y
    if travel > 0 then
        thumb_y = track_y + math.floor(travel * scroll / max_scroll)
    end

    P.rounded_rect(bb, track_x, track_y, track_w, track_h, Theme.soft, math.floor(track_w / 2))
    P.rounded_rect(bb, track_x, thumb_y, track_w, thumb_h, Theme.ink, math.floor(track_w / 2))
    P.hit(self, track_x - touch_w + track_w, b.y, touch_w, b.h, function(_, tap_y)
        if travel <= 0 then
            return
        end
        local ratio = (tap_y - track_y - math.floor(thumb_h / 2)) / travel
        ratio = math.max(0, math.min(1, ratio))
        self.app.state.scroll[self.app:scroll_key()] = math.floor(max_scroll * ratio + 0.5)
        self:refresh()
    end, "scrollbar")
end

function Chrome:draw_scrolled_list(bb, items, x, y, w, h, scroll, item_h, gap, draw_item)
    self:set_list_bounds(x, y, w, h, item_h + gap)
    P.rect(bb, x, y, w, h, Theme.bg)
    local total_h = 0
    for _ in ipairs(items or {}) do
        total_h = total_h + item_h + gap
    end
    if #(items or {}) > 0 then
        total_h = total_h - gap
    end
    local step = item_h + gap
    local max_scroll = math.max(0, total_h - h)
    if max_scroll > 0 then
        max_scroll = math.ceil(max_scroll / step) * step
    end
    local scrollable = max_scroll > 0
    local cy = y - scroll
    for _, item in ipairs(items or {}) do
        if cy >= y and cy + item_h <= y + h then
            draw_item(item, cy, scrollable)
        end
        cy = cy + item_h + gap
    end
    return max_scroll
end

function Chrome:draw_content(bb, x, y, w, h)
    local state = self.app.state
    local page = state.page
    local scroll_key = self.app:scroll_key()
    local scroll = state.scroll[scroll_key] or 0
    local max_scroll = 0

    if page == "home" then
        max_scroll = self:draw_featured(bb, x, y, w, h, scroll)
    elseif page == "search" then
        max_scroll = self:draw_packages_page(bb, x, y, w, h, scroll, _("Search"), "search", state.visible_packages, state.packages, state.filters.search)
    elseif page == "installed" then
        max_scroll = self:draw_packages_page(bb, x, y, w, h, scroll, _("Installed"), "installed", state.visible_packages, state.installed_packages, state.filters.installed)
    elseif page == "sources" then
        max_scroll = self:draw_sources(bb, x, y, w, h, scroll)
    elseif page == "source_details" then
        max_scroll = self:draw_source_details(bb, x, y, w, h, scroll)
    elseif page == "package_details" then
        self:draw_package_details(bb, x, y, w, h)
        max_scroll = 0
    elseif page == "debug" then
        max_scroll = self:draw_debug(bb, x, y, w, h, scroll)
    end

    if state.error then
        P.text(bb, state.error, x + Theme.scale(16), y + Theme.scale(10), w - Theme.scale(32), "default", { color = Theme.muted })
    elseif state.loading then
        P.text(bb, state.loading, x + Theme.scale(16), y + Theme.scale(10), w - Theme.scale(32), "default", { color = Theme.muted })
    end

    self:draw_scrollbar(bb, max_scroll, scroll)
    if scroll > max_scroll then
        state.scroll[scroll_key] = max_scroll
    end
    self.max_scroll = max_scroll
end

function Chrome:draw_featured(bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local list = self.app.state.featured_packages or {}
    local list_y = y + Theme.scale(8)
    local list_h = h - Theme.scale(8)
    if #list == 0 then
        P.text(bb, _("Featured packages coming soon."), x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        self:set_list_bounds(x, list_y, w, list_h, m.featured_h + m.card_gap)
        return 0
    end
    return self:draw_scrolled_list(bb, list, x, list_y, w, list_h, scroll, m.featured_h, m.card_gap, function(pkg, cy, scrollable)
        local gutter = scrollable and Theme.scale(14) or 0
        Cards.featured(self, bb, pkg, x + pad, cy, w - pad * 2 - gutter)
    end)
end

function Chrome:draw_packages_page(bb, x, y, w, h, scroll, title, kind, visible, total, query)
    local m = Theme.metrics()
    local pad = m.pad
    local count = tostring(#(visible or {}))
    if query and query ~= "" then
        count = count .. "/" .. tostring(#(total or {}))
    end
    local cy = y
    P.text(bb, title .. " (" .. count .. ")", x + pad, cy + Theme.scale(6), w - pad * 2, "heading", { bold = true })
    cy = cy + Theme.scale(54)
    local list_y = cy
    local list_h = h - (list_y - y) - Theme.scale(8)
    if #(visible or {}) == 0 then
        local msg = _("No packages found. Try Refresh.")
        if kind == "installed" then
            msg = query and query ~= "" and _("No installed packages match the filter.") or _("No packages installed. Browse Search to find packages.")
        elseif query and query ~= "" then
            msg = _("No packages match the filter.")
        end
        P.text(bb, msg, x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        self:set_list_bounds(x, list_y, w, list_h, m.card_h + m.card_gap)
        return 0
    end
    return self:draw_scrolled_list(bb, visible, x, list_y, w, list_h, scroll, m.card_h, m.card_gap, function(pkg, row_y, scrollable)
        local gutter = scrollable and Theme.scale(14) or 0
        Cards.package(self, bb, pkg, x + pad, row_y, w - pad * 2 - gutter)
    end)
end

function Chrome:draw_sources(bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local list_y = y + Theme.scale(8)
    local list_h = h - Theme.scale(12)
    local repos = self.app.state.repos or {}
    if #repos == 0 then
        P.text(bb, _("No repositories configured."), x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        self:set_list_bounds(x, list_y, w, list_h, m.repo_h + m.card_gap)
        return 0
    end
    return self:draw_scrolled_list(bb, repos, x, list_y, w, list_h, scroll, m.repo_h, m.card_gap, function(repo, row_y)
        Cards.source(self, bb, repo, x + pad, row_y, w - pad * 2)
    end)
end

function Chrome:draw_source_details(bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local cy = y + Theme.scale(8)
    local visible = self.app.state.visible_packages or {}
    P.text(bb, _("Packages") .. " (" .. tostring(#visible) .. ")", x + pad, cy, w - pad * 2, "heading", { bold = true })
    cy = cy + Theme.scale(54)
    local list_y = cy
    local list_h = h - (list_y - y) - Theme.scale(8)
    if #visible == 0 then
        P.text(bb, _("No packages found for this source."), x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        self:set_list_bounds(x, list_y, w, list_h, m.card_h + m.card_gap)
        return 0
    end
    return self:draw_scrolled_list(bb, visible, x, list_y, w, list_h, scroll, m.card_h, m.card_gap, function(pkg, row_y, scrollable)
        local gutter = scrollable and Theme.scale(14) or 0
        Cards.package(self, bb, pkg, x + pad, row_y, w - pad * 2 - gutter)
    end)
end

function Chrome:draw_package_details(bb, x, y, w, h)
    local m = Theme.metrics()
    local pad = m.pad
    local pkg = self.app.state.current_package or {}
    local cy = y + Theme.scale(8)
    local panel_h = h - Theme.scale(30)
    local panel_x = x + pad
    local panel_w = w - pad * 2
    P.box(bb, panel_x, cy, panel_w, panel_h)
    local inner_x = x + pad + Theme.scale(12)
    local inner_w = w - pad * 2 - Theme.scale(24)
    local iy = cy + Theme.scale(12)
    if pkg.featured_image then
        local art_h = math.min(Theme.scale(146), math.floor(panel_h * 0.318))
        if not P.image_zoomed_masked(bb, self.app:package_featured_file(pkg), inner_x, iy, inner_w, art_h, 1.5, {
            is_icon = false,
            outer_bounds = { x = panel_x, y = cy, w = panel_w, h = panel_h },
            mask_bounds = { x = panel_x + Theme.scale(2), y = cy + Theme.scale(2), w = panel_w - Theme.scale(4), h = panel_h - Theme.scale(4) },
        }) then
            P.center_text(bb, _("Featured"), inner_x, iy + Theme.scale(60), inner_w, "heading", { bold = true, color = Theme.muted })
        end
        iy = iy + art_h
        P.rect(bb, panel_x + Theme.scale(2), iy, panel_w - Theme.scale(4), Theme.scale(1), Theme.border)
        iy = iy + Theme.scale(10)
    end
    Cards.package(self, bb, pkg, inner_x, iy, inner_w, {
        height = Theme.scale(148),
        second_line = _("By ") .. I18n.dynamic_or(pkg.author, "?"),
        text_gap = Theme.scale(6),
        border = false,
    })
    local card_bottom = iy + Theme.scale(148)
    local description_y = iy + Theme.scale(166)
    local divider_y = card_bottom + math.floor((description_y - card_bottom) / 2)
    P.rect(bb, panel_x + Theme.scale(2), divider_y, panel_w - Theme.scale(4), Theme.scale(1), Theme.soft)
    iy = description_y
    P.text(bb, _("Description"), inner_x, iy, inner_w, "small", { bold = true })
    iy = iy + Theme.scale(34)
    P.text(bb, I18n.dynamic_or(pkg.description, _("No description available.")), inner_x, iy, inner_w, "small")
    return cy + panel_h - Theme.scale(12)
end

function Chrome:draw_debug(bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local cy = y + Theme.scale(8)
    local panel_h = h - Theme.scale(16)
    P.box(bb, x + pad, cy, w - pad * 2, panel_h)
    local lines = self.app.state.log_lines or {}
    local inner_x = x + pad + Theme.scale(12)
    local inner_y = cy + Theme.scale(12)
    local inner_w = w - pad * 2 - Theme.scale(24)
    local inner_h = panel_h - Theme.scale(24)
    local line_h = Theme.scale(22)
    self:set_list_bounds(inner_x, inner_y, inner_w, inner_h, line_h)
    P.rect(bb, inner_x, inner_y, inner_w, inner_h, Theme.bg)

    local ty = inner_y - scroll
    for _, line in ipairs(lines) do
        if ty >= inner_y and ty + line_h <= inner_y + inner_h then
            P.text(bb, line, inner_x, ty, inner_w, "mono")
        end
        ty = ty + line_h
    end
    return math.max(0, #lines * line_h - inner_h)
end

function Chrome:draw_nav(bb, x, y, w, h)
    local tab_w = math.floor(w / #Constants.TABS)
    P.box(bb, x, y, w, h, { border = false, background = Theme.bg })
    P.rect(bb, x, y, w, Theme.scale(2), Theme.muted)
    local icons = {
        home = "home.svg",
        sources = "sources.svg",
        installed = "packages.svg",
        debug = "debug.svg",
        search = "search.svg",
    }
    for i, tab in ipairs(Constants.TABS) do
        local label = tab_label(tab.id)
        local tx = x + (i - 1) * tab_w
        local tw = i == #Constants.TABS and (w - (i - 1) * tab_w) or tab_w
        local icon_size = Theme.scale(44)
        if not P.image(bb, Images.asset(icons[tab.id] or "packages.svg"), tx + math.floor((tw - icon_size) / 2), y + Theme.scale(5), icon_size, icon_size, { is_icon = true }) then
            P.center_text(bb, label:sub(1, 1), tx, y + Theme.scale(14), tw, "heading", { bold = true })
        end
        local label_size = P.center_text(bb, label, tx, y + Theme.scale(50), tw, "small", { bold = self.app.state.active_tab == tab.id })
        if self.app.state.active_tab == tab.id then
            local ux = tx + math.max(0, math.floor((tw - label_size.w) / 2))
            P.rect(bb, ux, y + h - Theme.scale(5), label_size.w, Theme.scale(3), Theme.border)
        end
        P.hit(self, tx, y, tw, h, function() self.app:navigate(tab.id) end, "tab:" .. tab.id)
    end
end

return Chrome
