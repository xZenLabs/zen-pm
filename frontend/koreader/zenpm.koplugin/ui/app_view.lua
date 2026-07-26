-- AppView is the root InputContainer for the ZenPM UI. It owns the widget
-- shell: gesture handling, the paint pipeline and shared per-paint state
-- (hitboxes, list_bounds, scrollbar geometry, max_scroll). The actual drawing
-- is delegated to focused modules:
--   ui/header.lua  top bar (header, back, actions, sort)
--   ui/pages.lua   per-page scrollable content
--   ui/nav.lua     bottom tab bar
--   ui/scroll.lua  scrolled lists + scrollbar drag

local Device = require("device")
local Input = require("device/input")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")

local Header = require("ui/header")
local I18n = require("i18n")
local Nav = require("ui/nav")
local P = require("ui/primitives")
local Pages = require("ui/pages")
local Scroll = require("ui/scroll")
local Theme = require("ui/theme")
local _ = require("gettext")

local Screen = Device.screen

local AppView = InputContainer:extend{
    modal = false,
    stop_events_propagation = true,
}

function AppView:init()
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
        PanZenPM = {
            GestureRange:new{
                ges = "pan",
                range = self.dimen,
            },
        },
        PanReleaseZenPM = {
            GestureRange:new{
                ges = "pan_release",
                range = self.dimen,
            },
        },
    }
    if Device:hasKeys() then
        self.key_events = {
            ZenPMPageForward = { { Input.group.PgFwd }, event = "ZenPMScroll", args = 1 },
            ZenPMPageBack = { { Input.group.PgBack }, event = "ZenPMScroll", args = -1 },
        }
    end
end

function AppView:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    return self.dimen
end

-- ---------------------------------------------------------------------------
-- Gestures
-- ---------------------------------------------------------------------------

function AppView:onTapZenPM(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    for i = #self.hitboxes, 1, -1 do
        local box = self.hitboxes[i]
        if P.contains(box, x, y) then
            box.callback(x, y)
            return true
        end
    end
    if self:tap_should_pass_to_koreader_menu(ges) then
        return self:show_koreader_menu_from_gesture(ges, "tap")
    end
    return true
end

function AppView:tap_menu_enabled()
    local activation = G_reader_settings and G_reader_settings.readSetting and G_reader_settings:readSetting("activate_menu") or "swipe_tap"
    return activation == "tap" or activation == "swipe_tap" or activation == "tap_swipe" or activation == "both"
end

function AppView:tap_in_koreader_menu_zone(ges)
    local pos = ges and ges.pos
    return pos and self.koreader_menu_zone and P.contains(self.koreader_menu_zone, pos.x, pos.y)
end

function AppView:tap_should_pass_to_koreader_menu(ges)
    return self:tap_menu_enabled()
        and self:tap_in_koreader_menu_zone(ges)
end

function AppView:gesture_in_menu_zone(ges)
    local pos = ges and ges.pos
    return pos and self.koreader_menu_zone and P.contains(self.koreader_menu_zone, pos.x, pos.y)
end

function AppView:show_koreader_menu_from_gesture(ges, kind)
    if kind == "tap" then
        if not self:tap_menu_enabled() or not self:tap_in_koreader_menu_zone(ges) then
            return false
        end
    elseif not self:gesture_in_menu_zone(ges) then
        return false
    else
        local activation = G_reader_settings and G_reader_settings.readSetting and G_reader_settings:readSetting("activate_menu") or "swipe_tap"
        if activation ~= "swipe_tap" and activation ~= "tap_swipe" and activation ~= "both" and activation ~= kind then
            return false
        end
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

function AppView:_scroll_list(steps, page_sized)
    local key = self.app:scroll_key()
    local old = self.app.state.scroll[key] or 0
    local delta = self.scroll_step or math.floor(Screen:getHeight() * 0.45)
    if page_sized and self.list_bounds then
        delta = math.floor(self.list_bounds.h * 0.9)
    end
    local new = math.max(0, math.min(old + steps * delta, self.max_scroll or 0))
    if new == old then
        return false
    end
    self.app.state.scroll[key] = new
    self:refresh()
    return true
end

function AppView:onZenPMScroll(steps)
    self:_scroll_list(steps, true)
    return true
end

function AppView:onSwipeZenPM(_, ges)
    -- A fast scrollbar drag can terminate as a swipe rather than pan_release.
    -- Finalize the in-progress drag with a clean GL16 repaint and consume the
    -- event, so it neither leaks a stuck drag flag nor double-scrolls via the
    -- paging logic below.
    if self._scroll_dragging then
        -- Don't re-apply ges.pos here: for a swipe, ges.pos is the gesture
        -- START, not the lift point. The pan events already moved the thumb to
        -- the latest position, so just finalize the current offset.
        self:_end_scroll_drag(nil)
        return true
    end
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
    self:_scroll_list(direction == "north" and 1 or -1)
    return true
end

-- Delay before the list re-renders once the thumb stops moving. The thumb
-- itself follows the finger every frame (cheap A2 paint of just the track);
-- only the expensive list-item render is debounced. Re-rendering the list on
-- every step queues competing GL16 waveforms that look jarring, so it is
-- deferred until the drag settles for this long.
local SCROLL_LIST_RENDER_DELAY = 0.18

-- Repaint the list region (scoping avoids flashing the header/nav). Re-runs
-- paintTo, which redraws the items at the current scroll offset. GL16 ("ui"),
-- not A2 ("fast"): the cards contain gray, which the 1-bit A2 waveform
-- corrupts into lingering square ghosts.
function AppView:_render_scroll_list()
    local region = self.scrollbar and self.scrollbar.region or self.dimen
    UIManager:setDirty(self, "ui", Geom:new(region))
end

function AppView:onPanZenPM(_, ges)
    if ges.mousewheel_direction then
        self._mousewheel_handled = true
        if ges.direction == "north" then
            self:_scroll_list(1)
        elseif ges.direction == "south" then
            self:_scroll_list(-1)
        end
        return true
    end

    -- Only begin a drag when the gesture starts inside the scrollbar touch
    -- zone; otherwise let the pan fall through (e.g. for menu gestures).
    if not self._scroll_dragging then
        local sb = self.scrollbar
        if not sb or sb.travel <= 0 or not P.contains(sb.zone, ges.pos.x, ges.pos.y) then
            return false
        end
        self._scroll_dragging = true
    end

    -- 1. Thumb follows the finger smoothly: paint just the track strip directly
    --    to Screen.bb and push an A2 refresh over each changed thumb footprint
    --    via setDirty(nil) — nil means "repaint no widgets", so the list items
    --    are left untouched. paint_drag_thumb returns only the small old/new
    --    thumb rects, never the span between, so no tall bar is refreshed.
    local rects = Scroll.paint_drag_thumb(self, ges.pos.y)
    if rects then
        for _i = 1, #rects do
            UIManager:setDirty(nil, "fast", Geom:new(rects[_i]))
        end
    end

    -- 2. List items are debounced: update the snapped model offset now, but
    --    defer the costly list render until the finger settles. Each move that
    --    advances the offset reschedules the trailing render.
    if Scroll.apply_y(self, ges.pos.y) then
        self._scroll_list_render = self._scroll_list_render or function()
            self:_render_scroll_list()
        end
        UIManager:unschedule(self._scroll_list_render)
        UIManager:scheduleIn(SCROLL_LIST_RENDER_DELAY, self._scroll_list_render)
    end
    return true
end

function AppView:onPanReleaseZenPM(_, ges)
    if ges and ges.from_mousewheel then
        if self._mousewheel_handled then
            self._mousewheel_handled = false
            return true
        end
        local relative_y = ges.relative and ges.relative.y
        if relative_y and relative_y < 0 then
            self:_scroll_list(1)
        elseif relative_y and relative_y > 0 then
            self:_scroll_list(-1)
        end
        return true
    end
    if not self._scroll_dragging then
        return false
    end
    self:_end_scroll_drag(ges and ges.pos and ges.pos.y)
    return true
end

-- Finalize a scrollbar drag: drop the pending debounced render, commit the
-- final offset and do one immediate clean repaint of the list.
function AppView:_end_scroll_drag(pos_y)
    self._scroll_dragging = false
    if self._scroll_list_render then
        UIManager:unschedule(self._scroll_list_render)
    end
    if pos_y then
        Scroll.apply_y(self, pos_y)
    end
    self:refresh()
end

-- ---------------------------------------------------------------------------
-- Paint pipeline
-- ---------------------------------------------------------------------------

function AppView:refresh(full)
    UIManager:setDirty(self, full and "full" or "ui", self.dimen)
end

function AppView:onCloseWidget()
    UIManager:setDirty("all", "flashui", self.dimen)
end

function AppView:onClose()
    self.app:close()
    return true
end

function AppView:paintTo(bb, x, y)
    self.hitboxes = {}
    self.list_bounds = nil
    self.scroll_step = nil
    self.scrollbar = nil
    self.koreader_menu_zone = nil
    local m = Theme.metrics()
    self.dimen = Geom:new{ x = x, y = y, w = m.screen_w, h = m.screen_h }
    P.rect(bb, x, y, m.screen_w, m.screen_h, Theme.bg)

    local content_top = y
    content_top = Header.draw(self, bb, x, content_top, m.screen_w)
    if self.app.state.page == "queue" then
        self:draw_content(bb, x, content_top, m.screen_w, y + m.screen_h - content_top)
        return
    end
    local nav_top = y + m.screen_h - m.nav_h - m.nav_bottom_margin
    local banner_h = self.app:queue_count() > 0 and Theme.scale(56) or 0
    local content_bottom = nav_top
    self:draw_content(bb, x, content_top, m.screen_w, content_bottom - content_top)
    if banner_h > 0 then
        Nav.draw_queue_banner(self, bb, x, nav_top - banner_h, m.screen_w, banner_h)
    end
    Nav.draw(self, bb, x, nav_top, m.screen_w, m.nav_h)
end

-- Routes to the active page's content renderer, then draws the scrollbar and
-- clamps the stored scroll offset.
function AppView:draw_content(bb, x, y, w, h)
    local state = self.app.state
    local page = state.page
    local scroll_key = self.app:scroll_key()
    local scroll = state.scroll[scroll_key] or 0
    local max_scroll = 0

    if state.loading then
        P.rect(bb, x, y, w, h, Theme.bg)
        P.text(bb, state.loading, x + Theme.scale(16), y + Theme.scale(10), w - Theme.scale(32), "default", { color = Theme.muted })
        Scroll.set_list_bounds(self, x, y, w, h, h)
        self.max_scroll = 0
        return
    end

    if state.error then
        Pages.error(self, bb, x, y, w, h, state.error)
        self.max_scroll = 0
        return
    end

    if page == "home" then
        max_scroll = Pages.featured(self, bb, x, y, w, h, scroll)
    elseif page == "search" then
        max_scroll = Pages.packages_page(self, bb, x, y, w, h, scroll, _("Discover"), "search", state.visible_packages, state.packages, state.filters.search)
    elseif page == "categories" then
        max_scroll = Pages.categories(self, bb, x, y, w, h, scroll)
    elseif page == "settings" then
        max_scroll = Pages.settings(self, bb, x, y, w, h, scroll)
    elseif page == "category_details" then
        local category = state.current_category or {}
        max_scroll = Pages.packages_page(self, bb, x, y, w, h, scroll, I18n.dynamic_or(category.label, _("Category")), "category", state.visible_packages, state.category_packages, state.filters.category)
    elseif page == "installed" then
        max_scroll = Pages.packages_page(self, bb, x, y, w, h, scroll, _("Installed"), "installed", state.visible_packages, state.installed_packages, state.filters.installed)
    elseif page == "queue" then
        max_scroll = Pages.queue(self, bb, x, y, w, h, scroll)
    elseif page == "sources" then
        max_scroll = Pages.sources(self, bb, x, y, w, h, scroll)
    elseif page == "source_details" then
        max_scroll = Pages.source_details(self, bb, x, y, w, h, scroll)
    elseif page == "package_details" then
        max_scroll = Pages.package_details(self, bb, x, y, w, h, scroll)
    elseif page == "debug" then
        max_scroll = Pages.debug(self, bb, x, y, w, h, scroll)
    end

    Scroll.draw_scrollbar(self, bb, max_scroll, scroll)
    if scroll > max_scroll then
        state.scroll[scroll_key] = max_scroll
    end
    self.max_scroll = max_scroll
end

return AppView
